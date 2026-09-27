// opencode-plugin-test.sh の node 側。build が生成した plugin (marker 行つき) を import し、
// server(fakeCtx, {timeoutMs}) が返す hooks (入口) 経由で safe-gh の注記と fail-open を確かめる。
// 使い方: node opencode-plugin-test.mjs <generated plugin.js> <personal-safe-gh-hook.rb> <work dir>
// HOME は case ごとに process.env.HOME で tmp の home に向ける (plugin は os.homedir() から
// script を解決する)。実物の tool home は読まない。
import { spawnSync } from "node:child_process"
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const [pluginPath, hookSource, workDir] = process.argv.slice(2)
if (!pluginPath || !hookSource || !workDir) {
  console.error("usage: node opencode-plugin-test.mjs <plugin.js> <personal-safe-gh-hook.rb> <work dir>")
  process.exit(2)
}

const SCRIPT_REL = [".claude", "agent-tools", "scripts", "personal-safe-gh-hook"]
const SERVICE = "personal-agent-tools"
const SHORT_TIMEOUT_MS = 500
const DEADLINE_MARGIN_MS = 1500
const KILL_SETTLE_MS = 300
const ORIGINAL_OUTPUT = "original tool output\nline 2"

function fail(msg) {
  console.error(`FAIL: ${msg}`)
  process.exit(1)
}

function assert(cond, msg) {
  if (!cond) fail(msg)
}

// --- fixture: case ごとの home ---------------------------------------------------------

function makeHome(label, body, mode) {
  const home = join(workDir, `home-${label}`)
  const dir = join(home, ...SCRIPT_REL.slice(0, -1))
  mkdirSync(dir, { recursive: true })
  if (body !== null) {
    const script = join(dir, SCRIPT_REL[SCRIPT_REL.length - 1])
    if (body === "real") copyFileSync(hookSource, script)
    else writeFileSync(script, body)
    chmodSync(script, mode)
  }
  return home
}

const homes = {
  real: makeHome("real", "real", 0o755),
  missing: join(workDir, "home-missing"),
  noexec: makeHome("noexec", "real", 0o644),
  exit1: makeHome("exit1", "#!/bin/sh\nexit 1\n", 0o755),
  garbage: makeHome("garbage", "#!/bin/sh\necho 'not json at all'\n", 0o755),
  // pid を cwd (= fake ctx の directory) に書いてから寝る。group kill で子 (sh) と孫 (sleep) が
  // 消えることを確かめるため。
  slow: makeHome("slow", "#!/bin/sh\necho $$ > child.pid\nsleep 30 &\necho $! > grandchild.pid\nwait\n", 0o755),
}
mkdirSync(homes.missing, { recursive: true })

const ctxDir = join(workDir, "ctx")
mkdirSync(ctxDir, { recursive: true })

// --- fake client (SDK の形を assert する) ----------------------------------------------

function assertLogShape(arg) {
  assert(arg && typeof arg === "object" && arg.body && typeof arg.body === "object", "app.log must be called with {body}")
  const { service, level, message } = arg.body
  assert(service === SERVICE, `app.log body.service must be ${SERVICE}, got ${JSON.stringify(service)}`)
  assert(level === "warn", `app.log body.level must be warn, got ${JSON.stringify(level)}`)
  assert(typeof message === "string" && message !== "", "app.log body.message must be a non-empty string")
}

function makeClient(mode) {
  const calls = []
  const log = (arg) => {
    assertLogShape(arg)
    calls.push(arg)
    if (mode === "throw") throw new Error("fake app.log throws")
    if (mode === "reject") return Promise.reject(new Error("fake app.log rejects"))
    return Promise.resolve({ data: true })
  }
  return { calls, app: { log } }
}

// --- 期待値: 同じ command を Claude 形の payload で script に直接渡す -----------------------

function expectedContext(command) {
  const res = spawnSync(join(homes.real, ...SCRIPT_REL), [], {
    input: JSON.stringify({ tool_name: "Bash", tool_input: { command } }),
    env: { ...process.env, HOME: homes.real },
    encoding: "utf8",
  })
  assert(res.status === 0, `direct run of the hook script failed: ${res.stderr}`)
  if (res.stdout.trim() === "") return null
  const ctx = JSON.parse(res.stdout).hookSpecificOutput.additionalContext
  assert(typeof ctx === "string", "direct run: additionalContext must be a string")
  return ctx
}

// --- 入口 -------------------------------------------------------------------------------

const mod = await import(pathToFileURL(pluginPath).href)
const exportNames = Object.keys(mod)
assert(exportNames.join(",") === "default", `plugin must export only default, got ${exportNames.join(",")}`)
const plugin = mod.default
assert(typeof plugin.id === "string" && plugin.id !== "", "default export id must be a non-empty string")
assert(typeof plugin.server === "function", "default export server must be a function")

async function makeHooks(client, options) {
  const ctx = { client, directory: ctxDir, worktree: ctxDir, project: { id: "p1" } }
  return plugin.server(ctx, options)
}

function withDeadline(promise, ms, label) {
  let timer
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label}: hook did not resolve within ${ms} ms`)), ms)
  })
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer))
}

async function runAfter(hooks, home, input, output, deadlineMs, label) {
  process.env.HOME = home
  try {
    await withDeadline(hooks["tool.execute.after"](input, output), deadlineMs, label)
  } catch (error) {
    fail(`${label}: hook must not throw: ${error && error.stack ? error.stack : error}`)
  }
}

function bashInput(command) {
  return { tool: "bash", sessionID: "s1", callID: "c1", args: { command } }
}

// --- P1: hooks の形 -----------------------------------------------------------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  assert(typeof hooks["tool.execute.after"] === "function", "P1: tool.execute.after must be registered")
  assert(!("permission.ask" in hooks), "P1: permission.ask must not be registered")
  if (typeof hooks["tool.execute.before"] === "function") {
    const out = { args: { command: "gh issue view 1" } }
    process.env.HOME = homes.real
    try {
      await withDeadline(hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1", callID: "c1" }, out), DEADLINE_MARGIN_MS, "P1 before")
    } catch (error) {
      fail(`P1: tool.execute.before must not throw: ${error}`)
    }
    assert(out.args.command === "gh issue view 1", "P1: tool.execute.before must not rewrite args")
  }
  let rejected = false
  try {
    await plugin.server({ client, directory: ctxDir }, { timeoutMs: { safeGh: -1 } })
  } catch (error) {
    rejected = error instanceof TypeError
  }
  assert(rejected, "P1: server must reject an invalid options.timeoutMs.safeGh with TypeError")
  console.log("ok P1 hooks shape")
}

// --- P2: gh issue view 1 は script の注記を先頭に載せ、元の出力を後ろに残す ------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: 5000 } })
  const expected = expectedContext("gh issue view 1")
  assert(expected !== null, "P2: the hook script must steer gh issue view 1 (fixture assumption)")
  assert(expected.includes("personal-safe-gh") && expected.includes("steering"), `P2: script context must mention personal-safe-gh and steering: ${expected}`)
  const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
  await runAfter(hooks, homes.real, bashInput("gh issue view 1"), output, 5000 + DEADLINE_MARGIN_MS, "P2")
  assert(output.output === `${expected}\n\n${ORIGINAL_OUTPUT}`, `P2: output must be <context>\\n\\n<original>, got: ${JSON.stringify(output.output)}`)
  assert(output.output.startsWith(expected), "P2: context must come first")
  assert(output.output.endsWith(ORIGINAL_OUTPUT), "P2: original output must remain after the context")
  assert(client.calls.length === 0, `P2: no warn expected, got ${client.calls.length}`)
  console.log("ok P2 gh issue view 1 is annotated")
}

// --- P3: 無変更 (script の判定と一致し、warn も出ない) --------------------------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: 5000 } })
  for (const command of ["git status", "gh api -X POST repos/o/r/issues/1/comments -f body=x"]) {
    assert(expectedContext(command) === null, `P3: the hook script must not steer ${JSON.stringify(command)} (fixture assumption)`)
    const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
    await runAfter(hooks, homes.real, bashInput(command), output, 5000 + DEADLINE_MARGIN_MS, `P3 ${command}`)
    assert(output.output === ORIGINAL_OUTPUT, `P3: ${JSON.stringify(command)} must leave the output unchanged`)
  }
  // echo gh issue view 1 は script の判定に任せる (script が注記を返すならそれが正)。
  {
    const command = "echo gh issue view 1"
    const expected = expectedContext(command)
    const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
    await runAfter(hooks, homes.real, bashInput(command), output, 5000 + DEADLINE_MARGIN_MS, "P3 echo")
    const want = expected === null ? ORIGINAL_OUTPUT : `${expected}\n\n${ORIGINAL_OUTPUT}`
    assert(output.output === want, `P3: echo gh must follow the script's decision (script steer: ${expected !== null})`)
  }
  for (const tool of ["read", "edit", "github_get_issue", "task"]) {
    const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
    await runAfter(hooks, homes.real, { tool, sessionID: "s1", callID: "c1", args: { command: "gh issue view 1", filePath: "x" } }, output, DEADLINE_MARGIN_MS, `P3 tool ${tool}`)
    assert(output.output === ORIGINAL_OUTPUT, `P3: tool ${tool} must not be touched`)
  }
  assert(client.calls.length === 0, `P3: no warn expected, got ${client.calls.length}`)
  console.log("ok P3 unchanged commands and tools")
}

// --- P4: output.output が string でなければ throw せず無変更 ----------------------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: 5000 } })
  for (const value of [undefined, 42, { text: "x" }, null]) {
    const output = { title: "t", output: value, metadata: {} }
    await runAfter(hooks, homes.real, bashInput("gh issue view 1"), output, 5000 + DEADLINE_MARGIN_MS, `P4 ${typeof value}`)
    assert(output.output === value, `P4: non-string output (${typeof value}) must stay as is`)
  }
  assert(client.calls.length === 0, `P4: no warn expected, got ${client.calls.length}`)
  console.log("ok P4 non-string output untouched")
}

// --- P5: fail-open。どれも timeout 内に resolve し、throw せず、無変更で、warn は 1 回 ---------
const failOpenCases = [
  ["scripts dir missing", homes.missing],
  ["script not executable", homes.noexec],
  ["script exits non-zero", homes.exit1],
  ["stdout is garbage", homes.garbage],
  ["script times out", homes.slow],
]
for (const [label, home] of failOpenCases) {
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
  const started = Date.now()
  await runAfter(hooks, home, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `P5 ${label}`)
  const elapsed = Date.now() - started
  assert(output.output === ORIGINAL_OUTPUT, `P5 ${label}: output must be unchanged`)
  assert(client.calls.length === 1, `P5 ${label}: exactly one warn expected, got ${client.calls.length}`)
  // 2 回目は同じ script なので warn を増やさない。
  await runAfter(hooks, home, bashInput("gh issue view 1"), { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `P5 ${label} again`)
  assert(client.calls.length === 1, `P5 ${label}: warn must be logged once per script, got ${client.calls.length}`)
  if (home === homes.slow) {
    assert(elapsed >= SHORT_TIMEOUT_MS - 50, `P5 ${label}: resolved before the timeout (${elapsed} ms)`)
    await new Promise((r) => setTimeout(r, KILL_SETTLE_MS))
    for (const name of ["child.pid", "grandchild.pid"]) {
      const pid = Number(readFileSync(join(ctxDir, name), "utf8").trim())
      assert(Number.isInteger(pid) && pid > 0, `P5 ${label}: ${name} was not written by the fake script`)
      let alive = true
      try {
        process.kill(pid, 0)
      } catch (error) {
        alive = error.code !== "ESRCH"
      }
      if (alive) process.kill(pid, "SIGKILL")
      assert(!alive, `P5 ${label}: process group kill left ${name} ${pid} alive`)
    }
  }
  console.log(`ok P5 fail-open: ${label}`)
}

// --- P6: warn の経路が壊れても hook は落ちない (app.log が throw / reject、client が無い) --------
for (const mode of ["throw", "reject"]) {
  const client = makeClient(mode)
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
  await runAfter(hooks, homes.missing, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `P6 app.log ${mode}`)
  assert(output.output === ORIGINAL_OUTPUT, `P6 app.log ${mode}: output must be unchanged`)
  assert(client.calls.length === 1, `P6 app.log ${mode}: app.log must still be attempted once`)
}
{
  const hooks = await plugin.server({ directory: ctxDir }, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = { title: "t", output: ORIGINAL_OUTPUT, metadata: {} }
  await runAfter(hooks, homes.missing, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, "P6 no client")
  assert(output.output === ORIGINAL_OUTPUT, "P6 no client: output must be unchanged")
}
console.log("ok P6 warn path failures are swallowed")

console.log("all opencode-plugin node cases passed")

// opencode-plugin-test.sh の node 側。build が生成した plugin (marker 行つき) を import し、
// server(fakeCtx, {timeoutMs}) が返す hooks (入口) 経由で、safe-gh の注記、品質ループ
// (fast-edit-check / changed-scope-qa)、fail-open を確かめる。
// 使い方: node opencode-plugin-test.mjs <generated plugin.js> <personal-safe-gh-hook.rb>
//           <personal-fast-edit-check.rb> <personal-changed-scope-qa.rb> <work dir>
// HOME は case ごとに process.env.HOME で tmp の home に向ける (plugin は os.homedir() から
// script を解決する)。check の宣言は AGENT_TOOLS_CHECKS_CONFIG で tmp の file に向け、XDG の dir も
// tmp に向ける。実物の tool home は読まない。
import { spawnSync } from "node:child_process"
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const [pluginPath, safeGhSource, fastEditSource, qaSource, workDir] = process.argv.slice(2)
if (!pluginPath || !safeGhSource || !fastEditSource || !qaSource || !workDir) {
  console.error("usage: node opencode-plugin-test.mjs <plugin.js> <personal-safe-gh-hook.rb> <personal-fast-edit-check.rb> <personal-changed-scope-qa.rb> <work dir>")
  process.exit(2)
}

const SCRIPTS_DIR = [".claude", "agent-tools", "scripts"]
const SAFE_GH = "personal-safe-gh-hook"
const FAST_EDIT = "personal-fast-edit-check"
const QA = "personal-changed-scope-qa"
const SCRIPT_SOURCES = { [SAFE_GH]: safeGhSource, [FAST_EDIT]: fastEditSource, [QA]: qaSource }
const QA_STATE_REL = [".cache", "agent-tools", "changed-scope-qa-opencode"]
const QA_DEFAULT_STATE_REL = [".cache", "agent-tools", "changed-scope-qa"]
const SERVICE = "personal-agent-tools"
const LOG_LEVELS = ["debug", "info", "error", "warn"]
const SHORT_TIMEOUT_MS = 500
const REAL_TIMEOUT_MS = 20000
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

function shq(value) {
  return `'${value.replace(/'/g, "'\\''")}'`
}

function readLines(path) {
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((line) => line !== "") : []
}

// --- fixture: case ごとの home (3 本の script を同じ body で置く) ---------------------------

function makeHome(label, body, mode, overrides = {}) {
  const home = join(workDir, `home-${label}`)
  const dir = join(home, ...SCRIPTS_DIR)
  mkdirSync(dir, { recursive: true })
  if (body !== null) {
    for (const [name, source] of Object.entries(SCRIPT_SOURCES)) {
      const script = join(dir, name)
      const content = overrides[name] ?? body
      if (content === "real") copyFileSync(source, script)
      else writeFileSync(script, content)
      chmodSync(script, mode)
    }
  }
  return home
}

const homes = {
  real: makeHome("real", "real", 0o755),
  qa: makeHome("qa", "real", 0o755),
  missing: join(workDir, "home-missing"),
  noexec: makeHome("noexec", "real", 0o644),
  exit1: makeHome("exit1", "#!/bin/sh\nexit 1\n", 0o755),
  garbage: makeHome("garbage", "#!/bin/sh\necho 'not json at all'\n", 0o755),
  // pid を cwd (= fake ctx の directory) に書いてから寝る。group kill で子 (sh) と孫 (sleep) が
  // 消えることを確かめるため。
  slow: makeHome("slow", "#!/bin/sh\necho $$ > child.pid\nsleep 5 &\necho $! > grandchild.pid\nwait\n", 0o755),
  // 起動と payload / env / cwd を $HOME の下に記録する (出力なしの exit 0)。changed-scope-qa は
  // 実行中の idle を skip することを確かめるため少し寝る。
  recorder: makeHome("recorder", "#!/bin/sh\nexit 0\n", 0o755, {
    [FAST_EDIT]: '#!/bin/sh\ncat >> "$HOME/edit-payloads.log"\necho >> "$HOME/edit-payloads.log"\n',
    [QA]: '#!/bin/sh\nprintf \'%s\\t%s\\t%s\\n\' "$AGENT_TOOLS_QA_STATE_DIR" "$(pwd -P)" "$(cat)" >> "$HOME/qa-starts.log"\nsleep 0.3\n',
  }),
  // fast-edit-check が bad.rb でだけ非 0 で終わり、ほかの file には file 名入りの要約を返す。
  flaky: makeHome("flaky", "#!/bin/sh\nexit 0\n", 0o755, {
    [FAST_EDIT]: `#!/bin/sh
payload=$(cat)
case "$payload" in *bad.rb*) exit 1 ;; esac
file=$(printf '%s' "$payload" | sed 's/.*"file_path":"\\([^"]*\\)".*/\\1/')
printf '{"hookSpecificOutput":{"additionalContext":"summary for %s"}}\\n' "$(basename "$file")"
`,
  }),
}
mkdirSync(homes.missing, { recursive: true })

const ctxDir = join(workDir, "ctx")
mkdirSync(ctxDir, { recursive: true })

// XDG の dir も tmp に向け、plugin が OpenCode の config / data / cache に書かないことを後で確かめる。
const xdgDirs = {}
for (const kind of ["CONFIG", "DATA", "CACHE", "STATE"]) {
  xdgDirs[kind] = join(workDir, "xdg", kind.toLowerCase())
  process.env[`XDG_${kind}_HOME`] = xdgDirs[kind]
}

// --- fixture: git repo と記録つきの fake check (quality-loop-hooks-test.sh と同じ組み方) --------

const gitEnv = {
  PATH: process.env.PATH,
  HOME: join(workDir, "git-home"),
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_AUTHOR_NAME: "test",
  GIT_AUTHOR_EMAIL: "test@example.com",
  GIT_COMMITTER_NAME: "test",
  GIT_COMMITTER_EMAIL: "test@example.com",
}

function git(repo, ...args) {
  const res = spawnSync("git", ["-C", repo, ...args], { env: gitEnv, encoding: "utf8" })
  assert(res.status === 0, `git ${args.join(" ")} failed: ${res.stderr}`)
  return res.stdout
}

function makeRepo(label) {
  const repo = join(workDir, label)
  mkdirSync(repo, { recursive: true })
  git(repo, "init", "-q", "-b", "main")
  writeFileSync(join(repo, "base.txt"), "base\n")
  git(repo, "add", "base.txt")
  git(repo, "commit", "-qm", "seed")
  return repo
}

const editRepo = makeRepo("repo-edit")
const qaRepo = makeRepo("repo-qa")

const checkLog = join(workDir, "check-argv.log")
const checkFailFlag = join(workDir, "check-fail")
const fakeCheck = join(workDir, "fake-check")
writeFileSync(fakeCheck, `#!/bin/sh
printf '%s\\n' "$*" >> ${shq(checkLog)}
if [ -f ${shq(checkFailFlag)} ]; then
  echo "lint error: something is wrong"
  exit 1
fi
exit 0
`)
chmodSync(fakeCheck, 0o755)
const slowCheckLog = join(workDir, "slow-check-argv.log")
const slowCheck = join(workDir, "slow-check")
writeFileSync(slowCheck, `#!/bin/sh\nprintf '%s\\n' "$*" >> ${shq(slowCheckLog)}\nsleep 5\n`)
chmodSync(slowCheck, 0o755)

function writeConfig(path, check) {
  const entry = {
    edit_checks: [{ name: "fake-lint", pattern: "\\.rb$", command: [check] }],
    qa_checks: [{ name: "fake-suite", command: [check] }],
  }
  writeFileSync(path, JSON.stringify({ [realpathSync(editRepo)]: entry, [realpathSync(qaRepo)]: entry }))
  return path
}
const configs = {
  fake: writeConfig(join(workDir, "checks.local.json"), fakeCheck),
  slow: writeConfig(join(workDir, "checks-slow.local.json"), slowCheck),
  broken: join(workDir, "checks-broken.local.json"),
}
writeFileSync(configs.broken, "{ not json")
process.env.AGENT_TOOLS_CHECKS_CONFIG = configs.fake

function setCheckFails(fails) {
  if (fails) writeFileSync(checkFailFlag, "")
  else rmSync(checkFailFlag, { force: true })
}

// --- fake client (SDK の形を assert する) ----------------------------------------------

function assertLogShape(arg) {
  assert(arg && typeof arg === "object" && arg.body && typeof arg.body === "object", "app.log must be called with {body}")
  const { service, level, message } = arg.body
  assert(service === SERVICE, `app.log body.service must be ${SERVICE}, got ${JSON.stringify(service)}`)
  assert(LOG_LEVELS.includes(level), `app.log body.level must be one of ${LOG_LEVELS.join("/")}, got ${JSON.stringify(level)}`)
  assert(typeof message === "string" && message !== "", "app.log body.message must be a non-empty string")
}

// model を続けさせる API と toast は、呼ばれた時点で test を落とす (「非対応」の case)。
// throw だと plugin の fail-open に握られるので、process ごと落とす。
function forbidden(name) {
  return () => fail(`${name} must never be called (the plugin must not continue the model or show a toast)`)
}

// session.get: parents[id] があればその parentID を持つ子 session として返す。
// getMode: "ok" / "throw" / "empty" (data が無い)。
function makeClient(mode, { parents = {}, getMode = "ok" } = {}) {
  const calls = []
  const log = (arg) => {
    assertLogShape(arg)
    calls.push(arg)
    if (mode === "throw") throw new Error("fake app.log throws")
    if (mode === "reject") return Promise.reject(new Error("fake app.log rejects"))
    return Promise.resolve({ data: true })
  }
  const get = async (arg) => {
    const id = arg && arg.path ? arg.path.id : undefined
    assert(typeof id === "string" && id !== "", `session.get must be called with {path: {id}}, got ${JSON.stringify(arg)}`)
    if (getMode === "throw") throw new Error("fake session.get throws")
    if (getMode === "empty") return { data: undefined }
    return { data: parents[id] === undefined ? { id } : { id, parentID: parents[id] } }
  }
  return {
    calls,
    app: { log },
    session: { get, prompt: forbidden("session.prompt"), promptAsync: forbidden("session.promptAsync") },
    tui: { showToast: forbidden("tui.showToast"), appendPrompt: forbidden("tui.appendPrompt"), submitPrompt: forbidden("tui.submitPrompt") },
  }
}

function assertWarns(client, count, label) {
  assert(client.calls.length === count, `${label}: expected ${count} log call(s), got ${client.calls.length}: ${JSON.stringify(client.calls)}`)
  for (const call of client.calls) {
    assert(call.body.level === "warn", `${label}: expected level warn, got ${call.body.level}`)
  }
}

// --- 期待値: 同じ payload を Claude 形で script に直接渡す ---------------------------------

// env は plugin が子 process に渡すものと揃える (PATH / LANG 系 / check 宣言の場所 + HOME)。
function runDirect(script, home, payload, { cwd, env = {} } = {}) {
  const base = {}
  for (const name of ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "AGENT_TOOLS_CHECKS_CONFIG"]) {
    if (typeof process.env[name] === "string") base[name] = process.env[name]
  }
  return spawnSync(join(home, ...SCRIPTS_DIR, script), [], {
    cwd,
    input: JSON.stringify(payload),
    env: { ...base, HOME: home, ...env },
    encoding: "utf8",
  })
}

function contextOf(res, label) {
  assert(res.status === 0, `${label}: direct run of the hook script failed: ${res.stderr}`)
  if (res.stdout.trim() === "") return null
  const ctx = JSON.parse(res.stdout).hookSpecificOutput.additionalContext
  assert(typeof ctx === "string", `${label}: direct run: additionalContext must be a string`)
  return ctx
}

function expectedContext(command) {
  return contextOf(runDirect(SAFE_GH, homes.real, { tool_name: "Bash", tool_input: { command } }), "safe-gh")
}

function expectedEditContext(file) {
  const payload = { hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: { file_path: file } }
  return contextOf(runDirect(FAST_EDIT, homes.real, payload), `fast-edit-check ${file}`)
}

// --- 入口 -------------------------------------------------------------------------------

const mod = await import(pathToFileURL(pluginPath).href)
const exportNames = Object.keys(mod)
assert(exportNames.join(",") === "default", `plugin must export only default, got ${exportNames.join(",")}`)
const plugin = mod.default
assert(typeof plugin.id === "string" && plugin.id !== "", "default export id must be a non-empty string")
assert(typeof plugin.server === "function", "default export server must be a function")

async function makeHooks(client, options, directory = ctxDir) {
  const ctx = { client, directory, worktree: directory, project: { id: "p1" } }
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

async function runEvent(hooks, home, event, deadlineMs, label) {
  process.env.HOME = home
  try {
    await withDeadline(hooks.event({ event }), deadlineMs, label)
  } catch (error) {
    fail(`${label}: event hook must not throw: ${error && error.stack ? error.stack : error}`)
  }
}

function bashInput(command) {
  return { tool: "bash", sessionID: "s1", callID: "c1", args: { command } }
}

function editInput(tool, filePath) {
  return { tool, sessionID: "s1", callID: "c1", args: { filePath } }
}

function patchInput() {
  return { tool: "apply_patch", sessionID: "s1", callID: "c1", args: { patchText: "*** Begin Patch\n*** End Patch" } }
}

function toolOutput(metadata = {}) {
  return { title: "t", output: ORIGINAL_OUTPUT, metadata }
}

function idle(sessionID = "s1") {
  return { type: "session.idle", properties: { sessionID } }
}

// --- P1: hooks の形 -----------------------------------------------------------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  assert(typeof hooks["tool.execute.after"] === "function", "P1: tool.execute.after must be registered")
  assert(typeof hooks.event === "function", "P1: event must be registered")
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
  for (const key of ["safeGh", "fastEditCheck", "changedScopeQa"]) {
    let rejected = false
    try {
      await plugin.server({ client, directory: ctxDir }, { timeoutMs: { [key]: -1 } })
    } catch (error) {
      rejected = error instanceof TypeError
    }
    assert(rejected, `P1: server must reject an invalid options.timeoutMs.${key} with TypeError`)
  }
  let rejectedTable = false
  try {
    await plugin.server({ client, directory: ctxDir }, { timeoutMs: 5 })
  } catch (error) {
    rejectedTable = error instanceof TypeError
  }
  assert(rejectedTable, "P1: server must reject a non-object options.timeoutMs with TypeError")
  console.log("ok P1 hooks shape")
}

// --- P2: gh issue view 1 は script の注記を先頭に載せ、元の出力を後ろに残す ------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: 5000 } })
  const expected = expectedContext("gh issue view 1")
  assert(expected !== null, "P2: the hook script must steer gh issue view 1 (fixture assumption)")
  assert(expected.includes("personal-safe-gh") && expected.includes("steering"), `P2: script context must mention personal-safe-gh and steering: ${expected}`)
  const output = toolOutput()
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
    const output = toolOutput()
    await runAfter(hooks, homes.real, bashInput(command), output, 5000 + DEADLINE_MARGIN_MS, `P3 ${command}`)
    assert(output.output === ORIGINAL_OUTPUT, `P3: ${JSON.stringify(command)} must leave the output unchanged`)
  }
  // echo gh issue view 1 は script の判定に任せる (script が注記を返すならそれが正)。
  {
    const command = "echo gh issue view 1"
    const expected = expectedContext(command)
    const output = toolOutput()
    await runAfter(hooks, homes.real, bashInput(command), output, 5000 + DEADLINE_MARGIN_MS, "P3 echo")
    const want = expected === null ? ORIGINAL_OUTPUT : `${expected}\n\n${ORIGINAL_OUTPUT}`
    assert(output.output === want, `P3: echo gh must follow the script's decision (script steer: ${expected !== null})`)
  }
  for (const tool of ["read", "edit", "github_get_issue", "task"]) {
    const output = toolOutput()
    await runAfter(hooks, homes.real, { tool, sessionID: "s1", callID: "c1", args: { command: "gh issue view 1", filePath: "x" } }, output, DEADLINE_MARGIN_MS, `P3 tool ${tool}`)
    assert(output.output === ORIGINAL_OUTPUT, `P3: tool ${tool} must not be touched`)
  }
  assert(client.calls.length === 0, `P3: no warn expected, got ${client.calls.length}`)
  console.log("ok P3 unchanged commands and tools")
}

// --- P4: output.output が string でなければ throw せず無変更 ----------------------------------
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: 5000 } }, editRepo)
  setCheckFails(true)
  writeFileSync(join(editRepo, "a.rb"), "puts 1\n")
  for (const value of [undefined, 42, { text: "x" }, null]) {
    for (const [label, input] of [["bash", bashInput("gh issue view 1")], ["edit", editInput("edit", join(editRepo, "a.rb"))]]) {
      const output = { title: "t", output: value, metadata: {} }
      await runAfter(hooks, homes.real, input, output, 5000 + DEADLINE_MARGIN_MS, `P4 ${label} ${typeof value}`)
      assert(output.output === value, `P4: non-string output (${label}, ${typeof value}) must stay as is`)
    }
  }
  setCheckFails(false)
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

async function assertGroupKilled(label) {
  await new Promise((r) => setTimeout(r, KILL_SETTLE_MS))
  for (const name of ["child.pid", "grandchild.pid"]) {
    const pid = Number(readFileSync(join(ctxDir, name), "utf8").trim())
    assert(Number.isInteger(pid) && pid > 0, `${label}: ${name} was not written by the fake script`)
    let alive = true
    try {
      process.kill(pid, 0)
    } catch (error) {
      alive = error.code !== "ESRCH"
    }
    if (alive) process.kill(pid, "SIGKILL")
    assert(!alive, `${label}: process group kill left ${name} ${pid} alive`)
    rmSync(join(ctxDir, name))
  }
}

for (const [label, home] of failOpenCases) {
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = toolOutput()
  const started = Date.now()
  await runAfter(hooks, home, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `P5 ${label}`)
  const elapsed = Date.now() - started
  assert(output.output === ORIGINAL_OUTPUT, `P5 ${label}: output must be unchanged`)
  assertWarns(client, 1, `P5 ${label}`)
  // 2 回目は同じ script なので warn を増やさない。
  await runAfter(hooks, home, bashInput("gh issue view 1"), toolOutput(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `P5 ${label} again`)
  assertWarns(client, 1, `P5 ${label} (warn once per script)`)
  if (home === homes.slow) {
    assert(elapsed >= SHORT_TIMEOUT_MS - 50, `P5 ${label}: resolved before the timeout (${elapsed} ms)`)
    await assertGroupKilled(`P5 ${label}`)
  }
  console.log(`ok P5 fail-open: ${label}`)
}

// --- P6: warn の経路が壊れても hook は落ちない (app.log が throw / reject、client が無い) --------
for (const mode of ["throw", "reject"]) {
  const client = makeClient(mode)
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = toolOutput()
  await runAfter(hooks, homes.missing, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `P6 app.log ${mode}`)
  assert(output.output === ORIGINAL_OUTPUT, `P6 app.log ${mode}: output must be unchanged`)
  assertWarns(client, 1, `P6 app.log ${mode} (still attempted once)`)
}
{
  const hooks = await plugin.server({ directory: ctxDir }, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = toolOutput()
  await runAfter(hooks, homes.missing, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, "P6 no client")
  assert(output.output === ORIGINAL_OUTPUT, "P6 no client: output must be unchanged")
}
console.log("ok P6 warn path failures are swallowed")

// === 品質ループ: fast-edit-check (tool.execute.after) ==========================================

// E1: edit (絶対 path / 相対 path) と write。check が失敗したら末尾に要約が足され、成功なら無変更。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: REAL_TIMEOUT_MS } }, editRepo)
  const file = join(editRepo, "a.rb")
  writeFileSync(file, "puts 1\n")
  setCheckFails(true)
  const expected = expectedEditContext(file)
  assert(expected !== null && expected.startsWith("fast-edit-check:") && expected.includes("lint error"), `E1: the script must report the failing check (fixture assumption): ${expected}`)
  const cases = [
    ["edit absolute", editInput("edit", file)],
    ["edit relative", editInput("edit", "a.rb")],
    ["write", editInput("write", file)],
  ]
  for (const [label, input] of cases) {
    const before = readLines(checkLog).length
    const output = toolOutput()
    await runAfter(hooks, homes.real, input, output, REAL_TIMEOUT_MS, `E1 ${label}`)
    assert(output.output === `${ORIGINAL_OUTPUT}\n\n${expected}`, `E1 ${label}: output must be <original>\\n\\n<summary>, got: ${JSON.stringify(output.output)}`)
    const ran = readLines(checkLog).slice(before)
    assert(ran.length === 1 && ran[0] === file, `E1 ${label}: the check must run once on ${file}, got ${JSON.stringify(ran)}`)
  }
  setCheckFails(false)
  {
    const before = readLines(checkLog).length
    const output = toolOutput()
    await runAfter(hooks, homes.real, editInput("edit", file), output, REAL_TIMEOUT_MS, "E1 pass")
    assert(output.output === ORIGINAL_OUTPUT, "E1 pass: a passing check must leave the output unchanged")
    assert(readLines(checkLog).length === before + 1, "E1 pass: the check must still run")
  }
  assert(client.calls.length === 0, `E1: no warn expected, got ${client.calls.length}`)
  console.log("ok E1 edit / write append the failing check summary")
}

// E2: apply_patch は metadata.files から取る。move は移動先、delete は check しない。metadata が無ければ無変更。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: REAL_TIMEOUT_MS } }, editRepo)
  const path = (name) => join(editRepo, name)
  // 移動元・削除した file・相対 path の file も置いておく (取り違えたら check されて検出できるように)。
  for (const name of ["a.rb", "b.rb", "old.rb", "c.rb", "d.rb", "relative.rb"]) writeFileSync(path(name), "puts 1\n")
  const files = [
    { filePath: path("b.rb"), type: "add" },
    { filePath: path("a.rb"), type: "update" },
    { filePath: path("old.rb"), movePath: path("c.rb"), type: "move" },
    { filePath: path("d.rb"), type: "delete" },
    { filePath: "relative.rb", type: "add" },
  ]
  setCheckFails(true)
  const expected = ["b.rb", "a.rb", "c.rb"].map((name) => expectedEditContext(path(name)))
  const before = readLines(checkLog).length
  const output = toolOutput({ files })
  await runAfter(hooks, homes.real, patchInput(), output, REAL_TIMEOUT_MS, "E2 apply_patch")
  const ran = readLines(checkLog).slice(before)
  assert(JSON.stringify(ran) === JSON.stringify(["b.rb", "a.rb", "c.rb"].map(path)), `E2: add / update / move target must be checked in order, got ${JSON.stringify(ran)}`)
  assert(output.output === `${ORIGINAL_OUTPUT}\n\n${expected.join("\n\n")}`, `E2: summaries must be appended in order, got: ${JSON.stringify(output.output)}`)
  for (const metadata of [{}, { files: "x" }, undefined]) {
    const beforeNone = readLines(checkLog).length
    const out = { title: "t", output: ORIGINAL_OUTPUT, metadata }
    await runAfter(hooks, homes.real, patchInput(), out, REAL_TIMEOUT_MS, "E2 no metadata")
    assert(out.output === ORIGINAL_OUTPUT, `E2: apply_patch without metadata.files must be unchanged (${JSON.stringify(metadata)})`)
    assert(readLines(checkLog).length === beforeNone, "E2: apply_patch without metadata.files must not run a check")
  }
  setCheckFails(false)
  assert(client.calls.length === 0, `E2: no warn expected, got ${client.calls.length}`)
  console.log("ok E2 apply_patch uses metadata.files (move target, no delete)")
}

// E3: 同じ文言は 1 回だけ足す (設定が壊れているときの設定エラーは file ごとに同じ文になる)。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: REAL_TIMEOUT_MS } }, editRepo)
  process.env.AGENT_TOOLS_CHECKS_CONFIG = configs.broken
  const expected = expectedEditContext(join(editRepo, "a.rb"))
  assert(expected !== null && expected.includes("設定エラー"), `E3: a broken config must be reported (fixture assumption): ${expected}`)
  const output = toolOutput({ files: [{ filePath: join(editRepo, "a.rb"), type: "update" }, { filePath: join(editRepo, "b.rb"), type: "update" }] })
  await runAfter(hooks, homes.real, patchInput(), output, REAL_TIMEOUT_MS, "E3 dedupe")
  process.env.AGENT_TOOLS_CHECKS_CONFIG = configs.fake
  assert(output.output === `${ORIGINAL_OUTPUT}\n\n${expected}`, `E3: the same summary must be appended once, got: ${JSON.stringify(output.output)}`)
  console.log("ok E3 identical summaries are appended once")
}

// E4: 総予算を超えたら残りの file は check しない。予算の内に resolve する。予算は、最初の file で
// ruby と slow check が起動して記録を書き終える余裕を持たせる。
{
  const budgetMs = 1500
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: budgetMs } }, editRepo)
  process.env.AGENT_TOOLS_CHECKS_CONFIG = configs.slow
  const files = ["a.rb", "b.rb", "c.rb"].map((name) => ({ filePath: join(editRepo, name), type: "update" }))
  const output = toolOutput({ files })
  const started = Date.now()
  await runAfter(hooks, homes.real, patchInput(), output, budgetMs + DEADLINE_MARGIN_MS, "E4 budget")
  const elapsed = Date.now() - started
  process.env.AGENT_TOOLS_CHECKS_CONFIG = configs.fake
  assert(elapsed < budgetMs + 500, `E4: the hook must resolve within the total budget (${elapsed} ms)`)
  const ran = readLines(slowCheckLog)
  assert(JSON.stringify(ran) === JSON.stringify([join(editRepo, "a.rb")]), `E4: only the first file may be checked within the budget, got ${JSON.stringify(ran)}`)
  assert(output.output === ORIGINAL_OUTPUT, "E4: output must be unchanged")
  assertWarns(client, 1, "E4 budget")
  console.log("ok E4 the total budget skips the remaining files")
}

// E5: script に渡す payload は Claude 形 (Edit / Write)。apply_patch の tool 名は渡さない。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: REAL_TIMEOUT_MS } }, editRepo)
  const file = join(editRepo, "a.rb")
  await runAfter(hooks, homes.recorder, editInput("edit", "a.rb"), toolOutput(), REAL_TIMEOUT_MS, "E5 edit")
  await runAfter(hooks, homes.recorder, editInput("write", file), toolOutput(), REAL_TIMEOUT_MS, "E5 write")
  await runAfter(hooks, homes.recorder, patchInput(), toolOutput({ files: [{ filePath: file, type: "update" }] }), REAL_TIMEOUT_MS, "E5 apply_patch")
  const payloads = readLines(join(homes.recorder, "edit-payloads.log")).map((line) => JSON.parse(line))
  const want = [["Edit", file], ["Write", file], ["Edit", file]]
  assert(payloads.length === want.length, `E5: expected ${want.length} payloads, got ${payloads.length}`)
  payloads.forEach((payload, i) => {
    assert(payload.hook_event_name === "PostToolUse", `E5[${i}]: hook_event_name must be PostToolUse`)
    assert(payload.tool_name === want[i][0], `E5[${i}]: tool_name must be ${want[i][0]}, got ${payload.tool_name}`)
    assert(payload.tool_input && payload.tool_input.file_path === want[i][1], `E5[${i}]: tool_input.file_path must be ${want[i][1]}`)
  })
  assert(client.calls.length === 0, `E5: no warn expected, got ${client.calls.length}`)
  console.log("ok E5 payloads are Claude-shaped (no apply_patch tool name)")
}

// E6: fail-open (P5 と同じ条件を fast-edit-check で)。
for (const [label, home] of failOpenCases) {
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: SHORT_TIMEOUT_MS } })
  const output = toolOutput()
  const started = Date.now()
  await runAfter(hooks, home, editInput("edit", join(editRepo, "a.rb")), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `E6 ${label}`)
  const elapsed = Date.now() - started
  assert(output.output === ORIGINAL_OUTPUT, `E6 ${label}: output must be unchanged`)
  assertWarns(client, 1, `E6 ${label}`)
  await runAfter(hooks, home, editInput("write", join(editRepo, "a.rb")), toolOutput(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `E6 ${label} again`)
  assertWarns(client, 1, `E6 ${label} (warn once per script)`)
  if (home === homes.slow) {
    assert(elapsed >= SHORT_TIMEOUT_MS - 50, `E6 ${label}: resolved before the timeout (${elapsed} ms)`)
    await assertGroupKilled(`E6 ${label}`)
  }
  console.log(`ok E6 fail-open: ${label}`)
}
for (const mode of ["throw", "reject"]) {
  const client = makeClient(mode)
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: SHORT_TIMEOUT_MS } })
  const output = toolOutput()
  await runAfter(hooks, homes.missing, editInput("edit", join(editRepo, "a.rb")), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `E6 app.log ${mode}`)
  assert(output.output === ORIGINAL_OUTPUT, `E6 app.log ${mode}: output must be unchanged`)
  assertWarns(client, 1, `E6 app.log ${mode} (still attempted once)`)
}
console.log("ok E6 warn path failures are swallowed")

// E7: 1 file の失敗は warn して次の file に進み、前後の file の要約は残す。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: REAL_TIMEOUT_MS } }, editRepo)
  const files = ["first.rb", "bad.rb", "last.rb"].map((name) => ({ filePath: join(editRepo, name), type: "add" }))
  const output = toolOutput({ files })
  await runAfter(hooks, homes.flaky, patchInput(), output, REAL_TIMEOUT_MS, "E7 one file fails")
  assert(output.output === `${ORIGINAL_OUTPUT}\n\nsummary for first.rb\n\nsummary for last.rb`, `E7: the other files' summaries must remain, got: ${JSON.stringify(output.output)}`)
  assertWarns(client, 1, "E7 one file fails")
  console.log("ok E7 a failing file does not drop the other files")
}

// === 品質ループ: changed-scope-qa (event の session.idle、report-only) ===========================

const qaStateDir = (home) => join(home, ...QA_STATE_REL)

// Q1: dirty な repo で qa check が失敗 → error で 1 回。同じ scope の再 idle → warn。clean → 何も出ない。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: REAL_TIMEOUT_MS } }, qaRepo)
  writeFileSync(join(qaRepo, "base.txt"), "changed\n")
  setCheckFails(true)
  const direct = runDirect(QA, homes.real, { hook_event_name: "Stop", stop_hook_active: false }, { cwd: qaRepo, env: { AGENT_TOOLS_QA_STATE_DIR: join(workDir, "qa-state-direct") } })
  assert(direct.status === 2 && direct.stderr.includes("lint error"), `Q1: the script must block the failing scope (fixture assumption): ${direct.status} ${direct.stderr}`)
  const expected = direct.stderr.trimEnd()

  await runEvent(hooks, homes.qa, idle(), REAL_TIMEOUT_MS, "Q1 fail")
  assert(client.calls.length === 1, `Q1: app.log must be called once, got ${client.calls.length}`)
  assert(client.calls[0].body.level === "error", `Q1: level must be error for exit 2, got ${client.calls[0].body.level}`)
  assert(client.calls[0].body.message === expected, `Q1: message must be the full stderr, got ${JSON.stringify(client.calls[0].body.message)}`)

  await runEvent(hooks, homes.qa, idle(), REAL_TIMEOUT_MS, "Q1 same scope")
  assert(client.calls.length === 2, `Q1: the same scope must be reported again, got ${client.calls.length}`)
  assert(client.calls[1].body.level === "warn" && client.calls[1].body.message.startsWith("changed-scope-qa:"), `Q1: the same scope must be a warn: ${JSON.stringify(client.calls[1].body)}`)

  git(qaRepo, "checkout", "--", "base.txt")
  await runEvent(hooks, homes.qa, idle(), REAL_TIMEOUT_MS, "Q1 clean")
  assert(client.calls.length === 2, `Q1: a clean tree must not be reported, got ${client.calls.length}`)
  setCheckFails(false)

  const stateFiles = existsSync(qaStateDir(homes.qa)) ? readdirSync(qaStateDir(homes.qa)) : []
  assert(stateFiles.length === 1, `Q1: state must be written under ${QA_STATE_REL.join("/")}, got ${JSON.stringify(stateFiles)}`)
  assert(!existsSync(join(homes.qa, ...QA_DEFAULT_STATE_REL)), "Q1: the Claude / Codex state dir must not be written")
  for (const [kind, dir] of Object.entries(xdgDirs)) {
    assert(!existsSync(join(dir, "opencode")), `Q1: nothing must be written under XDG_${kind}_HOME/opencode`)
  }
  console.log("ok Q1 changed-scope-qa reports to the log only (error / warn / clean)")
}

// Q2: 起動の条件。idle 以外では起動しない。起動時の env / cwd / payload。同時の idle は 1 回だけ。
{
  const starts = join(homes.recorder, "qa-starts.log")
  const client = makeClient("ok", { parents: { child: "s1" } })
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: REAL_TIMEOUT_MS } }, qaRepo)
  for (const type of ["session.updated", "session.status", "message.updated", "file.edited", "session.error"]) {
    await runEvent(hooks, homes.recorder, { type, properties: { sessionID: "s1" } }, REAL_TIMEOUT_MS, `Q2 ${type}`)
  }
  assert(readLines(starts).length === 0, `Q2: events other than session.idle must not start the script, got ${readLines(starts).length}`)

  await runEvent(hooks, homes.recorder, idle("child"), REAL_TIMEOUT_MS, "Q2 child idle")
  assert(readLines(starts).length === 0, "Q2: the idle of a child session must not start the script")

  await runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, "Q2 idle")
  const lines = readLines(starts)
  assert(lines.length === 1, `Q2: session.idle must start the script once, got ${lines.length}`)
  const [stateDir, cwd, payload] = lines[0].split("\t")
  assert(stateDir === qaStateDir(homes.recorder), `Q2: AGENT_TOOLS_QA_STATE_DIR must be ${qaStateDir(homes.recorder)}, got ${stateDir}`)
  assert(cwd === realpathSync(qaRepo), `Q2: cwd must be the plugin directory, got ${cwd}`)
  assert(JSON.stringify(JSON.parse(payload)) === JSON.stringify({ hook_event_name: "Stop", stop_hook_active: false }), `Q2: payload must be the Stop shape, got ${payload}`)

  await Promise.all([
    runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, "Q2 concurrent 1"),
    runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, "Q2 concurrent 2"),
  ])
  assert(readLines(starts).length === 2, `Q2: two concurrent idles must start the script once, got ${readLines(starts).length - 1}`)
  await runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, "Q2 after")
  assert(readLines(starts).length === 3, "Q2: the next idle after the run must start the script again")
  assert(client.calls.length === 0, `Q2: no log expected, got ${JSON.stringify(client.calls)}`)
  console.log("ok Q2 only a top-level session.idle starts the script, one at a time")
}

// Q3: 親子の判定ができないときは起動せず warn を 1 回 (session.get が throw / data が無い)。
for (const getMode of ["throw", "empty"]) {
  const starts = join(homes.recorder, "qa-starts.log")
  const before = readLines(starts).length
  const client = makeClient("ok", { getMode })
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: REAL_TIMEOUT_MS } }, qaRepo)
  await runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, `Q3 ${getMode}`)
  await runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, `Q3 ${getMode} again`)
  assert(readLines(starts).length === before, `Q3 ${getMode}: the script must not start without the session lookup`)
  assertWarns(client, 1, `Q3 ${getMode}`)
  console.log(`ok Q3 session lookup failure (${getMode}) is fail-open`)
}

// Q4: fail-open (P5 と同じ条件を changed-scope-qa で)。
for (const [label, home] of failOpenCases) {
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: SHORT_TIMEOUT_MS } })
  const started = Date.now()
  await runEvent(hooks, home, idle(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `Q4 ${label}`)
  const elapsed = Date.now() - started
  assertWarns(client, 1, `Q4 ${label}`)
  await runEvent(hooks, home, idle(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, `Q4 ${label} again`)
  assertWarns(client, 1, `Q4 ${label} (warn once per script)`)
  if (home === homes.slow) {
    assert(elapsed >= SHORT_TIMEOUT_MS - 50, `Q4 ${label}: resolved before the timeout (${elapsed} ms)`)
    await assertGroupKilled(`Q4 ${label}`)
  }
  console.log(`ok Q4 fail-open: ${label}`)
}
for (const mode of ["throw", "reject"]) {
  const client = makeClient(mode)
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: REAL_TIMEOUT_MS } }, qaRepo)
  writeFileSync(join(qaRepo, "base.txt"), `changed for ${mode}\n`)
  setCheckFails(true)
  await runEvent(hooks, homes.qa, idle(), REAL_TIMEOUT_MS, `Q4 app.log ${mode}`)
  setCheckFails(false)
  git(qaRepo, "checkout", "--", "base.txt")
  assert(client.calls.length === 1 && client.calls[0].body.level === "error", `Q4 app.log ${mode}: the report must still be attempted once`)
}
console.log("ok Q4 log failures are swallowed")

console.log("all opencode-plugin node cases passed")

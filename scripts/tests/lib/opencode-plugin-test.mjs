// opencode-plugin-test.sh の node 側。build が生成した plugin (marker 行つき) を import し、
// server(fakeCtx, {timeoutMs, termGraceMs}) が返す hooks (入口) 経由で、safe-gh の注記、品質ループ
// (fast-edit-check / changed-scope-qa)、fail-open、timeout の止め方 (#467)、init の目印の行 (#343) を確かめる。
// 使い方: node opencode-plugin-test.mjs <generated plugin.js> <personal-safe-gh-hook.rb>
//           <personal-fast-edit-check.rb> <personal-changed-scope-qa.rb> <work dir>
//           <生成物の marker の build_id> <scripts/lib/plugin_marker.rb>
// HOME は case ごとに process.env.HOME で tmp の home に向ける (plugin は os.homedir() から
// script を解決する)。check の宣言は AGENT_TOOLS_CHECKS_CONFIG で tmp の file に向け、XDG の dir も
// tmp に向ける。実物の tool home は読まない。
import { spawnSync } from "node:child_process"
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const [pluginPath, safeGhSource, fastEditSource, qaSource, workDir, expectedBuildId, pluginMarkerLib] = process.argv.slice(2)
if (!pluginPath || !safeGhSource || !fastEditSource || !qaSource || !workDir || !expectedBuildId || !pluginMarkerLib) {
  console.error("usage: node opencode-plugin-test.mjs <plugin.js> <personal-safe-gh-hook.rb> <personal-fast-edit-check.rb> <personal-changed-scope-qa.rb> <work dir> <build_id> <plugin_marker.rb>")
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
// init の目印の行 (#343。公開契約: docs/boundary-with-dotfiles.md)。fake client は、この語で始まる
// message を init の行として calls と分けて inits に数える (既存の件数の assertion は init の行を含めない)。
const INIT_WORD = "agent-tools:plugin-init"
const INIT_PREFIX = `${INIT_WORD} v=1`
const UNKNOWN_BUILD_ID = "unknown"
const SHORT_TIMEOUT_MS = 500
const REAL_TIMEOUT_MS = 20000
const DEADLINE_MARGIN_MS = 1500
const KILL_SETTLE_MS = 300
// timeout の止め方 (#467) の case の猶予。SHORT は猶予を待ち切る case、LONG は待たずに終わるべき case に使う。
const SHORT_GRACE_MS = 1000
const LONG_GRACE_MS = 4000
// 既定の猶予 (docs の契約。plugin の TERM_GRACE_MS)。P9 は単調時計を進めて、この前後で KILL の有無を見る。
const DEFAULT_GRACE_MS = 10000
// P9 で時計を合わせる位置: 既定の猶予の GRACE_EDGE_MS 手前で GRACE_EDGE_OBSERVE_MS (確認が数回通る長さ) 見て
// から、GRACE_EDGE_MS 先へ進める。
const GRACE_EDGE_MS = 1000
const GRACE_EDGE_OBSERVE_MS = 300
// P11 で Date.now を進める量 (system の時計の補正の再現)。猶予 (SHORT_GRACE_MS) よりずっと大きい。
const CLOCK_JUMP_MS = 60000
// hook が返った後、node の process が終わるまでの許容 (timer が残れば猶予の残りぶん待つ)。
const EXIT_LAG_MS = 1000
const ORIGINAL_OUTPUT = "original tool output\nline 2"

function fail(msg) {
  console.error(`FAIL: ${msg}`)
  process.exit(1)
}

// log の失敗 (reject) を plugin が握り損ねたら、ここで落とす (Node の既定でも落ちるが、理由を明示する)。
process.on("unhandledRejection", (reason) => fail(`unhandled rejection (a log failure must be swallowed): ${reason && reason.stack ? reason.stack : reason}`))

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

// timeout の止め方 (#467) の fixture の body。TERM を受けたら cwd の term.log に 1 行書いて終わる親が、同じ group
// に子 (寿命は有限) を 1 つ起動し、親と子の pid を cwd の leaders.pids / children.pids に足す。引数 warmup では
// 何もせずに終わる (下の P7 の前の warm-up 用。plugin は引数を渡さない)。
function termScript(startChild) {
  return `#!/bin/sh\ncase "$1" in warmup) exit 0 ;; esac\ntrap 'echo term >> term.log; exit 0' TERM\necho $$ >> leaders.pids\n${startChild}\necho $! >> children.pids\nwait\n`
}

// 記録用 script の 1 行: <script>\t<sentinel か unset>\t<AGENT_TOOLS_CHECKS_CONFIG か unset>
const ENV_SENTINEL = "OPENCODE_PLUGIN_TEST_SENTINEL"
function envLine(script) {
  return `printf '%s\\t%s\\t%s\\n' ${script} "\${${ENV_SENTINEL}-unset}" "\${AGENT_TOOLS_CHECKS_CONFIG-unset}" >> "$HOME/env.log"\n`
}

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
  // timeout の止め方 (#467)。termClean の子は TERM で終わる。termIgnorer の子は TERM を無視し、stdio を閉じて
  // 残る (親が TERM で終わると、group に member が居ても close が先に来る形)。
  termClean: makeHome("term-clean", termScript("sleep 15 &"), 0o755),
  termIgnorer: makeHome("term-ignorer", termScript("( trap '' TERM; exec sleep 15 ) </dev/null >/dev/null 2>&1 &"), 0o755),
  // 起動と payload / env / cwd を $HOME の下に記録する (出力なしの exit 0)。env.log には、許可外の
  // sentinel と AGENT_TOOLS_CHECKS_CONFIG が子 process から見えるかを script ごとに書く。
  // changed-scope-qa は実行中の idle を skip することを確かめるため少し寝る。
  recorder: makeHome("recorder", `#!/bin/sh\ncat > /dev/null\n${envLine(SAFE_GH)}`, 0o755, {
    [FAST_EDIT]: `#!/bin/sh\ncat >> "$HOME/edit-payloads.log"\necho >> "$HOME/edit-payloads.log"\n${envLine(FAST_EDIT)}`,
    [QA]: `#!/bin/sh\nprintf '%s\\t%s\\t%s\\n' "$AGENT_TOOLS_QA_STATE_DIR" "$(pwd -P)" "$(cat)" >> "$HOME/qa-starts.log"\n${envLine(QA)}sleep 0.3\n`,
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

function isInitLog(arg) {
  return arg.body.message.startsWith(INIT_WORD)
}

// app.log の mode: "ok" / "throw" / "reject" / "pending" (決して settle しない)。init の行は inits に、
// それ以外は calls に記録する (どちらも throw / reject の前に記録するので「試みた」回数になる)。
// session.get: parents[id] があればその parentID を持つ子 session として返す。waits[id] があれば、
// その promise が解決するまで返さない (lookup の遅れを再現する)。getMode: "ok" / "throw" / "empty" (data が無い)。
function makeClient(mode, { parents = {}, waits = {}, getMode = "ok" } = {}) {
  const calls = []
  const inits = []
  const log = (arg) => {
    assertLogShape(arg)
    ;(isInitLog(arg) ? inits : calls).push(arg)
    if (mode === "throw") throw new Error("fake app.log throws")
    if (mode === "reject") return Promise.reject(new Error("fake app.log rejects"))
    if (mode === "pending") return new Promise(() => {})
    return Promise.resolve({ data: true })
  }
  const get = async (arg) => {
    const id = arg && arg.path ? arg.path.id : undefined
    assert(typeof id === "string" && id !== "", `session.get must be called with {path: {id}}, got ${JSON.stringify(arg)}`)
    if (waits[id]) await waits[id]
    if (getMode === "throw") throw new Error("fake session.get throws")
    if (getMode === "empty") return { data: undefined }
    return { data: parents[id] === undefined ? { id } : { id, parentID: parents[id] } }
  }
  return {
    calls,
    inits,
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

// init の行の期待値 (契約の形そのもの。token は単一の空白区切りでこの順)。
function initMessage(buildId) {
  return `${INIT_PREFIX} name=${SERVICE} build_id=${buildId}`
}

// client が受けた init の行が count 件で、どれも契約の形 (level info / service / message) か。
function assertInits(client, count, buildId, label) {
  assert(client.inits.length === count, `${label}: expected ${count} init line(s), got ${client.inits.length}: ${JSON.stringify(client.inits)}`)
  for (const call of client.inits) {
    assert(call.body.level === "info", `${label}: the init line must be level info, got ${JSON.stringify(call.body.level)}`)
    assert(call.body.service === SERVICE, `${label}: the init line must be service ${SERVICE}, got ${JSON.stringify(call.body.service)}`)
    assert(call.body.message === initMessage(buildId), `${label}: the init line must be ${JSON.stringify(initMessage(buildId))}, got ${JSON.stringify(call.body.message)}`)
    assert(Object.keys(call.body).sort().join(",") === "level,message,service", `${label}: the init line must carry only service / level / message, got ${JSON.stringify(call.body)}`)
  }
}

// server() は 1 回の呼び出し (= directory の instance 1 つ) ごとに init の行を 1 行だけ出す。
async function makeHooks(client, options, directory = ctxDir) {
  const ctx = { client, directory, worktree: directory, project: { id: "p1" } }
  const before = client.inits.length
  let hooks
  try {
    hooks = await plugin.server(ctx, options)
  } catch (error) {
    fail(`server() must not throw for valid options (a log failure must be swallowed): ${error && error.stack ? error.stack : error}`)
  }
  assertInits(client, before + 1, expectedBuildId, "server()")
  return hooks
}

// 読込 (module の評価) が throw しないことも契約 (build_id の読み取りは fail-open)。
async function importPlugin(url, label) {
  try {
    return (await import(url)).default
  } catch (error) {
    fail(`${label}: importing the plugin must not throw (the build_id read must be fail-open): ${error && error.stack ? error.stack : error}`)
  }
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
  for (const termGraceMs of [-1, 0, Number.NaN, Number.POSITIVE_INFINITY, "1"]) {
    let rejected = false
    try {
      await plugin.server({ client, directory: ctxDir }, { termGraceMs })
    } catch (error) {
      rejected = error instanceof TypeError
    }
    assert(rejected, `P1: server must reject options.termGraceMs=${String(termGraceMs)} with TypeError`)
  }
  // throw した server() は init の行を出さない (最初の makeHooks の 1 行だけが残る)。
  assertInits(client, 1, expectedBuildId, "P1 (a server() that throws must not log the init line)")
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

// --- P7-P10: timeout の止め方 (#467)。group に TERM → group が空になるまで最大 termGraceMs → KILL ---------------
// 経路は 3 本の script で共通 (spawnScript) なので safe-gh で確かめ、直列の契約だけ changed-scope-qa (Q5) で見る。
// fixture は cwd (= ctxDir) に書く。case の終わりに、記録した pid を待って残りを KILL し、記録を消す。
const TERM_LOG = join(ctxDir, "term.log")
const LEADER_PIDS = join(ctxDir, "leaders.pids")
const CHILD_PIDS = join(ctxDir, "children.pids")

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function isAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error.code !== "ESRCH"
  }
}

async function waitFor(predicate, ms) {
  const deadline = Date.now() + ms
  while (!predicate()) {
    if (Date.now() >= deadline) return false
    await sleep(20)
  }
  return true
}

// 記録した pid が KILL_SETTLE_MS 以内に消えるのを待ってから、fixture の記録 (TERM を受けた回数・起動した親と子の
// 数) と残っていた pid を返す。残りは KILL し、記録は消す (次の case に持ち越さない)。
async function settleGroup() {
  const pids = [...readLines(LEADER_PIDS), ...readLines(CHILD_PIDS)].map(Number)
  await waitFor(() => !pids.some(isAlive), KILL_SETTLE_MS)
  const record = { terms: readLines(TERM_LOG).length, leaders: readLines(LEADER_PIDS).length, children: readLines(CHILD_PIDS).length }
  const alive = pids.filter(isAlive)
  for (const pid of alive) process.kill(pid, "SIGKILL")
  for (const file of [TERM_LOG, LEADER_PIDS, CHILD_PIDS]) rmSync(file, { force: true })
  return { ...record, alive }
}

// 新しく書いた script の初回の実行は遅いことがある (2026-10-10 の macOS の実測で 90〜720 ms。2 回目からは数 ms)。
// trap を置く前に TERM が届かないように、timeout の case で使う fixture の script を 1 回ずつ実行しておく。
for (const home of [homes.termClean, homes.termIgnorer]) {
  for (const name of Object.keys(SCRIPT_SOURCES)) {
    const res = spawnSync(join(home, ...SCRIPTS_DIR, name), ["warmup"])
    assert(res.status === 0, `warm-up of ${name} in ${home} must exit 0, got ${res.status} ${res.error}`)
  }
}

// timeout の warn は今と同じ文言で 1 回だけ。
function assertTimeoutWarn(client, script, timeoutMs, consequence, label) {
  assertWarns(client, 1, label)
  const want = `${script}: timed out after ${timeoutMs} ms; ${consequence} (fail-open)`
  assert(client.calls[0].body.message === want, `${label}: the timeout warn must stay ${JSON.stringify(want)}, got ${JSON.stringify(client.calls[0].body.message)}`)
}

// 停止を確認できないときの warn は、固定の文と理由を足す (#476 review)。
function assertUnconfirmedWarn(client, script, timeoutMs, detail, consequence, label) {
  assertWarns(client, 1, label)
  const want = `${script}: timed out after ${timeoutMs} ms; its process group may not have stopped (${detail}); ${consequence} (fail-open)`
  assert(client.calls[0].body.message === want, `${label}: the warn must be ${JSON.stringify(want)}, got ${JSON.stringify(client.calls[0].body.message)}`)
}

// body の間だけ、group 宛て (pid が負) の process.kill のうち faults に挙げた signal は、送らずに faults[signal] の
// code の error を throw させる (EPERM / 想定外の失敗の再現)。signal 0 と pid が正のものはそのまま通す。
async function withGroupKillFaults(faults, body) {
  const realKill = process.kill
  process.kill = (pid, signal) => {
    if (pid < 0 && Object.hasOwn(faults, signal)) throw Object.assign(new Error(`injected ${faults[signal]}`), { code: faults[signal] })
    return realKill.call(process, pid, signal)
  }
  try {
    return await body()
  } finally {
    process.kill = realKill
  }
}

// P7: TERM で後始末して終わる script は、group が空と分かった時点で終わる (猶予を待たず、KILL まで行かない)。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS }, termGraceMs: LONG_GRACE_MS })
  const output = toolOutput()
  const started = Date.now()
  await runAfter(hooks, homes.termClean, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + LONG_GRACE_MS + DEADLINE_MARGIN_MS, "P7")
  const elapsed = Date.now() - started
  const { terms, alive } = await settleGroup()
  assert(terms === 1, `P7: the timed-out script must receive SIGTERM once, got ${terms} term.log line(s)`)
  assert(elapsed >= SHORT_TIMEOUT_MS - 50, `P7: resolved before the timeout (${elapsed} ms)`)
  assert(elapsed < SHORT_TIMEOUT_MS + LONG_GRACE_MS / 2, `P7: a group emptied by SIGTERM must not wait for the grace (${elapsed} ms)`)
  assert(alive.length === 0, `P7: the group must be empty, but ${alive.join(", ")} survived`)
  assert(output.output === ORIGINAL_OUTPUT, "P7: output must be unchanged")
  assertTimeoutWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "the tool result was left unchanged", "P7")
  console.log("ok P7 a group that SIGTERM empties ends the timeout without the grace")
}

// P8: 親は TERM で終わり、TERM を無視する子が stdio を閉じて残る (close は先に来る)。group が空になるまで待ち、
// 猶予を過ぎたら KILL で子も消す。reject は KILL を送った後。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS }, termGraceMs: SHORT_GRACE_MS })
  const output = toolOutput()
  const started = Date.now()
  await runAfter(hooks, homes.termIgnorer, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + SHORT_GRACE_MS + DEADLINE_MARGIN_MS, "P8")
  const elapsed = Date.now() - started
  const { terms, children, alive } = await settleGroup()
  assert(children === 1, `P8: the fixture must start one child, got ${children}`)
  assert(terms === 1, `P8: the parent must receive SIGTERM once, got ${terms} term.log line(s)`)
  assert(elapsed >= SHORT_TIMEOUT_MS + SHORT_GRACE_MS - 50, `P8: must not resolve before the grace ends while the group has members (${elapsed} ms)`)
  assert(alive.length === 0, `P8: SIGKILL after the grace must remove the child that ignores SIGTERM, but ${alive.join(", ")} survived`)
  assert(output.output === ORIGINAL_OUTPUT, "P8: output must be unchanged")
  assertTimeoutWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "the tool result was left unchanged", "P8")
  console.log("ok P8 a child that ignores SIGTERM is killed after the grace, before the timeout resolves")
}

// P9: termGraceMs を渡さなければ既定の猶予 (10 秒) を待つ。猶予を計る単調時計 (performance.now) を test が
// 進め、10 秒の手前では KILL せず、10 秒を過ぎたら次の確認で KILL することを、実時間で 10 秒待たずに確かめる。
// 時計は TERM の後に進める (plugin は TERM の時点の実時間で期限を決めている)。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS } })
  const output = toolOutput()
  let resolved = false
  const pending = runAfter(hooks, homes.termIgnorer, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS * 3, "P9").then(() => {
    resolved = true
  })
  const termed = await waitFor(() => readLines(TERM_LOG).length > 0, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS)
  const children = readLines(CHILD_PIDS).map(Number)
  const realNow = performance.now
  let offset = DEFAULT_GRACE_MS - GRACE_EDGE_MS
  performance.now = () => realNow.call(performance) + offset
  let beforeEdge
  let afterEdge
  try {
    await sleep(GRACE_EDGE_OBSERVE_MS)
    beforeEdge = { resolved, alive: children.filter(isAlive).length }
    offset = DEFAULT_GRACE_MS + GRACE_EDGE_MS
    afterEdge = await waitFor(() => resolved, DEADLINE_MARGIN_MS)
  } finally {
    performance.now = realNow
  }
  // 変異 (既定の猶予が長い) で返らないときに test を止めないよう、残った子を消して後始末を終わらせる。
  for (const pid of children.filter(isAlive)) process.kill(pid, "SIGKILL")
  await pending
  const { alive } = await settleGroup()
  assert(termed && children.length === 1, `P9: the parent must receive SIGTERM after starting one child (fixture assumption), got ${termed} / ${children.length}`)
  assert(!beforeEdge.resolved && beforeEdge.alive === 1, `P9: ${GRACE_EDGE_MS} ms before the default grace (${DEFAULT_GRACE_MS} ms) ends, the child must not be killed yet, got ${JSON.stringify(beforeEdge)}`)
  assert(afterEdge, `P9: once the default grace (${DEFAULT_GRACE_MS} ms) has passed, the next check must send SIGKILL and resolve`)
  assert(alive.length === 0, `P9: nothing must be left, but ${alive.join(", ")} survived`)
  assert(output.output === ORIGINAL_OUTPUT, "P9: output must be unchanged")
  assertTimeoutWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "the tool result was left unchanged", "P9")
  console.log("ok P9 the default grace is 10 s on the monotonic clock")
}

// P10: 後始末が済んだら timer を残さない (OpenCode の process を待たせない)。別の node で plugin を読み、TERM で
// 終わる script の timeout を 1 回起こし、hook が返った後に node が猶予の残りを待たずに終わることを確かめる。
{
  const helper = join(workDir, "timer-leak-helper.mjs")
  writeFileSync(helper, `import { pathToFileURL } from "node:url"
const [pluginPath, directory, timeoutMs, graceMs] = process.argv.slice(2)
const plugin = (await import(pathToFileURL(pluginPath).href)).default
const warns = []
const client = { app: { log: ({ body }) => { if (body.level === "warn") warns.push(body.message); return Promise.resolve({}) } } }
const hooks = await plugin.server({ client, directory }, { timeoutMs: { safeGh: Number(timeoutMs) }, termGraceMs: Number(graceMs) })
const output = { title: "t", output: "unchanged", metadata: {} }
const started = Date.now()
await hooks["tool.execute.after"]({ tool: "bash", sessionID: "s1", callID: "c1", args: { command: "gh issue view 1" } }, output)
const resolvedAt = Date.now()
console.log(JSON.stringify({ elapsed: resolvedAt - started, resolvedAt, warns, output: output.output }))
`)
  const res = spawnSync(process.execPath, [helper, pluginPath, ctxDir, String(SHORT_TIMEOUT_MS), String(LONG_GRACE_MS)], {
    env: { ...process.env, HOME: homes.termClean },
    encoding: "utf8",
    timeout: SHORT_TIMEOUT_MS + LONG_GRACE_MS + DEADLINE_MARGIN_MS * 2,
  })
  const exitedAt = Date.now()
  const { alive } = await settleGroup()
  assert(res.status === 0, `P10: the helper node must exit 0, got ${res.status} ${res.signal}: ${res.stderr}`)
  const report = JSON.parse(res.stdout)
  assert(report.warns.length === 1 && report.warns[0].startsWith(`${SAFE_GH}: timed out after`), `P10: the helper must hit the timeout once (fixture assumption), got ${JSON.stringify(report.warns)}`)
  assert(report.output === "unchanged", "P10: output must be unchanged")
  assert(report.elapsed < SHORT_TIMEOUT_MS + LONG_GRACE_MS / 2, `P10: the group must be emptied by SIGTERM (fixture assumption, ${report.elapsed} ms)`)
  assert(exitedAt - report.resolvedAt < EXIT_LAG_MS, `P10: node must exit right after the hook resolves (no timer left), but it took ${exitedAt - report.resolvedAt} ms`)
  assert(alive.length === 0, `P10: nothing must be left, but ${alive.join(", ")} survived`)
  console.log("ok P10 no timer is left after the cleanup")
}

// P11: 猶予は単調時計で計る (#476 review)。TERM の直後に Date.now を大きく進めても (system の時計の補正)、TERM を
// 無視する子は猶予の間は KILL されず、呼び出しは猶予の後に返る。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS }, termGraceMs: SHORT_GRACE_MS })
  const output = toolOutput()
  const started = performance.now()
  let resolved = false
  const pending = runAfter(hooks, homes.termIgnorer, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + SHORT_GRACE_MS + DEADLINE_MARGIN_MS, "P11").then(() => {
    resolved = true
  })
  const termed = await waitFor(() => readLines(TERM_LOG).length > 0, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS)
  const children = readLines(CHILD_PIDS).map(Number)
  const realDateNow = Date.now
  Date.now = () => realDateNow() + CLOCK_JUMP_MS
  let midGrace
  try {
    await sleep(SHORT_GRACE_MS / 2)
    midGrace = { resolved, alive: children.filter(isAlive).length }
  } finally {
    Date.now = realDateNow
  }
  await pending
  const elapsed = performance.now() - started
  const { alive } = await settleGroup()
  assert(termed && children.length === 1, `P11: the parent must receive SIGTERM after starting one child (fixture assumption), got ${termed} / ${children.length}`)
  assert(!midGrace.resolved && midGrace.alive === 1, `P11: a forward jump of Date.now must not cut the grace short, got ${JSON.stringify(midGrace)} at mid-grace`)
  assert(elapsed >= SHORT_TIMEOUT_MS + SHORT_GRACE_MS - 50, `P11: must not resolve before the grace ends (${Math.round(elapsed)} ms)`)
  assert(alive.length === 0, `P11: SIGKILL after the grace must remove the child, but ${alive.join(", ")} survived`)
  assertTimeoutWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "the tool result was left unchanged", "P11")
  console.log("ok P11 the grace is measured on the monotonic clock, not Date.now")
}

// P12: TERM / KILL を送れない (EPERM) とき (#476 review)。KILL を送れず members が残れば、warn に「停止を確認できない」
// と理由を足す。TERM を送れなくても、猶予の後の KILL で group が空と確かめられたら通常の warn のまま。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS }, termGraceMs: SHORT_GRACE_MS })
  const output = toolOutput()
  await withGroupKillFaults({ SIGKILL: "EPERM" }, () =>
    runAfter(hooks, homes.termIgnorer, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + SHORT_GRACE_MS + DEADLINE_MARGIN_MS * 2, "P12 SIGKILL EPERM"),
  )
  const { terms, alive } = await settleGroup()
  assert(terms === 1, `P12 SIGKILL EPERM: SIGTERM must still be sent (fixture assumption), got ${terms} term.log line(s)`)
  assert(alive.length === 1, `P12 SIGKILL EPERM: the child must be left as the plugin could not kill it (fixture assumption), got ${alive.length}`)
  assert(output.output === ORIGINAL_OUTPUT, "P12 SIGKILL EPERM: output must be unchanged")
  assertUnconfirmedWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "SIGKILL EPERM, members remained after SIGKILL", "the tool result was left unchanged", "P12 SIGKILL EPERM")
}
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS }, termGraceMs: SHORT_GRACE_MS })
  const output = toolOutput()
  await withGroupKillFaults({ SIGTERM: "EPERM" }, () =>
    runAfter(hooks, homes.termIgnorer, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + SHORT_GRACE_MS + DEADLINE_MARGIN_MS * 2, "P12 SIGTERM EPERM"),
  )
  const { terms, alive } = await settleGroup()
  assert(terms === 0, `P12 SIGTERM EPERM: SIGTERM must not reach the script (fixture assumption), got ${terms} term.log line(s)`)
  assert(alive.length === 0, `P12 SIGTERM EPERM: SIGKILL after the grace must still empty the group, but ${alive.join(", ")} survived`)
  assert(output.output === ORIGINAL_OUTPUT, "P12 SIGTERM EPERM: output must be unchanged")
  assertTimeoutWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "the tool result was left unchanged", "P12 SIGTERM EPERM (a stop confirmed by SIGKILL keeps the usual warn)")
  console.log("ok P12 EPERM on SIGTERM / SIGKILL is reported only when the stop is not confirmed")
}

// P13: 想定外の失敗 (EPERM / ESRCH 以外) では後始末をやめ、どの signal で失敗したかを「停止を確認できない」の理由に
// 載せる。猶予は待たない。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: SHORT_TIMEOUT_MS }, termGraceMs: SHORT_GRACE_MS })
  const output = toolOutput()
  const started = performance.now()
  await withGroupKillFaults({ SIGTERM: "EINVAL" }, () =>
    runAfter(hooks, homes.termIgnorer, bashInput("gh issue view 1"), output, SHORT_TIMEOUT_MS + SHORT_GRACE_MS + DEADLINE_MARGIN_MS, "P13"),
  )
  const elapsed = performance.now() - started
  await settleGroup()
  assert(elapsed < SHORT_TIMEOUT_MS + SHORT_GRACE_MS / 2, `P13: an unexpected failure must end the cleanup without the grace (${Math.round(elapsed)} ms)`)
  assert(output.output === ORIGINAL_OUTPUT, "P13: output must be unchanged")
  assertUnconfirmedWarn(client, SAFE_GH, SHORT_TIMEOUT_MS, "SIGTERM EINVAL", "the tool result was left unchanged", "P13")
  console.log("ok P13 an unexpected kill failure is reported as an unconfirmed stop")
}

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

// E8: 同名の 2 file (a/index.rb と b/index.rb) が path を含まない同じ出力で失敗しても、要約は file ごとに
// repo 相対 path の label で区別され、2 件とも足される (#431 の 4)。label が basename だと 2 件が同文になり、
// E3 の重複除去 (設定エラーのための 1 回だけ) に潰されて 1 件しか届かず、どの file かも分からない。
// editRepo は mktemp の symlink 越しの path (macOS の /var → /private/var) なので、label が repo root
// (git が realpath で返す) 基準で相対になることも同時に確かめる。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { fastEditCheck: REAL_TIMEOUT_MS } }, editRepo)
  const files = ["a", "b"].map((dir) => {
    mkdirSync(join(editRepo, dir), { recursive: true })
    const file = join(editRepo, dir, "index.rb")
    writeFileSync(file, "puts 1\n")
    return file
  })
  setCheckFails(true)
  const expected = files.map((file) => expectedEditContext(file))
  const before = readLines(checkLog).length
  const output = toolOutput({ files: files.map((filePath) => ({ filePath, type: "update" })) })
  await runAfter(hooks, homes.real, patchInput(), output, REAL_TIMEOUT_MS, "E8 same basename")
  setCheckFails(false)
  for (const [i, rel] of ["a/index.rb", "b/index.rb"].entries()) {
    assert(expected[i] !== null && expected[i].startsWith(`fast-edit-check: ${rel} への編集`), `E8: the summary for ${files[i]} must be labeled with the repo-relative path ${rel}, got: ${expected[i]}`)
  }
  const ran = readLines(checkLog).slice(before)
  assert(JSON.stringify(ran) === JSON.stringify(files), `E8: both files must be checked, got ${JSON.stringify(ran)}`)
  assert(output.output === `${ORIGINAL_OUTPUT}\n\n${expected.join("\n\n")}`, `E8: both same-basename summaries must be appended, got: ${JSON.stringify(output.output)}`)
  assert(client.calls.length === 0, `E8: no warn expected, got ${client.calls.length}`)
  console.log("ok E8 same-basename failures are kept apart by their repo-relative labels")
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

// Q2b: 実行中に来た idle は、親子の判定 (session.get) を待つ間に前の実行が終わっても、後から起動しない。
{
  const starts = join(homes.recorder, "qa-starts.log")
  let release
  const held = new Promise((resolve) => {
    release = resolve
  })
  const client = makeClient("ok", { waits: { late: held } })
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: REAL_TIMEOUT_MS } }, qaRepo)
  const before = readLines(starts).length
  process.env.HOME = homes.recorder
  const first = hooks.event({ event: idle() })
  await new Promise((resolve) => setTimeout(resolve, 100))
  const second = hooks.event({ event: idle("late") })
  await withDeadline(first, REAL_TIMEOUT_MS, "Q2b first")
  release()
  await withDeadline(second, REAL_TIMEOUT_MS, "Q2b second")
  assert(readLines(starts).length === before + 1, `Q2b: an idle that arrived while running must not start later, got ${readLines(starts).length - before} start(s)`)
  assert(client.calls.length === 0, `Q2b: no log expected, got ${JSON.stringify(client.calls)}`)
  console.log("ok Q2b an idle that arrived while running is skipped even if its lookup resolves later")
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

// Q5: timeout の後始末の間 (猶予中) も実行中に含める (#467)。その間に来た idle では起動せず、warn は後始末の後に 1 回。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { changedScopeQa: SHORT_TIMEOUT_MS }, termGraceMs: SHORT_GRACE_MS })
  process.env.HOME = homes.termIgnorer
  const started = Date.now()
  const first = hooks.event({ event: idle() })
  const termed = await waitFor(() => readLines(TERM_LOG).length > 0, SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS)
  const secondAt = Date.now() - started
  await runEvent(hooks, homes.termIgnorer, idle(), DEADLINE_MARGIN_MS, "Q5 idle during the grace")
  await withDeadline(first, SHORT_TIMEOUT_MS + SHORT_GRACE_MS + DEADLINE_MARGIN_MS, "Q5 first")
  const elapsed = Date.now() - started
  const { leaders, alive } = await settleGroup()
  assert(termed, "Q5: the timed-out script must receive SIGTERM (fixture assumption)")
  assert(secondAt < SHORT_TIMEOUT_MS + SHORT_GRACE_MS, `Q5: the second idle must arrive within the grace (fixture assumption, ${secondAt} ms)`)
  assert(leaders === 1, `Q5: an idle during the cleanup grace must not start the script again, got ${leaders} start(s)`)
  assert(elapsed >= SHORT_TIMEOUT_MS + SHORT_GRACE_MS - 50, `Q5: the run must stay running until the cleanup ends (${elapsed} ms)`)
  assert(alive.length === 0, `Q5: nothing must be left, but ${alive.join(", ")} survived`)
  assertTimeoutWarn(client, QA, SHORT_TIMEOUT_MS, "no changed-scope-qa report was made", "Q5")
  console.log("ok Q5 an idle during the cleanup grace does not start a second run")
}

// V1: 子 process の env は絞る。許可外の sentinel は 3 本のどれからも見えず、AGENT_TOOLS_CHECKS_CONFIG は
// 渡り、changed-scope-qa の state dir は親の AGENT_TOOLS_QA_STATE_DIR ではなく plugin の値になる。
{
  const envLog = join(homes.recorder, "env.log")
  const starts = join(homes.recorder, "qa-starts.log")
  rmSync(envLog, { force: true })
  process.env[ENV_SENTINEL] = "leaked"
  process.env.AGENT_TOOLS_QA_STATE_DIR = join(workDir, "parent-qa-state")
  const client = makeClient("ok")
  const hooks = await makeHooks(client, { timeoutMs: { safeGh: REAL_TIMEOUT_MS, fastEditCheck: REAL_TIMEOUT_MS, changedScopeQa: REAL_TIMEOUT_MS } }, qaRepo)
  await runAfter(hooks, homes.recorder, bashInput("gh issue view 1"), toolOutput(), REAL_TIMEOUT_MS, "V1 safe-gh")
  await runAfter(hooks, homes.recorder, editInput("edit", join(qaRepo, "base.txt")), toolOutput(), REAL_TIMEOUT_MS, "V1 fast-edit-check")
  const startsBefore = readLines(starts).length
  await runEvent(hooks, homes.recorder, idle(), REAL_TIMEOUT_MS, "V1 changed-scope-qa")
  delete process.env[ENV_SENTINEL]
  delete process.env.AGENT_TOOLS_QA_STATE_DIR

  const lines = readLines(envLog).map((line) => line.split("\t"))
  assert(JSON.stringify(lines.map(([script]) => script)) === JSON.stringify([SAFE_GH, FAST_EDIT, QA]), `V1: each script must record its env once, got ${JSON.stringify(lines)}`)
  for (const [script, sentinel, checksConfig] of lines) {
    assert(sentinel === "unset", `V1: ${script} must not see ${ENV_SENTINEL} (got ${sentinel})`)
    assert(checksConfig === configs.fake, `V1: ${script} must see AGENT_TOOLS_CHECKS_CONFIG=${configs.fake}, got ${checksConfig}`)
  }
  const [stateDir] = readLines(starts)[startsBefore].split("\t")
  assert(stateDir === qaStateDir(homes.recorder), `V1: the plugin state dir must win over the parent's, got ${stateDir}`)
  assert(client.calls.length === 0, `V1: no log expected, got ${JSON.stringify(client.calls)}`)
  console.log("ok V1 child processes get only the allowed env")
}

// === 目印: shell.env (#295 PR 3a) ==============================================================

// S1: 目印は model の bash (記録専用の before で覚えた callID) にだけ立ち、`!` (callID はあるが before を
// 通らない) と PTY (sessionID も callID も無い) には立たない。model の bash では他の agent の目印を空にする。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, {})
  assert(typeof hooks["shell.env"] === "function", "S1: shell.env must be registered")
  const leaked = () => ({ CLAUDECODE: "1", CODEX_THREAD_ID: "thread", CODEX_SANDBOX: "seatbelt", KEEP: "keep" })
  const runEnv = async (input, output, label) => {
    try {
      await withDeadline(hooks["shell.env"](input, output), DEADLINE_MARGIN_MS, label)
    } catch (error) {
      fail(`${label}: shell.env must not throw: ${error && error.stack ? error.stack : error}`)
    }
  }
  const runBefore = async (input, args, label) => {
    try {
      await withDeadline(hooks["tool.execute.before"](input, { args }), DEADLINE_MARGIN_MS, label)
    } catch (error) {
      fail(`${label}: tool.execute.before must not throw: ${error}`)
    }
  }

  const args = { command: "git commit -m x" }
  await runBefore({ tool: "bash", sessionID: "s1", callID: "model-1" }, args, "S1 before model bash")
  assert(args.command === "git commit -m x", "S1: before must not rewrite args")
  const model = { env: leaked() }
  await runEnv({ cwd: ctxDir, sessionID: "s1", callID: "model-1" }, model, "S1 model bash")
  assert(model.env.AGENT_TOOLS_OPENCODE === "1", `S1: the marker must be set for the model bash, got ${JSON.stringify(model.env)}`)
  for (const name of ["CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX"]) {
    assert(model.env[name] === "", `S1: ${name} must be emptied for the model bash, got ${JSON.stringify(model.env[name])}`)
  }
  assert(model.env.KEEP === "keep", "S1: other env must be left as is")

  const bang = { env: leaked() }
  await runEnv({ cwd: ctxDir, sessionID: "s1", callID: "bang-1" }, bang, "S1 bang")
  assert(JSON.stringify(bang.env) === JSON.stringify(leaked()), `S1: \`!\` (callID without before) must not be touched, got ${JSON.stringify(bang.env)}`)
  const pty = { env: leaked() }
  await runEnv({ cwd: ctxDir }, pty, "S1 pty")
  assert(JSON.stringify(pty.env) === JSON.stringify(leaked()), `S1: PTY (no callID) must not be touched, got ${JSON.stringify(pty.env)}`)

  await runBefore({ tool: "read", sessionID: "s1", callID: "read-1" }, { filePath: "x" }, "S1 before read")
  const read = { env: leaked() }
  await runEnv({ cwd: ctxDir, sessionID: "s1", callID: "read-1" }, read, "S1 other tool")
  assert(read.env.AGENT_TOOLS_OPENCODE === undefined, "S1: only the bash tool may be marked")

  await runAfter(hooks, homes.missing, { tool: "bash", sessionID: "s1", callID: "model-1", args }, toolOutput(), DEADLINE_MARGIN_MS, "S1 after")
  const again = { env: leaked() }
  await runEnv({ cwd: ctxDir, sessionID: "s1", callID: "model-1" }, again, "S1 after forget")
  assert(again.env.AGENT_TOOLS_OPENCODE === undefined, "S1: a finished bash call must be forgotten")
  assert(client.calls.length === 0, `S1: no warn expected, got ${JSON.stringify(client.calls)}`)
  console.log("ok S1 the marker is set only for the model bash, and foreign markers are emptied")
}

// S3: 記録は (sessionID, callID) の組。callID は provider の ID で session をまたいで一意とは限らない。
// 別 session の同じ callID の終了で記録が消えず、別 session の同じ callID の `!` には立たない。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, {})
  const before = (sessionID, callID) => hooks["tool.execute.before"]({ tool: "bash", sessionID, callID }, { args: { command: "ls" } })
  const env = async (input) => {
    const output = { env: { CLAUDECODE: "1" } }
    await hooks["shell.env"](input, output)
    return output.env
  }
  await before("s1", "dup")
  await before("s2", "dup")
  await runAfter(hooks, homes.missing, { tool: "bash", sessionID: "s1", callID: "dup", args: { command: "ls" } }, toolOutput(), DEADLINE_MARGIN_MS, "S3 after s1")
  const s2 = await env({ cwd: ctxDir, sessionID: "s2", callID: "dup" })
  assert(s2.AGENT_TOOLS_OPENCODE === "1" && s2.CLAUDECODE === "", `S3: finishing s1 must not forget s2's call with the same callID, got ${JSON.stringify(s2)}`)
  const s1 = await env({ cwd: ctxDir, sessionID: "s1", callID: "dup" })
  assert(s1.AGENT_TOOLS_OPENCODE === undefined && s1.CLAUDECODE === "1", `S3: s1's finished call must be forgotten, got ${JSON.stringify(s1)}`)
  const bang = await env({ cwd: ctxDir, sessionID: "s3", callID: "dup" })
  assert(bang.AGENT_TOOLS_OPENCODE === undefined && bang.CLAUDECODE === "1", `S3: \`!\` in another session with the same callID must not be marked, got ${JSON.stringify(bang)}`)
  const noSession = await env({ cwd: ctxDir, callID: "dup" })
  assert(noSession.AGENT_TOOLS_OPENCODE === undefined, "S3: a call without sessionID must not be marked")
  assert(client.calls.length === 0, `S3: no warn expected, got ${JSON.stringify(client.calls)}`)
  console.log("ok S3 records are keyed by (sessionID, callID)")
}

// S2: shell.env の中で例外が起きても throw しない (env が無い・凍結・getter が throw、input が無い)。
{
  const client = makeClient("ok")
  const hooks = await makeHooks(client, {})
  await hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1", callID: "model-2" }, { args: { command: "ls" } })
  const cases = [
    ["no env", { cwd: ctxDir, sessionID: "s1", callID: "model-2" }, {}],
    ["frozen env", { cwd: ctxDir, sessionID: "s1", callID: "model-2" }, { env: Object.freeze({ CLAUDECODE: "1" }) }],
    ["throwing getter", { cwd: ctxDir, sessionID: "s1", callID: "model-2" }, Object.defineProperty({}, "env", { get() { throw new Error("boom") } })],
    ["no input", undefined, { env: {} }],
  ]
  for (const [label, input, output] of cases) {
    try {
      await withDeadline(hooks["shell.env"](input, output), DEADLINE_MARGIN_MS, `S2 ${label}`)
    } catch (error) {
      fail(`S2 ${label}: shell.env must not throw: ${error}`)
    }
  }
  for (const input of [undefined, null, { tool: "bash" }]) {
    try {
      await withDeadline(hooks["tool.execute.before"](input, { args: {} }), DEADLINE_MARGIN_MS, "S2 before")
    } catch (error) {
      fail(`S2: tool.execute.before must not throw for ${JSON.stringify(input)}: ${error}`)
    }
  }
  // 凍結された env と throw する getter は同じ hook の失敗なので warn は 1 回だけ。
  assertWarns(client, 1, "S2 shell.env failures")
  console.log("ok S2 shell.env and before never throw")
}

// === init の目印の行 (#343。公開契約: docs/boundary-with-dotfiles.md) ===========================

// I1: server() が return まで到達したら init の行を 1 行だけ出す。hook をどれだけ呼んでも増えず、
// server() を呼ぶ (= directory の instance を作る) たびに 1 行。build_id は生成物の marker の値。
{
  const client = makeClient("ok")
  const short = { timeoutMs: { safeGh: SHORT_TIMEOUT_MS, fastEditCheck: SHORT_TIMEOUT_MS, changedScopeQa: SHORT_TIMEOUT_MS } }
  const hooks = await makeHooks(client, short)
  await withDeadline(hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1", callID: "i1" }, { args: { command: "gh issue view 1" } }), DEADLINE_MARGIN_MS, "I1 before")
  await withDeadline(hooks["shell.env"]({ cwd: ctxDir, sessionID: "s1", callID: "i1" }, { env: {} }), DEADLINE_MARGIN_MS, "I1 shell.env")
  await runAfter(hooks, homes.missing, { ...bashInput("gh issue view 1"), callID: "i1" }, toolOutput(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, "I1 after")
  await runAfter(hooks, homes.missing, editInput("edit", join(editRepo, "a.rb")), toolOutput(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, "I1 edit")
  await runEvent(hooks, homes.missing, idle(), SHORT_TIMEOUT_MS + DEADLINE_MARGIN_MS, "I1 idle")
  assertWarns(client, 3, "I1 (each hook script warns once; fixture assumption)")
  assertInits(client, 1, expectedBuildId, "I1 (the hooks must not log the init line again)")
  await makeHooks(client, {}, editRepo)
  assertInits(client, 2, expectedBuildId, "I1 (a second directory instance logs its own line)")
  console.log("ok I1 the init line is logged once per server() with the marker build_id")
}

// I2: server() が途中で throw したら init の行を出さない (options の誤り)。
{
  const client = makeClient("ok")
  for (const options of [{ timeoutMs: 5 }, { timeoutMs: { safeGh: 0 } }, { timeoutMs: { fastEditCheck: Number.NaN } }, { timeoutMs: { changedScopeQa: "1" } }, { termGraceMs: 0 }]) {
    let threw = false
    try {
      await plugin.server({ client, directory: ctxDir }, options)
    } catch {
      threw = true
    }
    assert(threw, `I2: server() must throw for ${JSON.stringify(options)} (fixture assumption)`)
  }
  assertInits(client, 0, expectedBuildId, "I2 (a server() that throws must not log the init line)")
  assert(client.calls.length === 0, `I2: no log expected, got ${JSON.stringify(client.calls)}`)
  console.log("ok I2 a server() that throws logs no init line")
}

// I3: log の失敗は fail-open。app.log が throw / reject / settle しない、client が無い・形が違うときも
// server() は log を待たずに hooks を返し、hooks は普段どおり動く。
{
  const expected = expectedContext("gh issue view 1")
  const assertWorks = async (hooks, label) => {
    assert(hooks && typeof hooks["tool.execute.after"] === "function", `${label}: server() must still return the hooks`)
    const output = toolOutput()
    await runAfter(hooks, homes.real, bashInput("gh issue view 1"), output, 5000 + DEADLINE_MARGIN_MS, label)
    assert(output.output === `${expected}\n\n${ORIGINAL_OUTPUT}`, `${label}: the hooks must work as usual, got ${JSON.stringify(output.output)}`)
  }
  const serverWithin = async (client, label) => {
    try {
      return await withDeadline(plugin.server({ client, directory: ctxDir }, { timeoutMs: { safeGh: 5000 } }), DEADLINE_MARGIN_MS, label)
    } catch (error) {
      fail(`${label}: server() must neither throw nor wait for the log: ${error && error.stack ? error.stack : error}`)
    }
  }
  for (const mode of ["throw", "reject", "pending"]) {
    const client = makeClient(mode)
    const hooks = await serverWithin(client, `I3 app.log ${mode}`)
    assertInits(client, 1, expectedBuildId, `I3 app.log ${mode} (attempted once)`)
    await assertWorks(hooks, `I3 app.log ${mode}`)
  }
  for (const [label, client] of [["no client", undefined], ["no app", {}], ["log is not a function", { app: { log: "x" } }]]) {
    await assertWorks(await serverWithin(client, `I3 ${label}`), `I3 ${label}`)
  }
  // reject を握り損ねていれば、ここまでに unhandledRejection で落ちる (1 tick 以上待つ)。
  await new Promise((resolve) => setTimeout(resolve, 50))
  console.log("ok I3 log failures do not break server() or the hooks")
}

// I4: build_id は配置された file の 1 行目の marker から読む。marker の形は scripts/lib/plugin_marker.rb
// (PluginMarker.owned) と同じで、加えて build_id は生成の形 (sha256: + 64 桁の小文字 hex) に限る。
// それ以外 (marker が無い・形が違う・別の name / target・読めない) は unknown。各 variant の期待値は、
// 同じ file を Ruby の PluginMarker.owned で読んだ結果からも導けることを確かめる (2 つの解析の drift の検出)。
{
  const generated = readFileSync(pluginPath)
  const newline = generated.indexOf(0x0a)
  const markerLine = generated.subarray(0, newline).toString("utf8")
  const rest = generated.subarray(newline)
  const otherBuildId = `sha256:${"ab".repeat(32)}`
  const line = (text) => Buffer.concat([Buffer.from(text, "utf8"), rest])
  const replaced = (from, to) => {
    assert(markerLine.includes(from), `I4: the marker line must contain ${JSON.stringify(from)} (fixture assumption): ${markerLine}`)
    return line(markerLine.replace(from, to))
  }
  const [beforeSource, afterSource] = markerLine.split("source=shared/")
  const variants = [
    ["copy (control)", generated, expectedBuildId],
    ["another valid build_id", replaced(`build_id=${expectedBuildId}`, `build_id=${otherBuildId}`), otherBuildId],
    ["no marker", rest.subarray(1), UNKNOWN_BUILD_ID],
    ["marker on line 2", Buffer.concat([Buffer.from("// first\n"), generated]), UNKNOWN_BUILD_ID],
    ["BOM before the marker", Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), generated]), UNKNOWN_BUILD_ID],
    ["CR before the newline", line(`${markerLine}\r`), UNKNOWN_BUILD_ID],
    ["trailing space", line(`${markerLine} `), UNKNOWN_BUILD_ID],
    ["tab", replaced(" repo=", "\trepo="), UNKNOWN_BUILD_ID],
    ["C0 control in a value", replaced("source=shared/", "source=shared/\u0001"), UNKNOWN_BUILD_ID],
    ["C1 control in a value", replaced("source=shared/", "source=shared/\u0085"), UNKNOWN_BUILD_ID],
    ["double space", replaced(" repo=", "  repo="), UNKNOWN_BUILD_ID],
    ["other name", replaced(`name=${SERVICE}`, "name=personal-other"), UNKNOWN_BUILD_ID],
    ["other target", replaced("target=opencode", "target=codex"), UNKNOWN_BUILD_ID],
    ["other version", replaced("v=1", "v=2"), UNKNOWN_BUILD_ID],
    ["other repo", replaced("repo=agent-tools", "repo=other"), UNKNOWN_BUILD_ID],
    ["other artifact_kind", replaced("artifact_kind=plugin", "artifact_kind=skill"), UNKNOWN_BUILD_ID],
    ["absolute source", replaced("source=shared/", "source=/shared/"), UNKNOWN_BUILD_ID],
    ["extra key", replaced(" */", " extra=1 */"), UNKNOWN_BUILD_ID],
    ["missing key", replaced(" repo=agent-tools", ""), UNKNOWN_BUILD_ID],
    ["duplicate key", replaced(" repo=agent-tools", " repo=agent-tools repo=agent-tools"), UNKNOWN_BUILD_ID],
    ["empty value", replaced("target=opencode", "target="), UNKNOWN_BUILD_ID],
    ["build_id not sha256", replaced(`build_id=${expectedBuildId}`, "build_id=md5:abc"), UNKNOWN_BUILD_ID],
    // 以下 2 つは Ruby の parse は通すが、生成の形 (64 桁の小文字 hex) ではないので unknown。
    ["short build_id", replaced(`build_id=${expectedBuildId}`, "build_id=sha256:abc"), UNKNOWN_BUILD_ID],
    ["uppercase build_id", replaced(`build_id=${expectedBuildId}`, `build_id=sha256:${expectedBuildId.slice(7).toUpperCase()}`), UNKNOWN_BUILD_ID],
    ["invalid UTF-8", Buffer.concat([Buffer.from(`${beforeSource}source=shared/`, "utf8"), Buffer.from([0xff]), Buffer.from(afterSource, "utf8"), rest]), UNKNOWN_BUILD_ID],
  ]
  const files = variants.map(([, bytes], index) => {
    const dir = join(workDir, "variants", String(index))
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "package.json"), '{"type":"module"}\n')
    const file = join(dir, "personal-agent-tools.js")
    writeFileSync(file, bytes)
    return file
  })

  // Ruby の解析 (実装の PluginMarker.owned) で同じ file を読み、plugin が出すべき値を導く。
  const ruby = spawnSync("ruby", ["-r", pluginMarkerLib, "-e", `
    ARGV.each do |path|
      marker = PluginMarker.owned(File.binread(path), target: "opencode", name: ${JSON.stringify(SERVICE)})
      puts(marker ? marker["build_id"] : "nil")
    end
  `, ...files], { encoding: "utf8" })
  assert(ruby.status === 0, `I4: the Ruby parser failed: ${ruby.stderr}`)
  const rubyIds = ruby.stdout.split("\n").filter((l) => l !== "")
  assert(rubyIds.length === files.length, `I4: the Ruby parser must answer for each variant, got ${JSON.stringify(rubyIds)}`)

  for (const [index, [label, , want]] of variants.entries()) {
    const derived = /^sha256:[0-9a-f]{64}$/.test(rubyIds[index]) ? rubyIds[index] : UNKNOWN_BUILD_ID
    assert(derived === want, `I4 ${label}: the expectation must follow PluginMarker.owned + the generated form (ruby: ${rubyIds[index]}, want: ${want})`)
    const variant = await importPlugin(pathToFileURL(files[index]).href, `I4 ${label}`)
    const client = makeClient("ok")
    await variant.server({ client, directory: ctxDir }, {})
    assertInits(client, 1, want, `I4 ${label}`)
  }

  // file として読めない (import.meta.url が file: でない) ときも unknown で、server() は通る。
  const fromData = await importPlugin(`data:text/javascript;base64,${generated.toString("base64")}`, "I4 not a file (data: URL)")
  const client = makeClient("ok")
  await fromData.server({ client, directory: ctxDir }, {})
  assertInits(client, 1, UNKNOWN_BUILD_ID, "I4 not a file (data: URL)")
  console.log("ok I4 the build_id comes from the deployed file's own marker, otherwise unknown")
}

// I5: build_id は module を読み込んだ時点の file から読む。読み込んだ後に file が置き換わっても
// (sync が新しい版を置いた)、同じ process の後の server() は読み込み済みの code の build_id を出す。
{
  const dir = join(workDir, "variants", "reloaded")
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, "package.json"), '{"type":"module"}\n')
  const file = join(dir, "personal-agent-tools.js")
  const generated = readFileSync(pluginPath)
  writeFileSync(file, generated)
  const loaded = await importPlugin(pathToFileURL(file).href, "I5")
  writeFileSync(file, generated.toString("utf8").replace(`build_id=${expectedBuildId}`, `build_id=sha256:${"cd".repeat(32)}`))
  const client = makeClient("ok")
  await loaded.server({ client, directory: ctxDir }, {})
  await loaded.server({ client, directory: editRepo }, {})
  assertInits(client, 2, expectedBuildId, "I5 (the build_id read when the module was loaded)")
  console.log("ok I5 the build_id is the one read when the module was loaded")
}

console.log("all opencode-plugin node cases passed")

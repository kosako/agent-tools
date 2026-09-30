// personal-agent-tools: OpenCode plugin (v1 形 `export default { id, server }`)。
// Spec: docs/runtime-injection-defense.md「PreToolUse hook」節の OpenCode parity、
//       docs/quality-loop-hooks.md「OpenCode」節、adapters/opencode/README.md (#295)。
//
// 役割は薄い adapter に限る。判定は Claude Code / Codex と同じ Ruby の hook script
// (~/.claude/agent-tools/scripts/ に配った personal-*) を無改変で呼び、その返す文言を
// 載せるだけ。文言も判定も JS では持たない (2 系統の判定が drift しないため)。
// - safe-gh: bash の gh コマンドの後、personal-safe-gh-hook の注記を tool 結果の先頭に載せる。
// - 品質ループ: 編集の後、personal-fast-edit-check の失敗要約を tool 結果の末尾に足す。
//   session.idle で personal-changed-scope-qa を report-only で呼び、結果を log にだけ出す。
//
// 強度ラベル (偽らない): steering / fail-open であって enforcement ではない。OpenCode に
// 実行前の steer は無いので、注記は実行が済んだ後の同じ tool 結果に載る (model には届くが、
// TUI の人の目には入らない)。changed-scope-qa は model を続けさせない (Stop のように終了を
// 止める仕組みが OpenCode に無く、prompt を送る API は使わない)。置けばそのまま有効になり、
// `--pure` で外せる。
//
// fail-open の理由: OpenCode は hook の例外を隔離しないので、after の hook が throw すると
// 実行が済んでいても tool call が error になる。そのため hook は決して throw せず、script が
// 無い / 実行できない / 非 0 / stdout が JSON でない / timeout のどれでも tool 結果を
// そのまま返し、warn を script ごとに 1 回だけ client.app.log に出す。
//
// 依存: node:child_process / node:os / node:path だけ (外部 package なし)。Bun 専用の API と
// `$` (BunShell) は使わず、子 process は argv 配列 + stdin で起動する (shell: true は使わない)。
// 名前付き export は置かない (legacy の loader は名前付き export をすべて plugin 関数とみなす)。
import { spawn } from "node:child_process"
import { homedir } from "node:os"
import { isAbsolute, join, resolve } from "node:path"

const ID = "personal-agent-tools"

// hook script の配置先。Claude Code target に配った script を既定の claude home から解決する
// (custom の claude home には対応しない。docs 参照)。
const SCRIPTS_DIR_SEGMENTS = [".claude", "agent-tools", "scripts"]
const SAFE_GH_SCRIPT = "personal-safe-gh-hook"
const FAST_EDIT_CHECK_SCRIPT = "personal-fast-edit-check"
const CHANGED_SCOPE_QA_SCRIPT = "personal-changed-scope-qa"

// timeout の既定 (ms)。safe-gh は Codex の hook 登録と同じ 10 秒。fast-edit-check は 1 回の
// after で編集された file 全体に対する総予算 (Codex では 1 patch に起動も timeout も 1 回なので
// それに合わせる)。options.timeoutMs はこれより短くする方向だけ受け付ける (既定との min)。
const DEFAULT_TIMEOUT_MS = Object.freeze({ safeGh: 10000, fastEditCheck: 30000, changedScopeQa: 120000 })

// 子 process に渡す env は最低限に絞る (script の起動に PATH、home の解決に HOME、Ruby の
// encoding に LANG 系、check 宣言の場所の上書きに AGENT_TOOLS_CHECKS_CONFIG。最後のものは
// Claude Code / Codex の hook が env ごと継承して読むので揃える)。token 等の secret は渡さない。
const CHILD_ENV_NAMES = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "AGENT_TOOLS_CHECKS_CONFIG"]

// safe-gh-hook の prefilter。script の判定 (command word が gh) の上位集合なので、ここで
// 落とすことで見逃しは増えない。
const SAFE_GH_NEEDLE = "gh"

// 編集系 tool (M3) と、fast-edit-check に渡す Claude 形の tool_name。apply_patch は Codex 形の
// payload (patch の本文) を要するので渡さず、after の metadata から取った file ごとに Edit として渡す。
const EDIT_TOOL_NAMES = Object.freeze({ edit: "Edit", write: "Write", apply_patch: "Edit" })

// changed-scope-qa の state は Claude / Codex と分ける。script は「scope ごとに 1 回だけの block」を
// state に記録するので、共有すると model に届かない OpenCode の実行がその 1 回を先に使ってしまう。
const QA_STATE_DIR_ENV = "AGENT_TOOLS_QA_STATE_DIR"
const QA_STATE_DIR_SEGMENTS = [".cache", "agent-tools", "changed-scope-qa-opencode"]

function childEnv(extra) {
  const env = {}
  for (const name of CHILD_ENV_NAMES) {
    if (typeof process.env[name] === "string") env[name] = process.env[name]
  }
  return { ...env, ...extra }
}

function scriptPath(name) {
  return join(homedir(), ...SCRIPTS_DIR_SEGMENTS, name)
}

// options.timeoutMs.<key> は既定より短い正の有限値だけを採る。それ以外の値は options の
// 渡し方の誤りなので、hook ではなく server() の時点で fail fast する (file plugin として
// 読まれるときは options が渡らないので、ここで throw しても OpenCode の起動には関わらない)。
function resolveTimeout(options, key) {
  const table = options ? options.timeoutMs : undefined
  if (table === undefined) return DEFAULT_TIMEOUT_MS[key]
  if (typeof table !== "object" || table === null) {
    throw new TypeError(`${ID}: options.timeoutMs must be an object`)
  }
  const given = table[key]
  if (given === undefined) return DEFAULT_TIMEOUT_MS[key]
  if (typeof given !== "number" || !Number.isFinite(given) || given <= 0) {
    throw new TypeError(`${ID}: options.timeoutMs.${key} must be a positive finite number`)
  }
  return Math.min(given, DEFAULT_TIMEOUT_MS[key])
}

class ScriptFailure extends Error {
  constructor(script, reason) {
    super(`${script}: ${reason}`)
    this.script = script
  }
}

// hook script を起動し、終わったら {code, signal, stdout, stderr} で resolve する。起動できない
// ときと timeout だけを ScriptFailure で reject する (exit code の解釈は呼び出し側が持つ)。
// detached: true で process group を分け、timeout では group ごと SIGKILL する (script が
// 起動した孫 process を残さないため)。
function spawnScript(script, payload, { cwd, timeoutMs, env }) {
  return new Promise((resolve, reject) => {
    const child = spawn(scriptPath(script), [], {
      cwd,
      env: childEnv(env),
      stdio: "pipe",
      detached: true,
    })
    let stdout = ""
    let stderr = ""
    let settled = false
    let timer
    const settle = (fn, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      fn(value)
    }
    timer = setTimeout(() => {
      try {
        process.kill(-child.pid, "SIGKILL")
      } catch {
        // 既に終わっていれば ESRCH。timeout の扱いは変わらない。
      }
      settle(reject, new ScriptFailure(script, `timed out after ${timeoutMs} ms`))
    }, timeoutMs)

    child.on("error", (error) => settle(reject, new ScriptFailure(script, `cannot start (${error.code || error.message})`)))
    child.stdout.setEncoding("utf8")
    child.stdout.on("data", (chunk) => {
      stdout += chunk
    })
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      stderr += chunk
    })
    child.on("close", (code, signal) => settle(resolve, { code, signal, stdout, stderr }))
    // 子が読む前に終わると EPIPE が error event で来る。close 側の判定に任せる。
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify(payload))
  })
}

function exitFailure(script, { code, signal }) {
  return new ScriptFailure(script, `exited with ${signal ? `signal ${signal}` : `code ${code}`}`)
}

// hook script の stdout の JSON。steer しないとき script は何も出さずに exit 0 で終わる (正常な
// no-op) ので、空なら null。
function parseStdout(script, stdout) {
  if (stdout.trim() === "") return null
  try {
    return JSON.parse(stdout)
  } catch {
    throw new ScriptFailure(script, "stdout is not JSON")
  }
}

// PostToolUse 形の hook script (safe-gh-hook / fast-edit-check) を起動して stdout の JSON を返す。
// exit 0 以外はすべて失敗で、fail-open の握り方は呼び出し側 (hook) に集める。
async function runScript(script, payload, opts) {
  const result = await spawnScript(script, payload, opts)
  if (result.code !== 0) throw exitFailure(script, result)
  return parseStdout(script, result.stdout)
}

function additionalContext(result) {
  const out = result && typeof result === "object" ? result.hookSpecificOutput : undefined
  const ctx = out && typeof out === "object" ? out.additionalContext : undefined
  return typeof ctx === "string" ? ctx : null
}

// changed-scope-qa の結果を人向けの報告にする。exit 2 は Stop の block (stderr に要約)、exit 0 の
// systemMessage はユーザー向けの警告。どちらも OpenCode では model に返さず人に見せるだけ。
function qaReport(result) {
  if (result.code === 2) {
    const message = result.stderr.trimEnd()
    if (message === "") throw new ScriptFailure(CHANGED_SCOPE_QA_SCRIPT, "exited with code 2 without a message")
    return { level: "error", message }
  }
  if (result.code !== 0) throw exitFailure(CHANGED_SCOPE_QA_SCRIPT, result)
  const parsed = parseStdout(CHANGED_SCOPE_QA_SCRIPT, result.stdout)
  const message = parsed && typeof parsed === "object" ? parsed.systemMessage : undefined
  return typeof message === "string" && message !== "" ? { level: "warn", message } : null
}

function qaStateDir() {
  return join(homedir(), ...QA_STATE_DIR_SEGMENTS)
}

async function server(input, options) {
  const timeoutMs = {
    safeGh: resolveTimeout(options, "safeGh"),
    fastEditCheck: resolveTimeout(options, "fastEditCheck"),
    changedScopeQa: resolveTimeout(options, "changedScopeQa"),
  }
  const cwd = typeof input.directory === "string" ? input.directory : undefined
  const client = input.client
  const warned = new Set()
  // changed-scope-qa の実行中の印。server() は directory ごとに呼ばれるので、instance に 1 つ。
  let qaRunning = false

  // client が無い / log が throw・reject する場合も握る (log の失敗で hook を落とさない)。
  function log(level, message) {
    try {
      const pending = client.app.log({ body: { service: ID, level, message } })
      if (pending && typeof pending.then === "function") pending.then(undefined, () => {})
    } catch {
      // fail-open: log を出せないことは hook の結果に影響させない。
    }
  }

  // warn は script ごとに 1 回だけ (script 以外の想定外の失敗は hook 名を key にする)。
  function warnOnce(key, message) {
    if (warned.has(key)) return
    warned.add(key)
    log("warn", message)
  }

  // hook の本体を包む。hook は決して throw しない (after の throw は済んだ tool call を error にする)。
  async function failOpen(key, consequence, body) {
    try {
      await body()
    } catch (error) {
      warnOnce(error instanceof ScriptFailure ? error.script : key, `${String(error && error.message)}; ${consequence} (fail-open)`)
    }
  }

  // safe-gh: bash の gh コマンドが実行された後、script の additionalContext を結果の先頭に
  // 載せる。元の出力は "\n\n" の後ろに残す (切り詰めでは先頭が残るので注記を先に置く)。
  async function annotateSafeGh(input, output) {
    if (input.tool !== "bash") return
    const command = input.args ? input.args.command : undefined
    if (typeof command !== "string" || !command.includes(SAFE_GH_NEEDLE)) return
    if (typeof output.output !== "string") return

    const payload = { tool_name: "Bash", tool_input: { command } }
    const result = await runScript(SAFE_GH_SCRIPT, payload, { cwd, timeoutMs: timeoutMs.safeGh })
    const ctx = additionalContext(result)
    if (ctx === null) return
    output.output = `${ctx}\n\n${output.output}`
  }

  // 編集された file の絶対 path (M3)。edit / write は args.filePath (directory 基準で解決)、
  // apply_patch は after の metadata.files のうち delete 以外 (move は移動先)。metadata が無ければ
  // patch の本文は parse しない。
  function editedFiles(input, output) {
    if (input.tool === "apply_patch") {
      const files = output.metadata ? output.metadata.files : undefined
      if (!Array.isArray(files)) return []
      const paths = files
        .filter((file) => file && typeof file === "object" && file.type !== "delete")
        .map((file) => file.movePath ?? file.filePath)
      return [...new Set(paths.filter((path) => typeof path === "string" && isAbsolute(path)))]
    }
    const filePath = input.args ? input.args.filePath : undefined
    if (typeof filePath !== "string" || filePath === "") return []
    if (isAbsolute(filePath)) return [filePath]
    return cwd === undefined ? [] : [resolve(cwd, filePath)]
  }

  // fast-edit-check: 成功した編集の後、file ごとに script を直列に呼び、失敗要約を結果の末尾に
  // 足す (編集系の結果は短く、元の結果を先に読ませたい)。1 file の失敗は warn して次の file に
  // 進み、総予算を使い切ったら残りの file は check しない。
  async function checkEdits(input, output) {
    const toolName = Object.hasOwn(EDIT_TOOL_NAMES, input.tool) ? EDIT_TOOL_NAMES[input.tool] : undefined
    if (toolName === undefined) return
    if (typeof output.output !== "string") return

    const files = editedFiles(input, output)
    const deadline = Date.now() + timeoutMs.fastEditCheck
    const messages = []
    for (const [index, file] of files.entries()) {
      const remaining = deadline - Date.now()
      if (remaining <= 0) {
        warnOnce(FAST_EDIT_CHECK_SCRIPT, `${FAST_EDIT_CHECK_SCRIPT}: the ${timeoutMs.fastEditCheck} ms budget ran out; ${files.length - index} edited file(s) were not checked (fail-open)`)
        break
      }
      const payload = { hook_event_name: "PostToolUse", tool_name: toolName, tool_input: { file_path: file } }
      try {
        const ctx = additionalContext(await runScript(FAST_EDIT_CHECK_SCRIPT, payload, { cwd, timeoutMs: remaining }))
        if (ctx !== null && !messages.includes(ctx)) messages.push(ctx)
      } catch (error) {
        if (!(error instanceof ScriptFailure)) throw error
        warnOnce(FAST_EDIT_CHECK_SCRIPT, `${error.message}; that edited file was not checked (fail-open)`)
      }
    }
    if (messages.length > 0) output.output += `\n\n${messages.join("\n\n")}`
  }

  // task の子 session の idle も同じ directory に届く (M9)。子の途中で親の変更 scope を検査しない。
  async function isChildSession(sessionID) {
    if (typeof sessionID !== "string" || sessionID === "") throw new Error("session.idle without a sessionID")
    const res = await client.session.get({ path: { id: sessionID } })
    const info = res ? res.data : undefined
    if (!info || typeof info !== "object") throw new Error(`session ${sessionID} was not found`)
    return typeof info.parentID === "string" && info.parentID !== ""
  }

  // changed-scope-qa: session.idle で report-only に呼ぶ。Stop の block (exit 2) も警告も
  // client.app.log にだけ出し、model を続けさせる API (session.prompt 等) も toast も使わない
  // (1.18.30 の TUI は toast を描かない: M17)。実行中に来た idle は skip する。実行中の印は最初の
  // await より前に取り、親子の判定も含めて持つ (判定を待つ間に前の実行が終わっても、後から起動しない)。
  async function reportChangedScope(event) {
    if (!event || event.type !== "session.idle") return
    // 検査対象は directory の working tree。OpenCode の process の cwd を代わりに使わない。
    if (cwd === undefined) throw new Error("the plugin input has no directory")
    if (qaRunning) return
    qaRunning = true
    try {
      if (await isChildSession(event.properties ? event.properties.sessionID : undefined)) return
      const payload = { hook_event_name: "Stop", stop_hook_active: false }
      const env = { [QA_STATE_DIR_ENV]: qaStateDir() }
      const report = qaReport(await spawnScript(CHANGED_SCOPE_QA_SCRIPT, payload, { cwd, timeoutMs: timeoutMs.changedScopeQa, env }))
      if (report !== null) log(report.level, report.message)
    } finally {
      qaRunning = false
    }
  }

  return {
    "tool.execute.after": async (input, output) => {
      await failOpen("tool.execute.after", "the tool result was left unchanged", () => annotateSafeGh(input, output))
      await failOpen("tool.execute.after", "the tool result was left unchanged", () => checkEdits(input, output))
    },
    // OpenCode は event hook を待たないが、処理の promise を返す (test から await できるように)。
    event: (input) => failOpen("event", "no changed-scope-qa report was made", () => reportChangedScope(input ? input.event : undefined)),
  }
}

export default { id: ID, server }

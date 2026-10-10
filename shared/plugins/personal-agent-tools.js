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
// - 目印: model の bash の env に AGENT_TOOLS_OPENCODE=1 を立て、他の agent の目印
//   (CLAUDECODE / CODEX_THREAD_ID / CODEX_SANDBOX) を空にする。personal-ai-trailer-gate が
//   OpenCode の commit を見分けるため (docs/git-hook-gates.md)。人が打つ `!` と PTY には立てない。
// - init の目印: server() が hooks を組み終えた時点で、固定の接頭辞の INFO 行を 1 回だけ client.app.log に
//   出す (#343)。dotfiles の doctor が「OpenCode が plugin を読み込んで init を終えたか」を log から
//   確かめるための公開契約 (docs/boundary-with-dotfiles.md「OpenCode plugin の init の目印」)。
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
// 依存: node:child_process / node:fs / node:os / node:path / node:url だけ (外部 package なし)。Bun 専用の
// API と `$` (BunShell) は使わず、子 process は argv 配列 + stdin で起動する (shell: true は使わない)。
// 名前付き export は置かない (legacy の loader は名前付き export をすべて plugin 関数とみなす)。
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { isAbsolute, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

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

// timeout の後始末の猶予 (ms)。group に TERM を送ってから group が空になるのを最大この長さ待ち、members が
// 残っていれば KILL を送る。hook script の子 (hook が check の起動に使う safe-run) が check を止めて回収し
// 終えられるように、safe-run の後始末の最悪 (約 8 秒) より長くする (#467)。options.termGraceMs はこれより
// 短くする方向だけ受け付ける (既定との min)。
const TERM_GRACE_MS = 10000
// 猶予の間に group が空になったかを確かめる間隔 (ms)。
const GROUP_POLL_MS = 100
// KILL の後に group が空になるのを確かめる長さ (ms)。KILL された member は親 (孤児なら launchd / init) に
// 回収されるまで group に残る (2026-10-10 の macOS の実測で 20 ms 以内)。過ぎても members が残れば、停止を
// 確認できないと伝える。
const KILL_CONFIRM_MS = 1000

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

// OpenCode の目印 (personal-ai-trailer-gate の OPENCODE_MARKER と対)。OpenCode 自身の OPENCODE=1 は
// `!` / PTY / 内部の git にも載るので使わない (#295 の M5)。
const OPENCODE_MARKER = "AGENT_TOOLS_OPENCODE"
// 他の agent の目印。herdr の pane や Claude の session の中から起動した OpenCode では漏れうるので、
// model の bash では空にする (shell.env の output.env は string の Record で、変数を消せない。gate は
// 空の値を目印とみなさない)。
const FOREIGN_MARKERS = ["CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX"]
// 目印を立てる callID の記録の上限 (after が呼ばれない失敗で記録が残っても、増え続けないように)。
const MODEL_BASH_CALLS_MAX = 256

// init の目印の行 (#343)。message は `agent-tools:plugin-init v=1 name=<ID> build_id=<sha256:… か unknown>`
// の 1 行で、token は単一の空白区切りでこの順。形を変えるときは v を上げる (旧い reader が新しい形を
// 目印とみなさず、未確認に倒れるように)。
const INIT_LINE_PREFIX = "agent-tools:plugin-init v=1"
const UNKNOWN_BUILD_ID = "unknown"

// 配置された file の 1 行目の管理 marker (scripts/lib/plugin_marker.rb の PluginMarker.render が build で
// 前置する形)。解析は PluginMarker.owned と同じ規則 (先頭行だけ・単一の空白区切りの key=value・key の
// 重複なし・必須 key と完全一致・制御文字と不正な UTF-8 の行は拒否・name と target が自分) で、build_id は
// さらに生成の形 (sha256: + 64 桁の小文字 hex) に限る。どれかに外れれば unknown。
const MARKER_PREFIX = "/* agent-tools:managed "
const MARKER_SUFFIX = " */"
const MARKER_KEYS = ["artifact_kind", "build_id", "name", "repo", "source", "target", "v"]
const MARKER_FIXED = Object.freeze({ v: "1", repo: "agent-tools", artifact_kind: "plugin", name: ID, target: "opencode" })
const BUILD_ID_FORM = /^sha256:[0-9a-f]{64}$/
// Ruby の [[:cntrl:]] (Unicode の Cc) と同じ範囲。
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/

// content (bytes) の先頭行が自分の marker なら build_id を、そうでなければ null を返す。不正な UTF-8 は
// TextDecoder が throw する (呼び出し側が unknown に倒す)。BOM は剥がさない (Ruby と同じく拒否する)。
function markerBuildId(content) {
  const end = content.indexOf(0x0a)
  const first = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(end === -1 ? content : content.subarray(0, end))
  if (CONTROL_CHARS.test(first)) return null
  if (!first.startsWith(MARKER_PREFIX) || !first.endsWith(MARKER_SUFFIX)) return null
  const pairs = new Map()
  for (const token of first.slice(MARKER_PREFIX.length, -MARKER_SUFFIX.length).split(" ")) {
    const eq = token.indexOf("=")
    if (eq <= 0 || eq === token.length - 1) return null
    const key = token.slice(0, eq)
    if (pairs.has(key)) return null
    pairs.set(key, token.slice(eq + 1))
  }
  if ([...pairs.keys()].sort().join(" ") !== MARKER_KEYS.join(" ")) return null
  for (const [key, value] of Object.entries(MARKER_FIXED)) {
    if (pairs.get(key) !== value) return null
  }
  if (pairs.get("source").startsWith("/")) return null
  const buildId = pairs.get("build_id")
  return BUILD_ID_FORM.test(buildId) ? buildId : null
}

// 自分の file (import.meta.url) を読み、marker の build_id を返す。module の評価の中で 1 回だけ呼ぶので、
// 読み込んだ時点の file の値になる (同じ process で後から sync が file を置き換えても、読み込み済みの
// code の build_id を出し続ける)。ここで throw すると plugin の読込ごと失敗するので、例外は外に出さず
// unknown に倒す (file でない URL・読めない・marker が無い / 形が違う)。
function deployedBuildId() {
  try {
    return markerBuildId(readFileSync(fileURLToPath(import.meta.url))) ?? UNKNOWN_BUILD_ID
  } catch {
    return UNKNOWN_BUILD_ID
  }
}

const BUILD_ID = deployedBuildId()

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

// options の時間 (ms) は既定より短い正の有限値だけを採る (undefined は既定)。それ以外の値は options の
// 渡し方の誤りなので、hook ではなく server() の時点で fail fast する (file plugin として
// 読まれるときは options が渡らないので、ここで throw しても OpenCode の起動には関わらない)。
function shorterThanDefault(name, given, defaultMs) {
  if (given === undefined) return defaultMs
  if (typeof given !== "number" || !Number.isFinite(given) || given <= 0) {
    throw new TypeError(`${ID}: options.${name} must be a positive finite number`)
  }
  return Math.min(given, defaultMs)
}

function resolveTimeout(options, key) {
  const table = options ? options.timeoutMs : undefined
  if (table === undefined) return DEFAULT_TIMEOUT_MS[key]
  if (typeof table !== "object" || table === null) {
    throw new TypeError(`${ID}: options.timeoutMs must be an object`)
  }
  return shorterThanDefault(`timeoutMs.${key}`, table[key], DEFAULT_TIMEOUT_MS[key])
}

function resolveTermGrace(options) {
  return shorterThanDefault("termGraceMs", options ? options.termGraceMs : undefined, TERM_GRACE_MS)
}

class ScriptFailure extends Error {
  constructor(script, reason) {
    super(`${script}: ${reason}`)
    this.script = script
  }
}

// process group に signal を送る。"sent" (届いた) / "empty" (ESRCH。group が空) / "denied" (EPERM。送れない
// member が居る。macOS の kill(2) は group の中に送れない member が 1 つでもあれば EPERM) を返す。それ以外の
// 失敗は、どの signal で起きたかを message にして throw する (呼び出し側が停止を確認できないと伝える)。
function signalGroup(pgid, signal) {
  try {
    process.kill(-pgid, signal)
    return "sent"
  } catch (error) {
    if (error.code === "ESRCH") return "empty"
    if (error.code === "EPERM") return "denied"
    throw new Error(`${signal === 0 ? "signal 0" : signal} ${error.code || error.message}`, { cause: error })
  }
}

// GROUP_POLL_MS ごとに signal 0 で確かめ、ms 以内に group が空になれば true (signal 0 の EPERM は members が
// 居る扱い)。時間は単調時計 (performance.now) で計る。Date.now だと system の時計の補正で猶予が縮み
// (後始末中の子を KILL してしまう)、逆向きの補正では延びる。
async function waitForEmptyGroup(pgid, ms) {
  const deadline = performance.now() + ms
  while (performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, GROUP_POLL_MS))
    if (signalGroup(pgid, 0) === "empty") return true
  }
  return false
}

// timeout の後始末: group に TERM を送り、graceMs まで group が空になるのを待ち、members が残っていれば KILL を
// 送って、空になるのを KILL_CONFIRM_MS まで確かめる。終わりは close ではなく group が空かどうかで決める
// (script が TERM で終わっても、TERM を無視する子が stdio を閉じて残りうる)。script (leader) は plugin の
// process が回収するので、pgid は members が居る間だけ有効。KILL は members が居ると確かめた直後に送る (その
// 間に group が空になり、番号が別の group に再利用される窓は残る)。group が空と確かめられたら null、確かめ
// られなければ理由 (送れなかった signal と、KILL の後も members が残ったこと) を返す。
async function stopGroup(pgid, graceMs) {
  const denied = []
  const send = (signal) => {
    const result = signalGroup(pgid, signal)
    if (result === "denied") denied.push(`${signal} EPERM`)
    return result
  }
  if (send("SIGTERM") === "empty") return null
  if (await waitForEmptyGroup(pgid, graceMs)) return null
  if (send("SIGKILL") === "empty") return null
  if (await waitForEmptyGroup(pgid, KILL_CONFIRM_MS)) return null
  return [...denied, "members remained after SIGKILL"].join(", ")
}

// hook script を起動し、終わったら {code, signal, stdout, stderr} で resolve する。起動できない
// ときと timeout だけを ScriptFailure で reject する (exit code の解釈は呼び出し側が持つ)。
// detached: true で process group を分け、timeout では group を stopGroup で止める (script が
// 起動した孫 process を残さないため)。timeout の reject は後始末が済んでから出す (呼び出し側の
// 実行中の印を後始末の間も保つ。changed-scope-qa の直列)。
function spawnScript(script, payload, { cwd, timeoutMs, graceMs, env }) {
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
      // 結果はここで timeout に決まる。後始末の間に届く close / error では settle しない。
      settled = true
      // 停止を確認できないときだけ、固定の文と理由を足す (通常の timeout の warn は変えない)。
      const reason = `timed out after ${timeoutMs} ms`
      const unconfirmed = (detail) => `${reason}; its process group may not have stopped (${detail})`
      stopGroup(child.pid, graceMs).then(
        (detail) => reject(new ScriptFailure(script, detail === null ? reason : unconfirmed(detail))),
        (error) => reject(new ScriptFailure(script, unconfirmed(error.message))),
      )
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
  const termGraceMs = resolveTermGrace(options)
  const cwd = typeof input.directory === "string" ? input.directory : undefined
  const client = input.client
  const warned = new Set()
  // changed-scope-qa の実行中の印。server() は directory ごとに呼ばれるので、instance に 1 つ。
  let qaRunning = false
  // model の bash の (sessionID, callID) (記録専用の before で覚え、shell.env で突き合わせ、after で
  // 忘れる)。`!` にも callID が付くので callID の有無では絞れない (M5)。PTY は callID を持たない。
  // callID は provider の ID で session をまたいで一意とは限らず、instance は directory 単位で session を
  // 共有するので、session と組にする。どちらかが欠ければ記録も一致もしない (目印を立てない側に倒れる)。
  const modelBashCalls = new Set()

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
    const result = await runScript(SAFE_GH_SCRIPT, payload, { cwd, timeoutMs: timeoutMs.safeGh, graceMs: termGraceMs })
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
        const ctx = additionalContext(await runScript(FAST_EDIT_CHECK_SCRIPT, payload, { cwd, timeoutMs: remaining, graceMs: termGraceMs }))
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
      const report = qaReport(await spawnScript(CHANGED_SCOPE_QA_SCRIPT, payload, { cwd, timeoutMs: timeoutMs.changedScopeQa, graceMs: termGraceMs, env }))
      if (report !== null) log(report.level, report.message)
    } finally {
      qaRunning = false
    }
  }

  function callKey(input) {
    if (!input) return null
    const { sessionID, callID } = input
    if (typeof sessionID !== "string" || sessionID === "" || typeof callID !== "string" || callID === "") return null
    return JSON.stringify([sessionID, callID])
  }

  function rememberModelBash(input) {
    const key = callKey(input)
    if (key === null || input.tool !== "bash") return
    modelBashCalls.add(key)
    if (modelBashCalls.size > MODEL_BASH_CALLS_MAX) modelBashCalls.delete(modelBashCalls.values().next().value)
  }

  function forgetModelBash(input) {
    if (!input || input.tool !== "bash") return
    const key = callKey(input)
    if (key !== null) modelBashCalls.delete(key)
  }

  // model の bash の env にだけ目印を立て、他の agent の目印を空にする。
  function markModelBash(input, output) {
    const key = callKey(input)
    if (key === null || !modelBashCalls.has(key)) return
    const env = output.env
    if (!env || typeof env !== "object") return
    env[OPENCODE_MARKER] = "1"
    for (const name of FOREIGN_MARKERS) env[name] = ""
  }

  const hooks = {
    // 記録専用。throw も args の書き換えもしない (実行を止める経路は使わない)。
    "tool.execute.before": async (input) => {
      await failOpen("tool.execute.before", "the OpenCode marker may be missing", () => rememberModelBash(input))
    },
    "shell.env": async (input, output) => {
      await failOpen("shell.env", "the OpenCode marker was not set", () => markModelBash(input, output))
    },
    "tool.execute.after": async (input, output) => {
      await failOpen("tool.execute.after", "the bash call record was kept", () => forgetModelBash(input))
      await failOpen("tool.execute.after", "the tool result was left unchanged", () => annotateSafeGh(input, output))
      await failOpen("tool.execute.after", "the tool result was left unchanged", () => checkEdits(input, output))
    },
    // OpenCode は event hook を待たないが、処理の promise を返す (test から await できるように)。
    event: (input) => failOpen("event", "no changed-scope-qa report was made", () => reportChangedScope(input ? input.event : undefined)),
  }

  // init の目印 (#343): hooks を組み終えて return する直前に 1 回だけ出す。途中で throw した server() は
  // ここに来ないので出さない。log は待たず、失敗も握る (log の成否で init の結果を変えない)。
  log("info", `${INIT_LINE_PREFIX} name=${ID} build_id=${BUILD_ID}`)
  return hooks
}

export default { id: ID, server }

// OpenCode plugin probe (#295 PR 0) が隔離環境に置く計測用 plugin。
// Spec: docs/opencode-plugin-probe.md。runner (probe_opencode_plugin.rb) が同じ source を
// label 違いの file 名で global / project の plugins dir に複製して置く。
//
// 記録は hook ごとの allowlist で固定し、それ以外は書かない。args の値、tool の出力本文、
// provider / options / model.api.url / headers は、key や API key、private な baseURL を
// 含みうるので記録しない (記録するのは key の一覧・真偽値・ID 類だけ)。
//
// 制御は env で受ける (file plugin には options が渡らないため):
//   PROBE_HOOKS_OUT  記録先の JSONL (未設定なら何も書かない)
//   PROBE_RUN        記録に付ける run の label
//   PROBE_PRIMARY    hook を登録する plugin の label (それ以外は init だけ記録する)
//   PROBE_NONCE      after で出力の先頭に足す nonce
//   PROBE_MODE       comma 区切りの mode (MODES を参照)
//   PROBE_THROW_INIT この label の plugin は server() で throw する
//
// 名前付き export は置かない (legacy の loader が関数とみなして読むため)。
import { appendFileSync } from "node:fs"
import { spawn } from "node:child_process"
import { basename } from "node:path"
import { fileURLToPath } from "node:url"

const LABEL = basename(fileURLToPath(import.meta.url), ".js")

const MODES = new Set([
  "annotate", // after: 出力の先頭に nonce を足す (M4 / M16)
  "mark", // shell.env: AGENT_TOOLS_PROBE_MARK=1 を足す (M5)
  "throw-shell-env", // M6
  "throw-before", // M7
  "throw-after", // M7
  "slow-after", // M7: after で SLOW_AFTER_MS 待つ
  "reject-event", // M8: 最初の event で reject する
  "spawn", // M13: 最初の after で spawn と group kill を測る
  "notify", // M11: 最初の session.idle で toast と app.log を呼ぶ
])

const SLOW_AFTER_MS = 3000
const IDLE_DELAY_MS = 500
const KILL_SETTLE_MS = 300

// 目印の候補。値は記録せず、立っているかだけを見る。
const MARKER_NAMES = [
  "OPENCODE",
  "AGENT",
  "OPENCODE_PID",
  "OPENCODE_SESSION_ID",
  "AGENT_TOOLS_PROBE_MARK",
  "CLAUDECODE",
  "CODEX_THREAD_ID",
  "CODEX_SANDBOX",
]

function modes() {
  const raw = process.env.PROBE_MODE || ""
  const list = raw.split(",").filter((m) => m !== "")
  const unknown = list.filter((m) => !MODES.has(m))
  if (unknown.length > 0) throw new Error(`probe-plugin: unknown PROBE_MODE: ${unknown.join(",")}`)
  return new Set(list)
}

function record(fields) {
  const out = process.env.PROBE_HOOKS_OUT
  if (!out) return
  const line = JSON.stringify({ t: Date.now(), run: process.env.PROBE_RUN || null, label: LABEL, ...fields })
  appendFileSync(out, line + "\n")
}

function str(v) {
  return typeof v === "string" ? v : null
}

function argKeys(args) {
  return args && typeof args === "object" ? Object.keys(args).sort() : []
}

function markerPresence(env) {
  const seen = {}
  for (const name of MARKER_NAMES) seen[name] = typeof env[name] === "string" && env[name] !== ""
  return seen
}

function patchFiles(metadata) {
  const files = metadata && Array.isArray(metadata.files) ? metadata.files : null
  if (!files) return null
  return files.map((f) => ({
    type: str(f && f.type),
    has_filePath: typeof (f && f.filePath) === "string",
    has_movePath: typeof (f && f.movePath) === "string",
  }))
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function alive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

// M13: ruby の起動にかかる時間と、detached で起動した子の process group を負の pid で
// SIGKILL したときに子と孫が残るか。PR 1 / PR 2 の plugin が Ruby script を呼ぶ形と揃える。
async function spawnProbe() {
  const t0 = Date.now()
  const exitCode = await new Promise((resolve) => {
    const c = spawn("ruby", ["-e", "exit 0"], { stdio: "ignore" })
    c.on("exit", (code) => resolve(code))
    c.on("error", () => resolve(null))
  })
  const spawnMs = Date.now() - t0

  const child = spawn("ruby", ["-e", 'g = Process.spawn("sleep", "30"); puts g; $stdout.flush; sleep 30'], {
    detached: true,
    stdio: ["ignore", "pipe", "ignore"],
  })
  let exited = false
  child.on("exit", () => {
    exited = true
  })
  const grandPid = await new Promise((resolve) => {
    let buf = ""
    child.stdout.on("data", (d) => {
      buf += d
      const m = buf.match(/^(\d+)\n/)
      if (m) resolve(Number(m[1]))
    })
    child.on("error", () => resolve(null))
    setTimeout(() => resolve(null), 5000)
  })
  let killError = null
  try {
    process.kill(-child.pid, "SIGKILL")
  } catch (e) {
    killError = e && e.code ? e.code : "error"
  }
  await sleep(KILL_SETTLE_MS)
  const grandAlive = grandPid ? alive(grandPid) : null
  if (grandPid && grandAlive) process.kill(grandPid, "SIGKILL")
  return {
    spawn_ms: spawnMs,
    spawn_exit: exitCode,
    grandchild_pid_read: grandPid !== null,
    group_kill_error: killError,
    child_exited: exited,
    grandchild_alive: grandAlive,
  }
}

async function server(input) {
  record({ kind: "init" })
  if (process.env.PROBE_THROW_INIT === LABEL) throw new Error("probe: throw-init")
  if (process.env.PROBE_PRIMARY !== LABEL) return {}

  const mode = modes()
  const nonce = process.env.PROBE_NONCE || ""
  const client = input.client
  let spawned = false
  let notified = false
  let rejected = false
  const idleSeen = new Set()

  async function notify() {
    let toast
    try {
      const res = await client.tui.showToast({ body: { title: "probe", message: "probe toast", variant: "info" } })
      toast = { data_type: typeof (res && res.data), data: res && typeof res.data === "boolean" ? res.data : null, error: Boolean(res && res.error) }
    } catch (e) {
      toast = { threw: e && e.name ? e.name : "error" }
    }
    record({ kind: "toast", ...toast })
    let log
    try {
      const res = await client.app.log({ body: { service: "probe", level: "info", message: `probe-log-${nonce}` } })
      log = { error: Boolean(res && res.error) }
    } catch (e) {
      log = { threw: e && e.name ? e.name : "error" }
    }
    record({ kind: "app.log", ...log })
  }

  async function onIdle(sessionID) {
    setTimeout(() => record({ kind: "idle.delayed", sessionID }), IDLE_DELAY_MS)
    if (mode.has("notify") && !notified) {
      notified = true
      await notify()
    }
    if (!sessionID || idleSeen.has(sessionID)) return
    idleSeen.add(sessionID)
    try {
      const res = await client.session.get({ path: { id: sessionID } })
      const info = res && res.data
      record({ kind: "idle.session", sessionID, found: Boolean(info), has_parentID: Boolean(info && typeof info.parentID === "string") })
    } catch (e) {
      record({ kind: "idle.session", sessionID, threw: e && e.name ? e.name : "error" })
    }
  }

  return {
    event: async ({ event }) => {
      const props = (event && event.properties) || {}
      const info = props.info && typeof props.info === "object" ? props.info : {}
      record({
        kind: "event",
        type: str(event && event.type),
        sessionID: str(props.sessionID) || str(info.sessionID) || (event && event.type && event.type.startsWith("session.") ? str(info.id) : null),
        parentID: str(info.parentID),
      })
      if (mode.has("reject-event") && !rejected) {
        rejected = true
        throw new Error("probe: reject-event")
      }
      if (event && event.type === "session.idle") await onIdle(str(props.sessionID))
    },
    "chat.message": async (inp) => {
      const model = (inp && inp.model) || {}
      record({ kind: "chat.message", sessionID: str(inp && inp.sessionID), providerID: str(model.providerID), modelID: str(model.modelID) })
    },
    "chat.params": async (inp) => {
      const model = (inp && inp.model) || {}
      const api = model.api || {}
      record({ kind: "chat.params", sessionID: str(inp && inp.sessionID), providerID: str(model.providerID), modelID: str(model.id), apiID: str(api.id) })
    },
    "tool.execute.before": async (inp, out) => {
      record({ kind: "tool.before", tool: str(inp.tool), sessionID: str(inp.sessionID), callID: str(inp.callID), arg_keys: argKeys(out && out.args) })
      if (mode.has("throw-before")) throw new Error("probe: throw-before")
    },
    "tool.execute.after": async (inp, out) => {
      const started = Date.now()
      if (mode.has("spawn") && !spawned) {
        spawned = true
        record({ kind: "spawn", ...(await spawnProbe()) })
      }
      if (mode.has("slow-after")) await sleep(SLOW_AFTER_MS)
      const isString = typeof out.output === "string"
      if (mode.has("annotate") && isString && nonce) out.output = `${nonce}\n${out.output}`
      record({
        kind: "tool.after",
        tool: str(inp.tool),
        sessionID: str(inp.sessionID),
        callID: str(inp.callID),
        arg_keys: argKeys(inp.args),
        output_type: typeof out.output,
        nonce_first: isString && nonce !== "" && out.output.startsWith(nonce),
        files: patchFiles(out.metadata),
        hook_ms: Date.now() - started,
      })
      if (mode.has("throw-after")) throw new Error("probe: throw-after")
    },
    "shell.env": async (inp, out) => {
      record({
        kind: "shell.env",
        has_sessionID: typeof inp.sessionID === "string",
        sessionID: str(inp.sessionID),
        has_callID: typeof inp.callID === "string",
        callID: str(inp.callID),
        incoming_markers: markerPresence((out && out.env) || {}),
        process_markers: markerPresence(process.env),
      })
      if (mode.has("throw-shell-env")) throw new Error("probe: throw-shell-env")
      if (mode.has("mark")) out.env.AGENT_TOOLS_PROBE_MARK = "1"
    },
  }
}

export default { id: `agent-tools-probe-${LABEL}`, server }

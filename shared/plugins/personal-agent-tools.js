// personal-agent-tools: OpenCode plugin (v1 形 `export default { id, server }`)。
// Spec: docs/runtime-injection-defense.md「PreToolUse hook」節の OpenCode parity、
//       adapters/opencode/README.md (#295)。
//
// 役割は薄い adapter に限る。判定は Claude Code / Codex と同じ Ruby の hook script
// (~/.claude/agent-tools/scripts/ に配った personal-safe-gh-hook) を無改変で呼び、その返す
// additionalContext を tool 結果の先頭に載せるだけ。文言も判定も JS では持たない
// (2 系統の判定が drift しないため)。
//
// 強度ラベル (偽らない): steering / fail-open であって enforcement ではない。OpenCode に
// 実行前の steer は無いので、注記は実行が済んだ後の同じ tool 結果の先頭に載る (model には
// 届くが、TUI の人の目には入らない)。置けばそのまま有効になり、`--pure` で外せる。
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
import { join } from "node:path"

const ID = "personal-agent-tools"

// hook script の配置先。Claude Code target に配った script を既定の claude home から解決する
// (custom の claude home には対応しない。docs 参照)。
const SCRIPTS_DIR_SEGMENTS = [".claude", "agent-tools", "scripts"]
const SAFE_GH_SCRIPT = "personal-safe-gh-hook"

// timeout の既定 (ms)。safe-gh は Codex の hook 登録と同じ 10 秒。options.timeoutMs は
// これより短くする方向だけ受け付ける (既定との min)。
const DEFAULT_TIMEOUT_MS = Object.freeze({ safeGh: 10000 })

// 子 process に渡す env は最低限に絞る (script の起動に PATH、home の解決に HOME、Ruby の
// encoding に LANG 系)。token 等の secret は渡さない。
const CHILD_ENV_NAMES = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE"]

// safe-gh-hook の prefilter。script の判定 (command word が gh) の上位集合なので、ここで
// 落とすことで見逃しは増えない。
const SAFE_GH_NEEDLE = "gh"

function childEnv() {
  const env = {}
  for (const name of CHILD_ENV_NAMES) {
    if (typeof process.env[name] === "string") env[name] = process.env[name]
  }
  return env
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

// hook script を起動して stdout の JSON を返す。失敗はすべて ScriptFailure で reject し、
// fail-open の握り方は呼び出し側 (hook) の 1 箇所に集める。
// detached: true で process group を分け、timeout では group ごと SIGKILL する (script が
// 起動した孫 process を残さないため)。
function runScript(script, payload, { cwd, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const child = spawn(scriptPath(script), [], {
      cwd,
      env: childEnv(),
      stdio: "pipe",
      detached: true,
    })
    let stdout = ""
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
    child.stderr.resume()
    child.on("close", (code, signal) => {
      if (code !== 0) {
        settle(reject, new ScriptFailure(script, `exited with ${signal ? `signal ${signal}` : `code ${code}`}`))
        return
      }
      // hook script は steer しないとき何も出さずに exit 0 で終わる (正常な no-op)。
      if (stdout.trim() === "") {
        settle(resolve, null)
        return
      }
      let parsed
      try {
        parsed = JSON.parse(stdout)
      } catch {
        settle(reject, new ScriptFailure(script, "stdout is not JSON"))
        return
      }
      settle(resolve, parsed)
    })
    // 子が読む前に終わると EPIPE が error event で来る。close 側の判定に任せる。
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify(payload))
  })
}

function additionalContext(result) {
  const out = result && typeof result === "object" ? result.hookSpecificOutput : undefined
  const ctx = out && typeof out === "object" ? out.additionalContext : undefined
  return typeof ctx === "string" ? ctx : null
}

async function server(input, options) {
  const timeoutMs = { safeGh: resolveTimeout(options, "safeGh") }
  const cwd = typeof input.directory === "string" ? input.directory : undefined
  const client = input.client
  const warned = new Set()

  // warn は script ごとに 1 回だけ (script 以外の想定外の失敗は hook 名を key にする)。client が
  // 無い / log が throw・reject する場合も握る (warn の失敗で hook を落とさない)。
  function warnOnce(key, message) {
    if (warned.has(key)) return
    warned.add(key)
    try {
      const pending = client.app.log({
        body: { service: ID, level: "warn", message: `${message}; the tool result was left unchanged (fail-open)` },
      })
      if (pending && typeof pending.then === "function") pending.then(undefined, () => {})
    } catch {
      // fail-open: warn を出せないことは hook の結果に影響させない。
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

  return {
    "tool.execute.after": async (input, output) => {
      try {
        await annotateSafeGh(input, output)
      } catch (error) {
        // fail-open: hook は決して throw しない (throw すると済んだ tool call が error になる)。
        warnOnce(error instanceof ScriptFailure ? error.script : "tool.execute.after", String(error && error.message))
      }
    },
  }
}

export default { id: ID, server }

// probe-opencode-plugin-test.sh の node 側 (T7)。計測用 plugin の server(fakeCtx) が返す hooks に、
// canary を入れた fake の input を渡し、hooks.jsonl に canary が出ないことを確かめる (記録の allowlist)。
// 使い方: node probe-opencode-plugin-test.mjs <plugin.js> <hooks.jsonl> <canary>
// env: PROBE_HOOKS_OUT / PROBE_PRIMARY / PROBE_NONCE / PROBE_MODE は呼び出し側が立てる。
import { readFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

const [pluginPath, hooksOut, canary] = process.argv.slice(2)

function fail(msg) {
  console.error(`FAIL: ${msg}`)
  process.exit(1)
}

const mod = await import(pathToFileURL(pluginPath).href)
const exportNames = Object.keys(mod)
if (exportNames.join(",") !== "default") fail(`T7: plugin must export only default, got ${exportNames.join(",")}`)
const plugin = mod.default
if (typeof plugin.id !== "string" || typeof plugin.server !== "function") fail("T7: default export must be {id, server}")

const calls = []
const client = {
  tui: { showToast: async (arg) => (calls.push(["toast", arg]), { data: true }) },
  app: { log: async (arg) => (calls.push(["log", arg]), { data: true }) },
  session: { get: async () => ({ data: { id: "s1", parentID: "p1", secret: canary } }) },
}
const hooks = await plugin.server({ client, directory: `/tmp/${canary}`, worktree: `/tmp/${canary}`, project: { id: canary } })
for (const name of ["event", "chat.message", "chat.params", "tool.execute.before", "tool.execute.after", "shell.env"]) {
  if (typeof hooks[name] !== "function") fail(`T7: hook ${name} missing`)
}
if (hooks["permission.ask"]) fail("T7: permission.ask must not be registered")

const provider = { source: "config", info: { id: "probe", key: canary, options: { apiKey: canary } }, options: { apiKey: canary, baseURL: `https://${canary}.example` } }
const model = { id: "claude-probe", providerID: "probe", api: { id: "claude-probe", url: `https://${canary}.example/v1`, npm: "x" }, headers: { authorization: canary } }
const message = { id: "m1", sessionID: "s1", role: "user", system: canary }

await hooks["chat.message"]({ sessionID: "s1", agent: "build", model: { providerID: "probe", modelID: "claude-probe" }, messageID: "m1" }, { message, parts: [{ type: "text", text: canary }] })
await hooks["chat.params"]({ sessionID: "s1", agent: "build", model, provider, message }, { temperature: 0, topP: 1, topK: 0, maxOutputTokens: 1, options: { apiKey: canary } })
const beforeOut = { args: { command: `echo ${canary}`, filePath: `/tmp/${canary}` } }
await hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1", callID: "c1" }, beforeOut)
if (beforeOut.args.command !== `echo ${canary}`) fail("T7: before must not rewrite args")
const afterOut = { title: canary, output: `out ${canary}`, metadata: { files: [{ type: "update", filePath: `/tmp/${canary}`, movePath: `/tmp/${canary}2`, diff: canary }], secret: canary } }
await hooks["tool.execute.after"]({ tool: "apply_patch", sessionID: "s1", callID: "c1", args: { patchText: canary } }, afterOut)
if (!afterOut.output.startsWith(`${process.env.PROBE_NONCE}\n`)) fail("T7: annotate must prepend the nonce to the output")
const envOut = { env: { [`K_${canary.replace(/[^A-Z0-9_]/gi, "_")}`]: canary } }
await hooks["shell.env"]({ cwd: `/tmp/${canary}`, sessionID: "s1", callID: "c1" }, envOut)
if (envOut.env.AGENT_TOOLS_PROBE_MARK !== "1") fail("T7: mark mode must set AGENT_TOOLS_PROBE_MARK")
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s1", info: { id: "s1", title: canary, parentID: "p1" }, error: canary } } })
await new Promise((r) => setTimeout(r, 700))

const text = readFileSync(hooksOut, "utf8")
if (text.includes(canary)) {
  const hit = text.split("\n").filter((l) => l.includes(canary))
  fail(`T7: canary leaked into hooks.jsonl: ${hit.join(" | ").slice(0, 400)}`)
}
const kinds = new Set(text.trim().split("\n").map((l) => JSON.parse(l).kind))
for (const k of ["init", "chat.message", "chat.params", "tool.before", "tool.after", "shell.env", "event", "toast", "app.log", "idle.session", "idle.delayed"]) {
  if (!kinds.has(k)) fail(`T7: expected a ${k} record, got ${[...kinds].join(",")}`)
}
if (calls.length !== 2) fail(`T7: notify must call toast and app.log once each, got ${calls.length}`)
console.log("ok T7")

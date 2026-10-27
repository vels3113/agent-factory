// OpenCode server plugin: wraps the agents' build and test commands. The
// commands run unchanged; the plugin sets their environment and logs each run.
// Loaded through the "plugins" entry in <project>/opencode.jsonc, installed by
// bootstrap/03-project-layout.sh. Options:
//   commands  command prefixes to wrap, e.g. ["cmake --build", "ctest"]; a
//             command matches when any part of it (split at &&, ||, ;, |)
//             starts with one
//   env       environment variables set for those commands; ${VAR} in a value
//             is the command's current value, e.g. "PATH": "/usr/lib/ccache:${PATH}"
// Per wrapped command in a task worktree (<project>/worktrees/<task-id>):
//   - a running prebuild of the worktree is stopped first (see stopPrebuild)
//   - its full output copied to reports/<task-id>/commands/<time>-<shell-id>.log
//   - a journal line with exit code, duration and a link to the log
//   - a row in journal/<task-id>.checks.tsv (kind "command") for the ledger
// Only agent tool calls are wrapped: your own `!` commands in the TUI create
// shells too, but without a tool call before them.
// Costs: OpenCode records its own estimate from list prices, not what
// OpenRouter charged. The plugin reads each model response's usage report and,
// when it has a cost (OpenRouter's usage accounting, which OpenCode requests),
// appends a row to costs.tsv: time, session, agent, kind (primary, title, ...),
// provider/model, generation ID, cost in USD, prompt and completion tokens.
// agent-task.sh done sums these rows for the ledger.
// OpenCode 2.1.3 behavior this relies on is checked in tests/task-workflow.sh.
import { Plugin } from "@opencode/plugin"
import { spawnSync } from "node:child_process"
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

type Pending = { command: string; sessionID: string; agent: string; envSet: boolean; time: number }
type Running = { command: string; sessionID: string; task: string; file: string; started: number }

const factoryDir = process.env.AGENT_FACTORY_DIR || join(homedir(), ".agent-factory")
const taskPattern = /\/worktrees\/((?:TASK|VM)-\d+)(?=\/|$)/
const worktreePattern = /^(.*\/worktrees\/(?:TASK|VM)-\d+)(?=\/|$)/

const alive = (pid: number) => { try { process.kill(pid, 0); return true } catch { return false } }
// Stops the worktree's running prebuild (agent-check.sh registers it in
// .agent/check/prebuild.pid, in its own session) and waits up to 10 s for it to
// exit: the agent's command is usually much shorter, and both would build in
// the same build directory. The prebuild's journal line names the command.
async function stopPrebuild(cwd: string, command: string) {
  const root = worktreePattern.exec(cwd)?.[1]
  if (!root) return
  const dir = join(root, ".agent", "check")
  let sid = 0
  try { sid = Number(readFileSync(join(dir, "prebuild.pid"), "utf8").trim()) } catch { return }
  if (!Number.isInteger(sid) || sid <= 0 || !alive(sid)) return
  writeFileSync(join(dir, "prebuild.stop"), `command \`${command.replace(/\s+/g, " ")}\`\n`)
  spawnSync("pkill", ["-TERM", "-s", String(sid)])
  for (let i = 0; i < 100 && alive(sid); i++) await new Promise((r) => setTimeout(r, 100))
}

const pad = (n: number) => String(n).padStart(2, "0")
const stamp = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
const fileStamp = (d: Date) => `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
const duration = (ms: number) => { const s = Math.round(ms / 1000); return `${Math.floor(s / 60)}m${pad(s % 60)}s` }

// The response ID and the last usage report in a model response: a JSON body,
// or a stream of "data: {...}" lines whose last chunk carries the usage.
function usageOf(body: string): { id?: string; usage?: any } {
  let id: string | undefined
  let usage: any
  const take = (text: string) => {
    try {
      const o = JSON.parse(text)
      if (typeof o?.id === "string") id ??= o.id
      if (o?.usage) usage = o.usage
    } catch {}
  }
  if (body.trimStart().startsWith("{")) take(body)
  else for (const line of body.split("\n")) if (line.startsWith("data:") && !line.includes("[DONE]")) take(line.slice(5))
  return { id, usage }
}

function matches(command: string, prefixes: string[]): boolean {
  return command.split(/&&|\|\||[;|\n]/).some((part) => {
    const p = part.trim()
    return prefixes.some((x) => x && (p === x || p.startsWith(x + " ")))
  })
}

export default Plugin.define({
  id: "agent-factory",
  async setup(ctx) {
    const options = ((ctx as any).options ?? {}) as { commands?: string[]; env?: Record<string, string> }
    const prefixes = (options.commands ?? []).filter((c) => c && !c.startsWith("TODO"))
    const env = options.env ?? {}
    const pending: Pending[] = []
    const running = new Map<string, Running>()

    // An agent's shell call: remember it until OpenCode creates its shell.
    await ctx.tool.hook("execute.before", (event: any) => {
      const command = String(event.input?.command ?? "")
      if (event.tool !== "shell" || !matches(command, prefixes)) return
      const now = Date.now()
      while (pending.length && now - pending[0].time > 60_000) pending.shift()
      pending.push({ command, sessionID: event.sessionID, agent: event.agent, envSet: false, time: now })
    })
    // A denied or rejected call never gets a shell.
    await ctx.tool.hook("execute.after", (event: any) => {
      if (event.tool !== "shell" || event.status !== "error") return
      const i = pending.findIndex((p) => p.sessionID === event.sessionID && p.command === event.input?.command)
      if (i >= 0) pending.splice(i, 1)
    })
    // Runs right after execute.before; it gets no session, so match the command.
    await ctx.shell.hook("create.before", async (event: any) => {
      const p = pending.find((p) => !p.envSet && p.command === event.command)
      if (!p) return
      p.envSet = true
      const current = (name: string) => event.env[name] ?? process.env[name] ?? ""
      for (const [k, v] of Object.entries(env)) event.env[k] = String(v).replace(/\$\{(\w+)\}/g, (_, name) => current(name))
      await stopPrebuild(String(event.cwd ?? ""), p.command)
    })

    const created = (info: any) => {
      const sessionID = info.metadata?.sessionID
      const i = pending.findIndex((p) => p.sessionID === sessionID && p.command === info.command)
      if (i < 0) return
      pending.splice(i, 1)
      const task = taskPattern.exec(String(info.cwd ?? ""))?.[1]
      if (task) running.set(info.id, { command: info.command, sessionID, task, file: info.file, started: info.time?.started ?? Date.now() })
    }
    const exited = (data: any) => {
      const r = running.get(data.id)
      if (!r) return
      running.delete(data.id)
      const end = new Date()
      const name = `${fileStamp(new Date(r.started))}-${data.id}.log`
      const logDir = join(factoryDir, "reports", r.task, "commands")
      const journal = join(factoryDir, "journal")
      mkdirSync(logDir, { recursive: true })
      mkdirSync(journal, { recursive: true })
      if (r.file && existsSync(r.file)) copyFileSync(r.file, join(logDir, name))
      appendFileSync(join(journal, `${r.task}.md`),
        `- ${stamp(end)} command \`${r.command.replace(/\s+/g, " ")}\`: exit ${data.exit}, ${duration(end.getTime() - r.started)}, log: [${name}](../reports/${r.task}/commands/${name})\n`)
      appendFileSync(join(journal, `${r.task}.checks.tsv`),
        [Math.floor(r.started / 1000), Math.floor(end.getTime() / 1000), "command", "", data.exit, r.sessionID, ""].join("\t") + "\n")
    }
    // What the provider charged. A copy of the response is read in the
    // background: OpenCode waits for its hooks, so awaiting here would hold
    // back the streamed answer.
    await ctx.session.hook("http.response", (event: any) => {
      if (typeof event.response?.clone !== "function") return
      const time = Math.floor(Date.now() / 1000)
      const model = `${event.model?.providerID ?? ""}/${event.model?.id ?? ""}`
      event.response.clone().text().then((body: string) => {
        const { id, usage } = usageOf(body)
        if (typeof usage?.cost !== "number") return
        mkdirSync(factoryDir, { recursive: true })
        appendFileSync(join(factoryDir, "costs.tsv"), [time, event.sessionID, event.agent ?? "", event.kind ?? "", model,
          id ?? "", usage.cost, usage.prompt_tokens ?? "", usage.completion_tokens ?? ""].join("\t") + "\n")
      }).catch((err: unknown) => console.error("agent-factory plugin: response cost:", err))
    })

    // Approval waits: stub, see proposal-approval-waits.md.
    const permission = (_event: any) => {}

    const events: any = ctx.event.subscribe({ types: ["shell.created", "shell.exited", "permission.asked", "permission.replied"] })
    ;(async () => {
      for await (const e of events) {
        try {
          if (e?.type === "shell.created") created(e.data?.info ?? {})
          else if (e?.type === "shell.exited") exited(e.data ?? {})
          else if (e?.type === "permission.asked" || e?.type === "permission.replied") permission(e)
        } catch (err) {
          console.error("agent-factory plugin:", err)
        }
      }
    })().catch((err) => console.error("agent-factory plugin: event stream ended:", err))
  },
})

#!/usr/bin/env bun

// PROTOTYPE: delete after the direct-vs-code-mode agent evaluation is recorded.

import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

interface EvaluationRun {
  readonly mode: "direct" | "code"
  readonly exitCode: number
  readonly durationMs: number
  readonly correct: boolean
  readonly answer: unknown
  readonly providerAttempts: number
  readonly providerTurns: number
  readonly providerErrors: number
  readonly outerToolCalls: number
  readonly effectiveToolCalls: number
  readonly codeExecutions: readonly { readonly outcome: unknown; readonly error: unknown; readonly calls: unknown }[]
  readonly usage: {
    readonly input: number
    readonly output: number
    readonly cacheRead: number
    readonly cacheWrite: number
  }
  readonly finalText: string
  readonly stderr: string
}

const records = [
  { id: "amber", score: 91 },
  { id: "birch", score: 64 },
  { id: "cedar", score: 77 },
  { id: "delta", score: 35 },
  { id: "ember", score: 88 },
  { id: "fjord", score: 69 },
  { id: "grove", score: 73 },
  { id: "hazel", score: 52 },
  { id: "iris", score: 99 },
  { id: "juniper", score: 70 },
  { id: "kelp", score: 18 },
  { id: "lumen", score: 82 }
] as const

const expected = {
  ids: records
    .filter(record => record.score >= 70)
    .map(record => record.id)
    .toSorted(),
  total: records.filter(record => record.score >= 70).reduce((sum, record) => sum + record.score, 0)
}

const prompt = `Use the record tools to find every record whose score is at least 70.
Sort the selected IDs alphabetically, compute the sum of their scores, and call save_answer exactly once with { ids, total }.
The records are opaque: obtain the ID catalog and inspect every record. Do not guess or stop early.
After save_answer succeeds, briefly report what you saved.`

const temporary = await mkdtemp(join(tmpdir(), "zi-code-mode-agent-eval-"))
try {
  const extension = join(temporary, "records-extension.ts")
  await Bun.write(extension, extensionSource())
  const directDirectory = join(temporary, "direct")
  const codeDirectory = join(temporary, "code")
  await Promise.all([mkdir(directDirectory), mkdir(codeDirectory)])

  const model = optionalArgument("--model")
  const only = selectedMode(optionalArgument("--only"))
  const direct = only === "code" ? undefined : await evaluate("direct", directDirectory, extension, model)
  const code = only === "direct" ? undefined : await evaluate("code", codeDirectory, extension, model)
  const verdict = evaluationVerdict(direct, code)

  console.log(
    JSON.stringify(
      {
        prototype: "Zi direct-vs-code-mode opaque tool orchestration",
        question:
          "Can one generated JavaScript program fan out over data-dependent extension calls with fewer provider turns without losing correctness?",
        model: model ?? "configured default",
        expected,
        verdict,
        runs: { ...(direct ? { direct } : {}), ...(code ? { code } : {}) }
      },
      null,
      2
    )
  )
  if (direct?.correct === false || code?.correct === false) process.exitCode = 1
} finally {
  await rm(temporary, { recursive: true, force: true })
}

async function evaluate(
  mode: "direct" | "code",
  cwd: string,
  extension: string,
  model: string | undefined
): Promise<EvaluationRun> {
  const cli = resolve(import.meta.dirname, "../packages/cli/src/main.ts")
  const command = [
    process.execPath,
    cli,
    "--cwd",
    cwd,
    "--no-session",
    "--mode",
    "json",
    "--thinking",
    "medium",
    "--extension",
    extension,
    ...(model ? ["--model", model] : []),
    ...(mode === "code" ? ["--code-mode-prototype"] : []),
    prompt
  ]
  const startedAt = Date.now()
  const child = Bun.spawn(command, { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const timeout = setTimeout(() => child.kill("SIGKILL"), 5 * 60 * 1_000)
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  clearTimeout(timeout)
  const events = stdout
    .split(/\r?\n/)
    .filter(Boolean)
    .map(line => JSON.parse(line) as unknown)
    .filter(isRecord)
  const assistants = events.flatMap(event => {
    if (event.type !== "message_end" || !isRecord(event.message) || event.message.role !== "assistant") return []
    return [event.message]
  })
  const providerErrors = assistants.filter(message => message.stopReason === "error").length
  const providerTurns = assistants.length - providerErrors
  const usage = assistants.reduce<EvaluationRun["usage"]>(
    (sum, message) => {
      const current = isRecord(message.usage) ? message.usage : {}
      return {
        input: sum.input + finiteNumber(current.input),
        output: sum.output + finiteNumber(current.output),
        cacheRead: sum.cacheRead + finiteNumber(current.cacheRead),
        cacheWrite: sum.cacheWrite + finiteNumber(current.cacheWrite)
      }
    },
    { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  )
  const outerToolCalls = events.filter(event => event.type === "tool_execution_start").length
  const codeExecutions = events.flatMap(event => {
    if (event.type !== "message_end" || !isRecord(event.message) || event.message.role !== "toolResult") return []
    const details = event.message.details
    if (!isRecord(details) || details.type !== "code_mode_prototype") return []
    return [{ outcome: details.outcome, error: details.error, calls: details.calls }]
  })
  const nestedCalls = events.reduce((count, event) => {
    if (event.type !== "message_end" || !isRecord(event.message) || event.message.role !== "toolResult") return count
    const details = event.message.details
    if (!isRecord(details) || details.type !== "code_mode_prototype" || !Array.isArray(details.calls)) return count
    return count + details.calls.length
  }, 0)
  const finalAssistant = assistants.at(-1)
  const finalText = finalAssistant && Array.isArray(finalAssistant.content) ? assistantText(finalAssistant.content) : ""
  const answer = await readAnswer(cwd)
  return {
    mode,
    exitCode,
    durationMs: Date.now() - startedAt,
    correct: exactAnswer(answer),
    answer,
    providerAttempts: assistants.length,
    providerTurns,
    providerErrors,
    outerToolCalls,
    effectiveToolCalls: nestedCalls > 0 ? nestedCalls : outerToolCalls,
    codeExecutions,
    usage,
    finalText,
    stderr
  }
}

function extensionSource(): string {
  return `import { writeFile } from "node:fs/promises"
import { resolve } from "node:path"
import { Schema } from "@with-zi/extension-api"

const records = ${JSON.stringify(records)}

export default function recordsExtension(zi) {
  zi.registerTool({
    name: "list_record_ids",
    description: "Return a JSON array containing every opaque record ID.",
    parameters: Schema.object({}),
    execute: () => JSON.stringify(records.map(record => record.id))
  })
  zi.registerTool({
    name: "get_record",
    description: "Return one opaque record as JSON. Call this for every ID returned by list_record_ids.",
    parameters: Schema.object({ id: Schema.string({ description: "Record ID" }) }),
    execute: ({ id }) => {
      const record = records.find(candidate => candidate.id === id)
      if (!record) throw new Error("Unknown record: " + id)
      return JSON.stringify(record)
    }
  })
  zi.registerTool({
    name: "save_answer",
    description: "Save the final selected IDs and score total. Call exactly once after inspecting every record.",
    parameters: Schema.object({
      ids: Schema.array(Schema.string(), { maxItems: 32 }),
      total: Schema.number()
    }),
    async execute(answer) {
      await writeFile(resolve(process.cwd(), "answer.json"), JSON.stringify(answer))
      return "answer saved"
    }
  })
}
`
}

async function readAnswer(cwd: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(join(cwd, "answer.json"), "utf8"))
  } catch {
    return undefined
  }
}

function exactAnswer(value: unknown): boolean {
  return (
    isRecord(value) &&
    Array.isArray(value.ids) &&
    value.ids.every(id => typeof id === "string") &&
    JSON.stringify(value.ids) === JSON.stringify(expected.ids) &&
    value.total === expected.total
  )
}

function assistantText(content: readonly unknown[]): string {
  return content
    .flatMap(part => (isRecord(part) && part.type === "text" && typeof part.text === "string" ? [part.text] : []))
    .join("\n")
}

function evaluationVerdict(direct: EvaluationRun | undefined, code: EvaluationRun | undefined): string {
  if (!direct) return code?.correct ? "code mode completed correctly" : "code mode did not complete correctly"
  if (!code) return direct.correct ? "direct mode completed correctly" : "direct mode did not complete correctly"
  if (direct.correct && code.correct) {
    return code.providerTurns < direct.providerTurns || code.usage.output < direct.usage.output
      ? "code mode completed the orchestration with less model work"
      : "both modes were correct; code mode did not reduce model work in this trial"
  }
  if (code.correct) return "only code mode completed the orchestration correctly"
  if (direct.correct) return "only direct mode completed the orchestration correctly"
  return "neither mode completed the orchestration correctly"
}

function selectedMode(value: string | undefined): "direct" | "code" | undefined {
  if (value === undefined || value === "direct" || value === "code") return value
  throw new Error("--only expects direct or code")
}

function optionalArgument(name: string): string | undefined {
  const index = process.argv.indexOf(name)
  if (index === -1) return undefined
  const value = process.argv[index + 1]
  if (!value) throw new Error(`${name} requires a value`)
  return value
}

function finiteNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

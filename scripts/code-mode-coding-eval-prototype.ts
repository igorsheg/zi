#!/usr/bin/env bun

// PROTOTYPE: delete after the direct-vs-code-mode agent evaluation is recorded.

import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

interface RunReport {
  readonly mode: "direct" | "code"
  readonly exitCode: number
  readonly durationMs: number
  readonly correct: boolean
  readonly providerAttempts: number
  readonly providerTurns: number
  readonly providerErrors: number
  readonly outerToolCalls: number
  readonly effectiveToolCalls: number
  readonly usage: {
    readonly input: number
    readonly output: number
    readonly cacheRead: number
    readonly cacheWrite: number
  }
  readonly codeExecutions: readonly unknown[]
  readonly finalText: string
  readonly stderr: string
}

const prompt = `Implement buildManifest exactly as specified in README.md.
Inspect the existing source and tests, change only src/manifest.ts, and run the test suite.
Do not weaken or replace tests. Finish with a concise summary and test result.`

const temporary = await mkdtemp(join(tmpdir(), "zi-code-mode-coding-eval-"))
try {
  const directDirectory = join(temporary, "direct")
  const codeDirectory = join(temporary, "code")
  await Promise.all([writeFixture(directDirectory), writeFixture(codeDirectory)])
  const model = optionalArgument("--model")
  const direct = await evaluate("direct", directDirectory, model)
  const code = await evaluate("code", codeDirectory, model)
  const verdict =
    direct.correct && code.correct
      ? code.providerTurns < direct.providerTurns || code.usage.output < direct.usage.output
        ? "both were correct; code mode used less model work"
        : direct.providerTurns < code.providerTurns || direct.usage.output < code.usage.output
          ? "both were correct; direct mode used less model work"
          : "both were correct with equivalent model work"
      : code.correct
        ? "only code mode completed the coding task correctly"
        : direct.correct
          ? "only direct mode completed the coding task correctly"
          : "neither mode completed the coding task correctly"
  console.log(
    JSON.stringify(
      {
        prototype: "Zi direct-vs-code-mode ordinary coding task",
        question:
          "Does replacing direct coding tools with JavaScript orchestration help or hurt an ordinary repository edit?",
        model: model ?? "configured default",
        verdict,
        runs: { direct, code }
      },
      null,
      2
    )
  )
  if (!direct.correct || !code.correct) process.exitCode = 1
} finally {
  await rm(temporary, { recursive: true, force: true })
}

async function writeFixture(cwd: string): Promise<void> {
  await Promise.all([mkdir(join(cwd, "src"), { recursive: true }), mkdir(join(cwd, "test"), { recursive: true })])
  await Bun.write(
    join(cwd, "package.json"),
    `${JSON.stringify({ private: true, type: "module", scripts: { test: "bun test" } }, null, 2)}\n`
  )
  await Bun.write(
    join(cwd, "README.md"),
    `# Manifest builder

Implement \`buildManifest(records)\` in \`src/manifest.ts\`.

- Normalize package names by trimming and lowercasing.
- Ignore records whose normalized name is empty.
- Merge duplicate packages.
- Each package has unique versions sorted lexicographically and summed downloads.
- Sort packages by downloads descending, then normalized name ascending.
- Return the aggregate download total across admitted records.
- Do not mutate the input records or their version strings.
`
  )
  await Bun.write(
    join(cwd, "src/manifest.ts"),
    `export interface DownloadRecord {
  readonly name: string
  readonly version: string
  readonly downloads: number
}

export interface PackageSummary {
  readonly name: string
  readonly versions: readonly string[]
  readonly downloads: number
}

export interface Manifest {
  readonly packages: readonly PackageSummary[]
  readonly totalDownloads: number
}

export function buildManifest(_records: readonly DownloadRecord[]): Manifest {
  return { packages: [], totalDownloads: 0 }
}
`
  )
  await Bun.write(
    join(cwd, "test/manifest.test.ts"),
    `import { expect, test } from "bun:test"
import { buildManifest } from "../src/manifest.js"

test("normalizes, merges, sorts, and totals records", () => {
  const records = [
    { name: " Alpha ", version: "2.0.0", downloads: 4 },
    { name: "beta", version: "1.0.0", downloads: 9 },
    { name: "ALPHA", version: "1.0.0", downloads: 7 },
    { name: "alpha", version: "2.0.0", downloads: 3 },
    { name: "  ", version: "ignored", downloads: 100 },
    { name: "gamma", version: "3.0.0", downloads: 9 }
  ] as const
  expect(buildManifest(records)).toEqual({
    packages: [
      { name: "alpha", versions: ["1.0.0", "2.0.0"], downloads: 14 },
      { name: "beta", versions: ["1.0.0"], downloads: 9 },
      { name: "gamma", versions: ["3.0.0"], downloads: 9 }
    ],
    totalDownloads: 32
  })
  expect(records[0]).toEqual({ name: " Alpha ", version: "2.0.0", downloads: 4 })
})

test("handles empty input", () => {
  expect(buildManifest([])).toEqual({ packages: [], totalDownloads: 0 })
})
`
  )
}

async function evaluate(mode: "direct" | "code", cwd: string, model: string | undefined): Promise<RunReport> {
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
  const assistants = events.flatMap(event =>
    event.type === "message_end" && isRecord(event.message) && event.message.role === "assistant" ? [event.message] : []
  )
  const providerErrors = assistants.filter(message => message.stopReason === "error").length
  const usage = assistants.reduce<RunReport["usage"]>(
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
    return isRecord(details) && details.type === "code_mode_prototype" ? [details] : []
  })
  const nestedCalls = codeExecutions.reduce(
    (sum, details) => sum + (Array.isArray(details.calls) ? details.calls.length : 0),
    0
  )
  const finalAssistant = assistants.at(-1)
  const finalText = finalAssistant && Array.isArray(finalAssistant.content) ? assistantText(finalAssistant.content) : ""
  return {
    mode,
    exitCode,
    durationMs: Date.now() - startedAt,
    correct: await testsPass(cwd),
    providerAttempts: assistants.length,
    providerTurns: assistants.length - providerErrors,
    providerErrors,
    outerToolCalls,
    effectiveToolCalls: nestedCalls || outerToolCalls,
    usage,
    codeExecutions,
    finalText,
    stderr
  }
}

async function testsPass(cwd: string): Promise<boolean> {
  const child = Bun.spawn([process.execPath, "test"], { cwd, stdin: "ignore", stdout: "ignore", stderr: "ignore" })
  return (await child.exited) === 0 && (await readFile(join(cwd, "src/manifest.ts"), "utf8")).includes("buildManifest")
}

function assistantText(content: readonly unknown[]): string {
  return content
    .flatMap(part => (isRecord(part) && part.type === "text" && typeof part.text === "string" ? [part.text] : []))
    .join("\n")
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

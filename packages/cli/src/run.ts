import {
  createAgentRuntime,
  runPrintMode,
  type AgentRuntime,
  type AgentSession,
  type CreateAgentRuntimeOptions,
  type PrintModeResult
} from "@openzi/coding-agent"

import { parseArgs, type Args } from "./args.js"
import { openziVersion } from "./version.js"

export const maxCliStdinBytes = 8 * 1024 * 1024
export const cliShutdownTimeoutMs = 5_000

export type AppMode = "interactive" | "text" | "json"
export type CliSignal = "SIGHUP" | "SIGINT" | "SIGTERM"

export interface CliHost {
  readonly stdinIsTTY: boolean
  readonly stdoutIsTTY: boolean
  readStdin(): Promise<string | undefined>
  writeStdout(chunk: string): Promise<void>
  writeStderr(chunk: string): Promise<void>
  createRuntime(options: CreateAgentRuntimeOptions): Promise<AgentRuntime>
  runInteractive(session: AgentSession, initialMessages: readonly string[]): Promise<void>
  onSignal(listener: (signal: CliSignal) => void): () => void
}

export const helpText = `Usage: openzi [options] [prompt ...]

Options:
  -p, --print                 Print the final response and exit
      --mode text             Print the final response and exit
      --mode json             Emit header-first JSONL session events
      --cwd path              Set the effective working directory
      --model provider/model  Select a model
      --api-key key           Use a memory-only provider API key
      --session file          Resume a session file
      --no-session            Do not persist the session
  -h, --help                  Show this help
  -V, --version               Show the OpenZi version

Piped stdin is the first prompt; positional prompts follow in argument order.
RPC mode is not available yet.
`

export const versionText = `openzi ${openziVersion}\n`

export function resolveAppMode(args: Args, stdinIsTTY: boolean, stdoutIsTTY: boolean): AppMode {
  if (args.mode === "json") return "json"
  if (args.mode === "text" || args.print || !stdinIsTTY || !stdoutIsTTY) return "text"
  return "interactive"
}

export async function runCli(argv: readonly string[], host: CliHost): Promise<number> {
  let args: Args
  try {
    args = parseArgs(argv)
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  }

  if (args.help) {
    await host.writeStdout(helpText)
    return 0
  }
  if (args.version) {
    await host.writeStdout(versionText)
    return 0
  }

  const mode = resolveAppMode(args, host.stdinIsTTY, host.stdoutIsTTY)
  let stdin: string | undefined
  if (!host.stdinIsTTY) {
    try {
      stdin = await host.readStdin()
    } catch (cause) {
      await host.writeStderr(`${errorMessage(cause)}\n`)
      return 1
    }
    if (stdin !== undefined && Buffer.byteLength(stdin) > maxCliStdinBytes) {
      await host.writeStderr(`Piped stdin cannot exceed ${maxCliStdinBytes} bytes\n`)
      return 1
    }
  }
  const prompts = Object.freeze([...(stdin ? [stdin] : []), ...args.messages])
  if (mode !== "interactive" && prompts.length === 0) {
    await host.writeStderr("Headless mode requires a prompt or piped stdin\n")
    return 1
  }

  let runtime: AgentRuntime
  try {
    runtime = await host.createRuntime(runtimeOptions(args))
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  }

  try {
    for (const diagnostic of runtime.services.settingsManager.drainErrors()) {
      // Keep scoped diagnostics ordered on the single stderr writer.
      // oxlint-disable-next-line no-await-in-loop
      await host.writeStderr(`Warning: (${diagnostic.scope} settings) ${diagnostic.error.message}\n`)
    }
    if (mode === "interactive") {
      await host.runInteractive(runtime.session, prompts)
      return 0
    }
    return await runHeadless(runtime.session, mode, prompts, host)
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  } finally {
    runtime.session.dispose()
  }
}

function runtimeOptions(args: Args): CreateAgentRuntimeOptions {
  return {
    cwd: args.cwd,
    persist: !args.noSession,
    ...(args.model === undefined ? {} : { model: args.model }),
    ...(args.apiKey === undefined ? {} : { apiKey: args.apiKey }),
    ...(args.sessionFile === undefined ? {} : { sessionFile: args.sessionFile })
  }
}

async function runHeadless(
  session: AgentSession,
  output: "text" | "json",
  prompts: readonly string[],
  host: CliHost
): Promise<number> {
  let signal: CliSignal | undefined
  const requested = deferred<void>()
  const removeSignals = host.onSignal(received => {
    if (signal) return
    signal = received
    try {
      void session.abortAndDiscardQueuedInputs().catch(() => {})
    } catch {}
    requested.resolve()
  })

  const run = runPrintMode(session, { output, prompts, writer: { write: chunk => host.writeStdout(chunk) } })
  const completion = run.then(result => ({ type: "result" as const, result }))
  const shutdown = requested.promise.then(async () => {
    try {
      const result = await settle(run, cliShutdownTimeoutMs)
      return { type: "result" as const, result }
    } catch (cause) {
      return { type: "shutdown_error" as const, cause }
    }
  })

  try {
    const outcome = await Promise.race([completion, shutdown])
    if (outcome.type === "shutdown_error") await host.writeStderr(`${errorMessage(outcome.cause)}\n`)
    else if (outcome.result.type !== "success") await host.writeStderr(`${outcome.result.message}\n`)
    if (signal) return signalExitCode(signal)
    return outcome.type === "result" ? resultExitCode(outcome.result) : 1
  } finally {
    removeSignals()
  }
}

function resultExitCode(result: PrintModeResult): number {
  return result.type === "success" ? 0 : 1
}

function signalExitCode(signal: CliSignal): number {
  if (signal === "SIGHUP") return 129
  if (signal === "SIGINT") return 130
  return 143
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function settle<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation,
    new Promise<T>((_, reject) => {
      timeout = setTimeout(() => reject(new Error("Headless shutdown timed out")), timeoutMs)
    })
  ]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

export const defaultRuntimeFactory = createAgentRuntime

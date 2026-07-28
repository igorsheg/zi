import {
  createAgentRuntime,
  createAgentSessionRuntime,
  runPrintMode,
  type AgentRuntime,
  type AgentSession,
  type AgentSessionRuntime,
  type CreateAgentRuntimeOptions,
  type PrintModeResult,
  type RpcModeResult
} from "@with-zi/coding-agent"

import { parseArgs, resolveCliInvocation, type CliInvocation, type CliMode, type ParsedArgs } from "./args.js"
import { ziVersion } from "./version.js"

export const maxCliStdinBytes = 8 * 1024 * 1024
export const cliShutdownTimeoutMs = 5_000

export type AppMode = "interactive" | "text" | "json" | "rpc"
export type CliSignal = "SIGHUP" | "SIGINT" | "SIGTERM"

export interface CliHost {
  readonly cwd: string
  readonly home: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly stdinIsTTY: boolean
  readonly stdoutIsTTY: boolean
  readonly extensionWorkerCommand: readonly string[]
  readStdin(): Promise<string | undefined>
  writeStdout(chunk: string): Promise<void>
  writeStderr(chunk: string): Promise<void>
  createRuntime(options: CreateAgentRuntimeOptions): Promise<AgentRuntime>
  createSessionRuntime(options: CreateAgentRuntimeOptions): Promise<AgentSessionRuntime>
  runInteractive(runtime: AgentSessionRuntime, initialMessages: readonly string[]): Promise<void>
  runRpc(session: AgentSession, signal: AbortSignal): Promise<RpcModeResult>
  onSignal(listener: (signal: CliSignal) => void): () => void
}

export const helpText = `Usage: zi [options] [prompt ...]

Output:
  -p, --print                 Alias for --mode text
      --mode mode             auto, interactive, text, json, or rpc

Runtime:
      --cwd path              Set the effective working directory
      --agent-dir path        Set the global Zi agent directory
      --session-dir path      Set session storage for this invocation
      --model provider/model  Select a model
      --thinking level        off, minimal, low, medium, high, xhigh, or max
      --api-key key           Use a memory-only key for the selected provider
      --system-prompt text    Replace the built-in system prompt
      --append-system-prompt text
                              Append system prompt text; repeatable
      --extension path        Load an explicit extension source; repeatable

Session:
  -r, --resume file           Resume a session file
  -c, --continue              Continue the most recent session
      --new-session           Start a persistent new session
      --no-session            Start an ephemeral new session

Other:
  -h, --help                  Show this help
  -V, --version               Show the Zi version

Environment defaults:
  ZI_MODE                     auto, interactive, text, json, or rpc
  ZI_AGENT_DIR                Global agent directory
  ZI_SESSION_DIR              Session storage directory
  ZI_DEFAULT_MODEL            provider/model selection
  ZI_DEFAULT_THINKING         Default thinking level for this invocation

CLI values override environment defaults. Within argv, the last scalar or
session selector wins; repeatable append-system-prompt values keep their order.
Piped stdin is the first prompt; positional prompts follow in argument order.
Provider credential variables such as ANTHROPIC_API_KEY remain supported.
RPC reads versioned JSONL requests from stdin and writes only protocol frames to stdout.
`

export const versionText = `zi ${ziVersion}\n`

export function resolveAppMode(mode: CliMode, stdinIsTTY: boolean, stdoutIsTTY: boolean): AppMode {
  switch (mode) {
    case "text":
    case "json":
    case "rpc":
      return mode
    case "interactive":
      if (!stdinIsTTY || !stdoutIsTTY) throw new Error("Interactive mode requires TTY stdin and stdout")
      return "interactive"
    case "auto":
      return stdinIsTTY && stdoutIsTTY ? "interactive" : "text"
    default:
      return assertNever(mode)
  }
}

export async function runCli(argv: readonly string[], host: CliHost): Promise<number> {
  let parsed: ParsedArgs
  try {
    parsed = parseArgs(argv)
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  }

  if (parsed.help) {
    await host.writeStdout(helpText)
    return 0
  }
  if (parsed.version) {
    await host.writeStdout(versionText)
    return 0
  }

  let args: CliInvocation
  let mode: AppMode
  try {
    args = resolveCliInvocation(parsed, host)
    mode = resolveAppMode(args.mode, host.stdinIsTTY, host.stdoutIsTTY)
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  }
  if (mode === "rpc" && args.messages.length > 0) {
    await host.writeStderr("RPC mode accepts input only through its JSONL protocol\n")
    return 1
  }
  let stdin: string | undefined
  if (mode !== "rpc" && !host.stdinIsTTY) {
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
  if (mode !== "interactive" && mode !== "rpc" && prompts.length === 0) {
    await host.writeStderr("Headless mode requires a prompt or piped stdin\n")
    return 1
  }

  let runtime: AgentRuntime
  let sessionRuntime: AgentSessionRuntime | undefined
  try {
    if (mode === "interactive") {
      sessionRuntime = await host.createSessionRuntime(runtimeOptions(args, host.extensionWorkerCommand))
      runtime = sessionRuntime
    } else {
      runtime = await host.createRuntime(runtimeOptions(args, host.extensionWorkerCommand))
    }
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  }

  let exitCode: number
  try {
    if (runtime.projectTrust.diagnostic) {
      await host.writeStderr(`Warning: ${runtime.projectTrust.diagnostic.message}\n`)
    }
    for (const diagnostic of runtime.services.settingsManager.drainErrors()) {
      // Keep scoped diagnostics ordered on the single stderr writer.
      // oxlint-disable-next-line no-await-in-loop
      await host.writeStderr(`Warning: (${diagnostic.scope} settings) ${diagnostic.error.message}\n`)
    }
    const extensionSnapshot = runtime.session.extensionHostSnapshot
    if (extensionSnapshot) {
      const diagnostics =
        extensionSnapshot.failure && !extensionSnapshot.diagnostics.includes(extensionSnapshot.failure)
          ? [...extensionSnapshot.diagnostics, extensionSnapshot.failure]
          : extensionSnapshot.diagnostics
      for (const diagnostic of diagnostics) {
        const source = diagnostic.path ? ` ${diagnosticLine(diagnostic.path)}` : ""
        // Keep extension diagnostics ordered without contaminating protocol stdout.
        // oxlint-disable-next-line no-await-in-loop
        await host.writeStderr(`Warning: (extension${source}) ${diagnosticLine(diagnostic.message)}\n`)
      }
      if (extensionSnapshot.omittedDiagnostics > 0) {
        await host.writeStderr(
          `Warning: ${extensionSnapshot.omittedDiagnostics} additional extension diagnostics were omitted\n`
        )
      }
    }
    const bootstrapDiagnostic = runtime.bootstrapDiagnostic
    if (mode !== "interactive" && bootstrapDiagnostic && bootstrapDiagnostic.type !== "no_model") {
      await host.writeStderr(`Warning: ${bootstrapDiagnostic.message}\n`)
    }
    if (mode === "interactive") {
      if (!sessionRuntime) throw new Error("Interactive session runtime was not created")
      await host.runInteractive(sessionRuntime, prompts)
      exitCode = 0
    } else if (mode === "rpc") {
      exitCode = await runRpc(runtime.session, host)
    } else {
      exitCode = await runHeadless(runtime.session, mode, prompts, host)
    }
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    exitCode = 1
  }

  if (sessionRuntime) sessionRuntime.dispose()
  else runtime.session.dispose()
  try {
    await settle(sessionRuntime ? sessionRuntime.waitForIdle() : runtime.session.waitForIdle(), cliShutdownTimeoutMs)
  } catch (cause) {
    await host.writeStderr(`${errorMessage(cause)}\n`)
    return 1
  }
  return exitCode
}

function runtimeOptions(args: CliInvocation, extensionWorkerCommand: readonly string[]): CreateAgentRuntimeOptions {
  return {
    cwd: args.cwd,
    agentDir: args.agentDir,
    extensionPaths: args.extensionPaths,
    extensionWorkerCommand,
    session: args.session,
    ...(args.sessionDir === undefined ? {} : { sessionDir: args.sessionDir }),
    ...(args.model === undefined ? {} : { model: args.model }),
    ...(args.thinkingLevel === undefined ? {} : { thinkingLevel: args.thinkingLevel }),
    ...(args.apiKey === undefined ? {} : { apiKey: args.apiKey }),
    ...(args.systemPrompt === undefined ? {} : { systemPrompt: args.systemPrompt }),
    ...(args.appendSystemPrompt === undefined ? {} : { appendSystemPrompt: args.appendSystemPrompt })
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

async function runRpc(session: AgentSession, host: CliHost): Promise<number> {
  let signal: CliSignal | undefined
  const controller = new AbortController()
  const removeSignals = host.onSignal(received => {
    if (signal) return
    signal = received
    controller.abort()
    try {
      void session.abortAndDiscardQueuedInputs().catch(() => {})
    } catch {}
  })

  try {
    const result = await host.runRpc(session, controller.signal)
    if (result.type !== "eof" && result.type !== "cancelled") await host.writeStderr(`${result.message}\n`)
    if (signal) return signalExitCode(signal)
    return result.type === "eof" ? 0 : 1
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

function assertNever(value: never): never {
  throw new Error(`Unknown CLI state: ${String(value)}`)
}

function diagnosticLine(value: string): string {
  return value.replace(/[\r\n]+/g, " ")
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function settle<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation,
    new Promise<T>((_, reject) => {
      timeout = setTimeout(() => reject(new Error("Session disposal timed out")), timeoutMs)
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
export const defaultSessionRuntimeFactory = createAgentSessionRuntime

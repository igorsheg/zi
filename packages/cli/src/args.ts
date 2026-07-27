import { isAbsolute } from "node:path"

import { getDefaultAgentDir, resolveZiPath, type ThinkingLevel } from "@with-zi/coding-agent"

export type CliOutputMode = "text" | "json"
export type CliMode = "auto" | "interactive" | CliOutputMode

export type CliSession =
  | { readonly type: "new"; readonly persist: true }
  | { readonly type: "new"; readonly persist: false }
  | { readonly type: "continue" }
  | { readonly type: "resume"; readonly file: string }

export interface ParsedArgs {
  readonly cwd?: string
  readonly agentDir?: string
  readonly sessionDir?: string
  readonly model?: string
  readonly thinkingLevel?: ThinkingLevel
  readonly apiKey?: string
  readonly systemPrompt?: string
  readonly appendSystemPrompt?: readonly string[]
  readonly extensionPaths?: readonly string[]
  readonly session?: CliSession
  readonly mode?: CliMode
  readonly messages: readonly string[]
  readonly help: boolean
  readonly version: boolean
}

export interface CliInvocation {
  readonly cwd: string
  readonly agentDir: string
  readonly sessionDir?: string
  readonly model?: string
  readonly thinkingLevel?: ThinkingLevel
  readonly apiKey?: string
  readonly systemPrompt?: string
  readonly appendSystemPrompt?: readonly string[]
  readonly extensionPaths: readonly string[]
  readonly session: CliSession
  readonly mode: CliMode
  readonly messages: readonly string[]
}

export interface CliResolutionContext {
  readonly cwd: string
  readonly home: string
  readonly env: Readonly<Record<string, string | undefined>>
}

const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const

export function parseArgs(argv: readonly string[]): ParsedArgs {
  let cwd: string | undefined
  let agentDir: string | undefined
  let sessionDir: string | undefined
  let model: string | undefined
  let thinkingLevel: ThinkingLevel | undefined
  let apiKey: string | undefined
  let systemPrompt: string | undefined
  let appendSystemPrompt: string[] | undefined
  let extensionPaths: string[] | undefined
  let session: CliSession | undefined
  let mode: CliMode | undefined
  let help = false
  let version = false
  const messages: string[] = []

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]
    if (arg === "--") {
      messages.push(...argv.slice(index + 1))
      break
    }
    if (arg === undefined) continue

    const option = splitLongOption(arg)
    const flag = option?.flag ?? arg
    const inlineValue = option?.value

    if (flag === "--cwd") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      cwd = value
      index = nextIndex
    } else if (flag === "--agent-dir") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      agentDir = value
      index = nextIndex
    } else if (flag === "--session-dir") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      sessionDir = value
      index = nextIndex
    } else if (flag === "--model") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      model = value
      index = nextIndex
    } else if (flag === "--thinking") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      thinkingLevel = parseThinkingLevel(value, flag)
      index = nextIndex
    } else if (flag === "--api-key") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      apiKey = value
      index = nextIndex
    } else if (flag === "--system-prompt") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      systemPrompt = value
      index = nextIndex
    } else if (flag === "--append-system-prompt") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      appendSystemPrompt ??= []
      appendSystemPrompt.push(value)
      index = nextIndex
    } else if (flag === "--extension") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      extensionPaths ??= []
      extensionPaths.push(value)
      index = nextIndex
    } else if (flag === "--resume" || flag === "-r") {
      const [file, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      session = Object.freeze({ type: "resume", file })
      index = nextIndex
    } else if (flag === "--continue" || flag === "-c") {
      rejectInlineValue(flag, inlineValue)
      session = Object.freeze({ type: "continue" })
    } else if (flag === "--new-session") {
      rejectInlineValue(flag, inlineValue)
      session = Object.freeze({ type: "new", persist: true })
    } else if (flag === "--no-session") {
      rejectInlineValue(flag, inlineValue)
      session = Object.freeze({ type: "new", persist: false })
    } else if (flag === "--print" || flag === "-p") {
      rejectInlineValue(flag, inlineValue)
      mode = "text"
    } else if (flag === "--mode") {
      const [value, nextIndex] = requiredValue(argv, index, flag, inlineValue)
      mode = parseMode(value, flag)
      index = nextIndex
    } else if (flag === "--help" || flag === "-h") {
      rejectInlineValue(flag, inlineValue)
      help = true
    } else if (flag === "--version" || flag === "-V") {
      rejectInlineValue(flag, inlineValue)
      version = true
    } else if (arg.startsWith("-")) {
      throw new Error(`Unknown argument: ${arg}`)
    } else {
      messages.push(arg)
    }
  }

  return Object.freeze({
    messages: Object.freeze(messages),
    help,
    version,
    ...(cwd === undefined ? {} : { cwd }),
    ...(agentDir === undefined ? {} : { agentDir }),
    ...(sessionDir === undefined ? {} : { sessionDir }),
    ...(model === undefined ? {} : { model }),
    ...(thinkingLevel === undefined ? {} : { thinkingLevel }),
    ...(apiKey === undefined ? {} : { apiKey }),
    ...(systemPrompt === undefined ? {} : { systemPrompt }),
    ...(appendSystemPrompt === undefined ? {} : { appendSystemPrompt: Object.freeze(appendSystemPrompt) }),
    ...(extensionPaths === undefined ? {} : { extensionPaths: Object.freeze(extensionPaths) }),
    ...(session === undefined ? {} : { session }),
    ...(mode === undefined ? {} : { mode })
  })
}

export function resolveCliInvocation(parsed: ParsedArgs, context: CliResolutionContext): CliInvocation {
  const cwd = resolveZiPath(parsed.cwd ?? context.cwd, context.cwd, context.home)
  const agentDir = resolveZiPath(
    parsed.agentDir ?? environmentValue(context.env, "ZI_AGENT_DIR") ?? getDefaultAgentDir(context.home),
    context.cwd,
    context.home
  )
  const sessionDirValue = parsed.sessionDir ?? environmentValue(context.env, "ZI_SESSION_DIR")
  const sessionDir = sessionDirValue === undefined ? undefined : resolveSessionDirectory(sessionDirValue, context)
  const model = parsed.model ?? environmentValue(context.env, "ZI_DEFAULT_MODEL")
  const thinkingLevel = parsed.thinkingLevel ?? environmentThinkingLevel(context.env)
  const mode = parsed.mode ?? environmentMode(context.env) ?? "auto"
  const session = resolveSession(parsed.session, context)
  const extensionPaths = Object.freeze(
    (parsed.extensionPaths ?? []).map(path => resolveZiPath(path, context.cwd, context.home))
  )

  return Object.freeze({
    cwd,
    agentDir,
    extensionPaths,
    session,
    mode,
    messages: parsed.messages,
    ...(sessionDir === undefined ? {} : { sessionDir }),
    ...(model === undefined ? {} : { model }),
    ...(thinkingLevel === undefined ? {} : { thinkingLevel }),
    ...(parsed.apiKey === undefined ? {} : { apiKey: parsed.apiKey }),
    ...(parsed.systemPrompt === undefined ? {} : { systemPrompt: parsed.systemPrompt }),
    ...(parsed.appendSystemPrompt === undefined ? {} : { appendSystemPrompt: parsed.appendSystemPrompt })
  })
}

function splitLongOption(arg: string): { readonly flag: string; readonly value: string } | undefined {
  if (!arg.startsWith("--")) return undefined
  const separator = arg.indexOf("=")
  if (separator === -1) return undefined
  return { flag: arg.slice(0, separator), value: arg.slice(separator + 1) }
}

function requiredValue(
  argv: readonly string[],
  index: number,
  flag: string,
  inlineValue: string | undefined
): [value: string, nextIndex: number] {
  const value = inlineValue ?? argv[index + 1]
  if (value === undefined || value.trim().length === 0) throw new Error(`${flag} requires a value`)
  return [value, inlineValue === undefined ? index + 1 : index]
}

function rejectInlineValue(flag: string, inlineValue: string | undefined): void {
  if (inlineValue !== undefined) throw new Error(`${flag} does not take a value`)
}

function parseMode(value: string, source: string): CliMode {
  if (value === "auto" || value === "interactive" || value === "text" || value === "json") return value
  if (value === "rpc") throw new Error("RPC mode is not available yet")
  throw new Error(`Invalid ${source} value: ${value} (expected auto, interactive, text, or json)`)
}

function parseThinkingLevel(value: string, source: string): ThinkingLevel {
  switch (value) {
    case "off":
    case "minimal":
    case "low":
    case "medium":
    case "high":
    case "xhigh":
    case "max":
      return value
    default:
      throw new Error(`Invalid ${source} value: ${value} (expected ${thinkingLevels.join(", ")})`)
  }
}

function resolveSession(session: CliSession | undefined, context: CliResolutionContext): CliSession {
  if (session === undefined) return Object.freeze({ type: "new", persist: true })
  switch (session.type) {
    case "new":
    case "continue":
      return session
    case "resume":
      return Object.freeze({ type: "resume", file: resolveZiPath(session.file, context.cwd, context.home) })
    default:
      return assertNever(session)
  }
}

function resolveSessionDirectory(value: string, context: CliResolutionContext): string {
  if (isAbsolute(value) || value === "~" || value.startsWith("~/") || value.startsWith("~\\")) {
    return resolveZiPath(value, context.cwd, context.home)
  }
  return value
}

function environmentThinkingLevel(env: Readonly<Record<string, string | undefined>>): ThinkingLevel | undefined {
  const value = environmentValue(env, "ZI_DEFAULT_THINKING")
  return value === undefined ? undefined : parseThinkingLevel(value, "ZI_DEFAULT_THINKING")
}

function environmentMode(env: Readonly<Record<string, string | undefined>>): CliMode | undefined {
  const value = environmentValue(env, "ZI_MODE")
  return value === undefined ? undefined : parseMode(value, "ZI_MODE")
}

function assertNever(value: never): never {
  throw new Error(`Unknown CLI session: ${String(value)}`)
}

function environmentValue(env: Readonly<Record<string, string | undefined>>, name: string): string | undefined {
  const value = env[name]
  if (value === undefined) return undefined
  if (value.trim().length === 0) throw new Error(`${name} must not be empty`)
  return value
}

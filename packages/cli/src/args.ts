export type CliOutputMode = "text" | "json"

export interface Args {
  readonly cwd: string
  readonly model?: string
  readonly apiKey?: string
  readonly sessionFile?: string
  readonly continueRecent?: boolean
  readonly noSession: boolean
  readonly print: boolean
  readonly mode?: CliOutputMode
  readonly messages: readonly string[]
  readonly help: boolean
  readonly version: boolean
}

export function parseArgs(argv: readonly string[]): Args {
  let cwd = process.cwd()
  let model: string | undefined
  let apiKey: string | undefined
  let sessionFile: string | undefined
  let continueRecent = false
  let noSession = false
  let print = false
  let mode: CliOutputMode | undefined
  let help = false
  let version = false
  const messages: string[] = []

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]
    if (arg === "--") {
      messages.push(...argv.slice(index + 1))
      break
    }
    if (arg === "--cwd") cwd = required(argv[++index], "--cwd")
    else if (arg === "--model") model = required(argv[++index], "--model")
    else if (arg === "--api-key") apiKey = required(argv[++index], "--api-key")
    else if (arg === "--resume" || arg === "-r") {
      sessionFile = required(argv[++index], arg)
    } else if (arg === "--continue" || arg === "-c") continueRecent = true
    else if (arg === "--no-session") noSession = true
    else if (arg === "--print" || arg === "-p") print = true
    else if (arg === "--mode") mode = parseMode(required(argv[++index], "--mode"))
    else if (arg === "--help" || arg === "-h") help = true
    else if (arg === "--version" || arg === "-V") version = true
    else if (arg?.startsWith("-")) throw new Error(`Unknown argument: ${arg}`)
    else if (arg !== undefined) messages.push(arg)
  }

  if (sessionFile && continueRecent) throw new Error("--resume and --continue cannot be used together")
  if ((sessionFile || continueRecent) && noSession) {
    throw new Error("--resume/--continue and --no-session cannot be used together")
  }

  return Object.freeze({
    cwd,
    noSession,
    print,
    messages: Object.freeze(messages),
    help,
    version,
    ...(model === undefined ? {} : { model }),
    ...(apiKey === undefined ? {} : { apiKey }),
    ...(sessionFile === undefined ? {} : { sessionFile }),
    ...(continueRecent ? { continueRecent: true } : {}),
    ...(mode === undefined ? {} : { mode })
  })
}

function parseMode(value: string): CliOutputMode {
  if (value === "text" || value === "json") return value
  if (value === "rpc") throw new Error("RPC mode is not available yet")
  throw new Error(`Invalid --mode value: ${value} (expected text or json)`)
}

function required(value: string | undefined, flag: string): string {
  if (!value) throw new Error(`${flag} requires a value`)
  return value
}

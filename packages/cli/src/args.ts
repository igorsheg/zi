export interface Args {
  cwd: string
  model?: string
  apiKey?: string
  sessionFile?: string
  noSession: boolean
}

export function parseArgs(argv: string[]): Args {
  let cwd = process.cwd()
  let model: string | undefined
  let apiKey: string | undefined
  let sessionFile: string | undefined
  let noSession = false

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]
    if (arg === "--cwd") cwd = required(argv[++index], "--cwd")
    else if (arg === "--model") model = required(argv[++index], "--model")
    else if (arg === "--api-key") apiKey = required(argv[++index], "--api-key")
    else if (arg === "--session") sessionFile = required(argv[++index], "--session")
    else if (arg === "--no-session") noSession = true
    else if (arg === "--help" || arg === "-h") {
      process.stdout.write(
        "Usage: openzi [--cwd path] [--model provider/model-id] [--api-key key] [--session file] [--no-session]\n"
      )
      process.exit(0)
    } else throw new Error(`Unknown argument: ${arg}`)
  }

  if (sessionFile && noSession) throw new Error("--session and --no-session cannot be used together")

  return {
    cwd,
    noSession,
    ...(model === undefined ? {} : { model }),
    ...(apiKey === undefined ? {} : { apiKey }),
    ...(sessionFile === undefined ? {} : { sessionFile })
  }
}

function required(value: string | undefined, flag: string): string {
  if (!value) throw new Error(`${flag} requires a value`)
  return value
}

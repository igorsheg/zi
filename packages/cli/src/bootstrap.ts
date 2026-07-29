import { codeModeWorkerArgument } from "@with-zi/coding-agent/internal/code-mode-worker-mode"
import { extensionWorkerArgument } from "@with-zi/coding-agent/internal/extension-worker-mode"

export type StandaloneRoute = "help" | "version" | "code_mode_worker" | "extension_worker" | "main"

export function standaloneRoute(argv: readonly string[]): StandaloneRoute {
  if (argv.length !== 1) return "main"
  switch (argv[0]) {
    case "-h":
    case "--help":
      return "help"
    case "-V":
    case "--version":
      return "version"
    case codeModeWorkerArgument:
      return "code_mode_worker"
    case extensionWorkerArgument:
      return "extension_worker"
    default:
      return "main"
  }
}

export function defaultCliArgv(argv: readonly string[] = process.argv): readonly string[] {
  // Bun standalone argv includes a virtual script path whose Windows spelling has changed across releases.
  if (argv.at(-1) === codeModeWorkerArgument) return [codeModeWorkerArgument]
  if (argv.at(-1) === extensionWorkerArgument) return [extensionWorkerArgument]
  const second = argv[1]
  if (!second) return []
  if (second.startsWith("-")) return argv.slice(1)
  if (second.includes("$bunfs") || /\.[cm]?[jt]sx?$/.test(second)) return argv.slice(2)
  if (/(^|[\\/])bun(?:\.exe)?$/i.test(argv[0] ?? "")) return argv.slice(2)
  return argv.slice(1)
}

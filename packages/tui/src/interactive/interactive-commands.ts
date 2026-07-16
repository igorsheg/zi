import {
  builtinSlashCommands,
  type AgentSession,
  type BuiltinSlashCommandName,
  type SlashCommand
} from "@openzi/coding-agent"

export type InteractiveCommand =
  | { readonly type: "model"; readonly search: string }
  | { readonly type: "login"; readonly provider: string }
  | { readonly type: "logout" }
  | { readonly type: "settings" }
  | { readonly type: "new_session" }
  | { readonly type: "resume_session" }

export interface InteractiveCommands {
  suggestions(text: string, cursorOffset: number): readonly SlashCommand[]
  completion(command: SlashCommand): string
  parse(text: string): InteractiveCommand | undefined
}

export function createInteractiveCommands(
  getSession?: () => Pick<AgentSession, "listResourceCommands">
): InteractiveCommands {
  const commands = (): readonly SlashCommand[] => {
    const byName = new Map<string, SlashCommand>()
    for (const command of builtinSlashCommands) byName.set(command.name, command)
    for (const command of getSession?.().listResourceCommands() ?? []) {
      if (!byName.has(command.name)) byName.set(command.name, command)
    }
    return [...byName.values()]
  }

  return {
    suggestions(text, cursorOffset) {
      const query = slashCommandQuery(text, cursorOffset)
      if (query === undefined) return []
      return commands().filter(command => command.name.startsWith(query))
    },
    completion(command) {
      return `/${command.name} `
    },
    parse(text) {
      const command = builtinSlashCommands.find(candidate => invokes(text, candidate.name))
      if (!command) return undefined

      switch (command.name) {
        case "model":
          return { type: "model", search: text === "/model" ? "" : text.slice(7).trim() }
        case "login":
          return { type: "login", provider: text === "/login" ? "" : text.slice(7).trim() }
        case "logout":
          return { type: "logout" }
        case "settings":
          return { type: "settings" }
        case "new":
          return { type: "new_session" }
        case "resume":
          return { type: "resume_session" }
        default:
          return assertNever(command.name)
      }
    }
  }
}

function slashCommandQuery(text: string, cursorOffset: number): string | undefined {
  const beforeCursor = text.slice(0, cursorOffset)
  if (beforeCursor.includes("\n")) return undefined
  const prefix = beforeCursor.trimStart()
  if (!prefix.startsWith("/") || prefix.slice(1).includes("/") || /\s/.test(prefix)) return undefined
  return prefix.slice(1)
}

function invokes(text: string, name: BuiltinSlashCommandName): boolean {
  return text === `/${name}` || text.startsWith(`/${name} `)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected built-in slash command: ${String(value)}`)
}

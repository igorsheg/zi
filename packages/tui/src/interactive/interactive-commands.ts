import { builtinSlashCommands, type BuiltinSlashCommand, type BuiltinSlashCommandName } from "@openzi/coding-agent"

export type InteractiveCommand =
  | { readonly type: "model"; readonly search: string }
  | { readonly type: "login"; readonly provider: string }
  | { readonly type: "logout" }

export interface InteractiveCommands {
  suggestions(text: string, cursorOffset: number): readonly BuiltinSlashCommand[]
  completion(command: BuiltinSlashCommand): string
  parse(text: string): InteractiveCommand | undefined
}

export function createInteractiveCommands(): InteractiveCommands {
  return {
    suggestions(text, cursorOffset) {
      const query = slashCommandQuery(text, cursorOffset)
      if (query === undefined) return []
      return builtinSlashCommands.filter(command => command.name.startsWith(query))
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

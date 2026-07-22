const definitions = [
  { name: "model", description: "Select model (opens selector UI)", argumentHint: "<provider/model>" },
  { name: "login", description: "Authenticate a provider", argumentHint: "<provider>" },
  { name: "logout", description: "Remove stored provider credentials" },
  { name: "settings", description: "Open settings menu" },
  { name: "compact", description: "Compact context, optionally preserving a specified focus", argumentHint: "[focus]" },
  { name: "new", description: "Start a new session" },
  { name: "resume", description: "Browse and resume saved sessions" }
] as const

export type BuiltinSlashCommandName = (typeof definitions)[number]["name"]

export interface SlashCommand {
  readonly name: string
  readonly description: string
  readonly argumentHint?: string
}

export interface BuiltinSlashCommand extends SlashCommand {
  readonly name: BuiltinSlashCommandName
}

export const builtinSlashCommands: readonly BuiltinSlashCommand[] = definitions

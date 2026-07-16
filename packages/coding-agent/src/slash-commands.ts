const definitions = [
  { name: "model", description: "Select model (opens selector UI)", argumentHint: "<provider/model>" },
  { name: "login", description: "Authenticate a provider", argumentHint: "<provider>" },
  { name: "logout", description: "Remove stored provider credentials" },
  { name: "settings", description: "Open settings menu" }
] as const

export type BuiltinSlashCommandName = (typeof definitions)[number]["name"]

export interface BuiltinSlashCommand {
  readonly name: BuiltinSlashCommandName
  readonly description: string
  readonly argumentHint?: string
}

export const builtinSlashCommands: readonly BuiltinSlashCommand[] = definitions

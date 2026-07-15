const definitions = [
  { name: "model", description: "Select model (opens selector UI)", argumentHint: "<provider/model>" }
] as const

export type BuiltinSlashCommandName = (typeof definitions)[number]["name"]

export interface BuiltinSlashCommand {
  readonly name: BuiltinSlashCommandName
  readonly description: string
  readonly argumentHint?: string
}

export const builtinSlashCommands: readonly BuiltinSlashCommand[] = definitions

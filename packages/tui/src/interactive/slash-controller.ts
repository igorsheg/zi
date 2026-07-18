import {
  builtinSlashCommands,
  type AgentSession,
  type BuiltinSlashCommandName,
  type SlashCommand
} from "@openzi/coding-agent"

import { fuzzyMatch } from "./fuzzy-match.js"

export type InteractiveCommand =
  | { readonly type: "model"; readonly search: string }
  | { readonly type: "login"; readonly provider: string }
  | { readonly type: "logout" }
  | { readonly type: "settings" }
  | { readonly type: "new_session" }
  | { readonly type: "resume_session" }

export type SlashCompletion =
  | { readonly type: "unavailable" }
  | { readonly type: "edit"; readonly text: string; readonly cursorOffset: number }

export type SlashActivation = SlashCompletion | { readonly type: "intent"; readonly command: InteractiveCommand }

type CommandSession = Pick<AgentSession, "listResourceCommands">

interface SlashInput {
  readonly query: string
  readonly commandStart: number
  readonly commandEnd: number
}

export class SlashController {
  readonly #getSession: (() => CommandSession) | undefined
  readonly #getGeneration: (() => number) | undefined
  #catalogGeneration: number | undefined
  #catalog: readonly SlashCommand[] = builtinSlashCommands

  constructor(getSession?: () => CommandSession, getGeneration?: () => number) {
    this.#getSession = getSession
    this.#getGeneration = getGeneration
  }

  suggestions(text: string, cursorOffset: number): readonly SlashCommand[] {
    const input = slashInput(text, cursorOffset)
    if (!input) return []

    const commands = this.#commands()
    if (!input.query) return commands
    const query = input.query.toLowerCase()
    return commands
      .map((command, index) => {
        const match = fuzzyMatch(input.query, command.name)
        if (!match.matches) return undefined
        const name = command.name.toLowerCase()
        const rank = name === query ? 0 : name.startsWith(query) ? 1 : 2
        return { command, index, rank, score: match.score }
      })
      .filter(result => result !== undefined)
      .toSorted((left, right) => left.rank - right.rank || left.score - right.score || left.index - right.index)
      .map(result => result.command)
  }

  complete(text: string, cursorOffset: number, selectedId: string): SlashCompletion {
    const selection = this.#selection(text, cursorOffset, selectedId)
    return selection ? completionEdit(text, selection.input, selection.command) : { type: "unavailable" }
  }

  activate(text: string, cursorOffset: number, selectedId: string): SlashActivation {
    const selection = this.#selection(text, cursorOffset, selectedId)
    if (!selection) return { type: "unavailable" }
    const edit = completionEdit(text, selection.input, selection.command)
    const builtin = builtinSlashCommands.find(command => command.name === selection.command.name)
    return builtin ? { type: "intent", command: builtinIntent(builtin.name, edit.text.slice(edit.cursorOffset)) } : edit
  }

  parse(text: string): InteractiveCommand | undefined {
    const command = builtinSlashCommands.find(candidate => invokes(text, candidate.name))
    if (!command) return undefined
    const prefix = `/${command.name}`
    const args = text === prefix ? "" : text.slice(prefix.length + 1)
    return builtinIntent(command.name, args)
  }

  #commands(): readonly SlashCommand[] {
    const session = this.#getSession?.()
    if (!session) return builtinSlashCommands
    const generation = this.#getGeneration?.()
    if (generation !== undefined && generation === this.#catalogGeneration) return this.#catalog

    const byName = new Map<string, SlashCommand>()
    for (const command of builtinSlashCommands) byName.set(command.name, command)
    for (const command of session.listResourceCommands()) {
      if (!byName.has(command.name)) byName.set(command.name, command)
    }
    this.#catalogGeneration = generation
    this.#catalog = [...byName.values()]
    return this.#catalog
  }

  #selection(
    text: string,
    cursorOffset: number,
    selectedId: string
  ): { readonly input: SlashInput; readonly command: SlashCommand } | undefined {
    const input = slashInput(text, cursorOffset)
    if (!input) return undefined
    const command = this.suggestions(text, cursorOffset).find(candidate => candidate.name === selectedId)
    return command ? { input, command } : undefined
  }
}

function slashInput(text: string, cursorOffset: number): SlashInput | undefined {
  if (cursorOffset < 0 || cursorOffset > text.length || text.includes("\n")) return undefined
  const commandStart = text.search(/\S/)
  if (commandStart < 0 || text[commandStart] !== "/") return undefined

  let commandEnd = text.length
  for (let index = commandStart + 1; index < text.length; index++) {
    if (/\s/.test(text[index] ?? "")) {
      commandEnd = index
      break
    }
  }
  if (cursorOffset < commandStart + 1 || cursorOffset > commandEnd) return undefined

  const token = text.slice(commandStart + 1, commandEnd)
  if (token.includes("/")) return undefined
  return { query: text.slice(commandStart + 1, cursorOffset), commandStart, commandEnd }
}

function completionEdit(
  text: string,
  input: SlashInput,
  command: SlashCommand
): Extract<SlashCompletion, { type: "edit" }> {
  let replaceEnd = input.commandEnd
  const separator = text[replaceEnd]
  if (separator && /\s/.test(separator)) replaceEnd += separator.length
  const completion = `/${command.name} `
  return {
    type: "edit",
    text: `${text.slice(0, input.commandStart)}${completion}${text.slice(replaceEnd)}`,
    cursorOffset: input.commandStart + completion.length
  }
}

function builtinIntent(name: BuiltinSlashCommandName, args: string): InteractiveCommand {
  switch (name) {
    case "model":
      return { type: "model", search: args.trim() }
    case "login":
      return { type: "login", provider: args.trim() }
    case "logout":
      return { type: "logout" }
    case "settings":
      return { type: "settings" }
    case "new":
      return { type: "new_session" }
    case "resume":
      return { type: "resume_session" }
    default:
      return assertNever(name)
  }
}

function invokes(text: string, name: BuiltinSlashCommandName): boolean {
  return text === `/${name}` || text.startsWith(`/${name} `)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected built-in slash command: ${String(value)}`)
}

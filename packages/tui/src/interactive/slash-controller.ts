import {
  builtinSlashCommands,
  type AgentSession,
  type BuiltinSlashCommandName,
  type SlashCommand
} from "@with-zi/coding-agent"

import { fuzzyMatch } from "./fuzzy-match.js"

export type InteractiveCommand =
  | { readonly type: "model"; readonly search: string }
  | { readonly type: "login"; readonly provider: string }
  | { readonly type: "logout" }
  | { readonly type: "settings" }
  | { readonly type: "codex_settings" }
  | { readonly type: "compact"; readonly instructions: string }
  | { readonly type: "copy" }
  | { readonly type: "extension_command"; readonly name: string; readonly arguments: string }
  | { readonly type: "reload" }
  | { readonly type: "new_session" }
  | { readonly type: "resume_session" }
  | { readonly type: "subagents" }

export type SlashCompletion =
  | { readonly type: "unavailable" }
  | { readonly type: "edit"; readonly text: string; readonly cursorOffset: number }

export type SlashActivation = SlashCompletion | { readonly type: "intent"; readonly command: InteractiveCommand }

type CommandSession = Pick<AgentSession, "extensionCommandRevision" | "listExtensionCommands" | "listResourceCommands">

interface SlashInput {
  readonly query: string
  readonly commandStart: number
  readonly commandEnd: number
}

export class SlashController {
  readonly #getSession: (() => CommandSession) | undefined
  readonly #getGeneration: (() => number) | undefined
  #catalogGeneration: number | undefined
  #catalogCommandRevision: number | undefined
  #extensionCommandNames: ReadonlySet<string> = new Set()
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
    if (builtin) return { type: "intent", command: builtinIntent(builtin.name, edit.text.slice(edit.cursorOffset)) }
    if (this.#extensionCommandNames.has(selection.command.name)) {
      return {
        type: "intent",
        command: {
          type: "extension_command",
          name: selection.command.name,
          arguments: edit.text.slice(edit.cursorOffset).trim()
        }
      }
    }
    return edit
  }

  parse(text: string): InteractiveCommand | undefined {
    const builtin = builtinSlashCommands.find(candidate => invokes(text, candidate.name))
    if (builtin) {
      const prefix = `/${builtin.name}`
      const args = text === prefix ? "" : text.slice(prefix.length + 1)
      return builtinIntent(builtin.name, args)
    }
    this.#commands()
    if (!text.startsWith("/")) return undefined
    const separator = text.slice(1).search(/\s/)
    const name = separator === -1 ? text.slice(1) : text.slice(1, separator + 1)
    if (!name || !this.#extensionCommandNames.has(name) || !invokes(text, name)) return undefined
    const prefix = `/${name}`
    return { type: "extension_command", name, arguments: text.slice(prefix.length).trim() }
  }

  invalidateCatalog(): void {
    this.#catalogGeneration = undefined
    this.#catalogCommandRevision = undefined
  }

  #commands(): readonly SlashCommand[] {
    const session = this.#getSession?.()
    if (!session) return builtinSlashCommands
    const generation = this.#getGeneration?.()
    const commandRevision = session.extensionCommandRevision
    if (
      generation !== undefined &&
      generation === this.#catalogGeneration &&
      commandRevision === this.#catalogCommandRevision
    ) {
      return this.#catalog
    }

    const byName = new Map<string, SlashCommand>()
    for (const command of builtinSlashCommands) byName.set(command.name, command)
    const extensionCommandNames = new Set<string>()
    for (const command of session.listExtensionCommands()) {
      if (byName.has(command.name)) continue
      byName.set(command.name, command)
      extensionCommandNames.add(command.name)
    }
    for (const command of session.listResourceCommands()) {
      if (!byName.has(command.name)) byName.set(command.name, command)
    }
    this.#catalogGeneration = generation
    this.#catalogCommandRevision = commandRevision
    this.#extensionCommandNames = extensionCommandNames
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
    case "codex-settings":
      return { type: "codex_settings" }
    case "compact":
      return { type: "compact", instructions: args.trim() }
    case "copy":
      return { type: "copy" }
    case "reload":
      return { type: "reload" }
    case "new":
      return { type: "new_session" }
    case "resume":
      return { type: "resume_session" }
    default:
      return assertNever(name)
  }
}

function invokes(text: string, name: string): boolean {
  const prefix = `/${name}`
  return text === prefix || (text.startsWith(prefix) && /\s/.test(text[prefix.length] ?? ""))
}

function assertNever(value: never): never {
  throw new Error(`Unexpected built-in slash command: ${String(value)}`)
}

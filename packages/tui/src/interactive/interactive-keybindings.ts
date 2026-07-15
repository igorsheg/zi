import type { KeyEvent } from "@opentui/core"

export type InteractiveKeyEvent = Pick<KeyEvent, "name" | "ctrl" | "meta" | "shift" | "super" | "hyper">

export const maxKeysPerBinding = 16
const maxKeyIdLength = 128

export type PromptKeyAction =
  | "picker_confirm"
  | "picker_complete"
  | "picker_cancel"
  | "picker_up"
  | "picker_down"
  | "submit"
  | "follow_up"
  | "new_line"
  | "restore_queue"
  | "interrupt"
  | "clear"
  | "exit"
  | "consume"

export type TranscriptKeyAction = "page_up" | "page_down" | "line_up" | "line_down" | "tail"

export interface PromptKeyContext {
  readonly pickerOpen: boolean
  readonly editorEmpty: boolean
  readonly streaming: boolean
}

interface ParsedKey {
  readonly name: string
  readonly ctrl: boolean
  readonly meta: boolean
  readonly shift: boolean
  readonly super: boolean
  readonly hyper: boolean
}

const defaultBindingEntries = [
  ["app.interrupt", ["escape"], "Cancel the active run", "reserved"],
  ["app.clear", ["ctrl+c"], "Clear editor or exit on a second press", "reserved"],
  ["app.exit", ["ctrl+d"], "Exit when the editor is empty", "reserved"],
  ["app.message.followUp", ["alt+return"], "Queue a follow-up message", "reserved"],
  ["app.message.dequeue", ["alt+up"], "Restore queued messages", "overridable"],
  ["tui.input.submit", ["return"], "Submit input", "reserved"],
  ["tui.input.newLine", ["shift+return"], "Insert a newline", "overridable"],
  ["tui.input.tab", ["tab"], "Complete the active input", "overridable"],
  ["tui.input.copy", ["ctrl+c"], "Copy native selection", "reserved"],
  ["tui.select.up", ["up"], "Move selection up", "overridable"],
  ["tui.select.down", ["down"], "Move selection down", "overridable"],
  ["tui.select.confirm", ["return"], "Confirm selection", "reserved"],
  ["tui.select.cancel", ["escape", "ctrl+c"], "Cancel selection", "reserved"],
  ["app.transcript.pageUp", ["pageup"], "Scroll transcript up half a page", "overridable"],
  ["app.transcript.pageDown", ["pagedown"], "Scroll transcript down half a page", "overridable"],
  ["app.transcript.lineUp", ["ctrl+alt+up"], "Scroll transcript up one line", "overridable"],
  ["app.transcript.lineDown", ["ctrl+alt+down"], "Scroll transcript down one line", "overridable"],
  ["app.transcript.tail", ["ctrl+end"], "Jump to the transcript tail", "overridable"]
] as const

export type InteractiveKeybinding = (typeof defaultBindingEntries)[number][0]
export type InteractiveKeybindingOverrides = Partial<Record<InteractiveKeybinding, readonly string[]>>
export type ExtensionKeybindingPolicy = "reserved" | "overridable"

export interface ResolvedInteractiveKeybinding {
  readonly id: InteractiveKeybinding
  readonly keys: readonly string[]
  readonly description: string
  readonly extension: ExtensionKeybindingPolicy
}

export interface InteractiveKeybindingConflict {
  readonly key: string
  readonly keybindings: readonly InteractiveKeybinding[]
}

interface ResolvedBinding {
  readonly keys: readonly string[]
  readonly parsed: readonly ParsedKey[]
  readonly description: string
  readonly extension: ExtensionKeybindingPolicy
}

export class InteractiveKeybindings {
  readonly #bindings = new Map<InteractiveKeybinding, ResolvedBinding>()
  readonly #conflicts: InteractiveKeybindingConflict[] = []

  constructor(overrides: InteractiveKeybindingOverrides = {}) {
    const supported = new Set<string>(defaultBindingEntries.map(([id]) => id))
    for (const id of Object.keys(overrides)) {
      if (!supported.has(id)) throw new Error(`Unknown interactive keybinding: ${id}`)
    }

    const userClaims = new Map<string, InteractiveKeybinding[]>()
    for (const [id, defaultKeys, description, extension] of defaultBindingEntries) {
      const parsed = parseKeys(overrides[id] ?? defaultKeys)
      const keys = parsed.map(formatKey)
      this.#bindings.set(id, { keys, parsed, description, extension })
      if (overrides[id] === undefined) continue
      for (const key of keys) userClaims.set(key, [...(userClaims.get(key) ?? []), id])
    }
    for (const [key, keybindings] of userClaims) {
      if (keybindings.length > 1) this.#conflicts.push({ key, keybindings })
    }
  }

  matches(event: InteractiveKeyEvent, id: InteractiveKeybinding): boolean {
    return this.#bindings.get(id)?.parsed.some(key => matches(event, key)) ?? false
  }

  getKeys(id: InteractiveKeybinding): readonly string[] {
    return [...(this.#bindings.get(id)?.keys ?? [])]
  }

  getHint(id: InteractiveKeybinding): string | undefined {
    const key = this.#bindings.get(id)?.keys[0]
    return key ? formatKeyHint(key) : undefined
  }

  get(id: InteractiveKeybinding): ResolvedInteractiveKeybinding {
    const binding = this.#bindings.get(id)
    if (!binding) throw new Error(`Unknown interactive keybinding: ${id}`)
    return { id, keys: [...binding.keys], description: binding.description, extension: binding.extension }
  }

  list(): readonly ResolvedInteractiveKeybinding[] {
    return defaultBindingEntries.map(([id]) => this.get(id))
  }

  getConflicts(): readonly InteractiveKeybindingConflict[] {
    return this.#conflicts.map(conflict => ({ ...conflict, keybindings: [...conflict.keybindings] }))
  }

  promptAction(event: InteractiveKeyEvent, context: PromptKeyContext): PromptKeyAction | undefined {
    if (context.pickerOpen) {
      if (this.matches(event, "tui.select.confirm")) return "picker_confirm"
      if (this.matches(event, "tui.input.tab")) return "picker_complete"
      if (this.matches(event, "tui.select.cancel")) return "picker_cancel"
      if (this.matches(event, "tui.select.up")) return "picker_up"
      if (this.matches(event, "tui.select.down")) return "picker_down"
      if (isNativeKey(event, "return", "tab", "up", "down")) return "consume"
    }

    if (context.streaming && this.matches(event, "app.interrupt")) return "interrupt"
    if (this.matches(event, "app.clear")) return "clear"
    if (context.editorEmpty && this.matches(event, "app.exit")) return "exit"
    if (this.matches(event, "app.message.followUp")) return "follow_up"
    if (this.matches(event, "app.message.dequeue")) return "restore_queue"
    if (this.matches(event, "tui.input.newLine")) return "new_line"
    if (this.matches(event, "tui.input.submit")) return "submit"
    if (isNativeKey(event, "return")) return "consume"
    return undefined
  }

  transcriptAction(event: InteractiveKeyEvent): TranscriptKeyAction | undefined {
    if (this.matches(event, "app.transcript.pageUp")) return "page_up"
    if (this.matches(event, "app.transcript.pageDown")) return "page_down"
    if (this.matches(event, "app.transcript.lineUp")) return "line_up"
    if (this.matches(event, "app.transcript.lineDown")) return "line_down"
    if (this.matches(event, "app.transcript.tail")) return "tail"
    return undefined
  }
}

function parseKeys(values: readonly string[]): readonly ParsedKey[] {
  if (values.length > maxKeysPerBinding) {
    throw new Error(`Interactive keybindings cannot exceed ${maxKeysPerBinding} keys per action`)
  }
  const keys: ParsedKey[] = []
  const seen = new Set<string>()
  for (const value of values) {
    const parsed = parseKey(value)
    const formatted = formatKey(parsed)
    if (seen.has(formatted)) continue
    seen.add(formatted)
    keys.push(parsed)
  }
  return keys
}

function parseKey(value: string): ParsedKey {
  const normalizedValue = value.trim().toLowerCase()
  if (normalizedValue.length > maxKeyIdLength) {
    throw new Error(`Interactive key IDs cannot exceed ${maxKeyIdLength} characters`)
  }
  const parts = normalizedValue.split("+")
  const name = normalizeName(parts.pop() ?? "")
  if (!name) throw new Error("Key name cannot be empty")

  let ctrl = false
  let meta = false
  let shift = false
  let superKey = false
  let hyper = false
  for (const modifier of parts) {
    switch (modifier) {
      case "ctrl":
      case "control":
        ctrl = true
        break
      case "alt":
      case "meta":
      case "option":
        meta = true
        break
      case "shift":
        shift = true
        break
      case "super":
      case "cmd":
        superKey = true
        break
      case "hyper":
        hyper = true
        break
      default:
        throw new Error(`Unknown key modifier: ${modifier}`)
    }
  }
  return { name, ctrl, meta, shift, super: superKey, hyper }
}

function formatKey(key: ParsedKey): string {
  return [
    ...(key.ctrl ? ["ctrl"] : []),
    ...(key.shift ? ["shift"] : []),
    ...(key.meta ? ["alt"] : []),
    ...(key.super ? ["super"] : []),
    ...(key.hyper ? ["hyper"] : []),
    key.name
  ].join("+")
}

function formatKeyHint(key: string): string {
  return key
    .split("+")
    .map(part => {
      switch (part) {
        case "ctrl":
          return "Ctrl"
        case "shift":
          return "Shift"
        case "alt":
          return "Alt"
        case "super":
          return "Super"
        case "hyper":
          return "Hyper"
        case "return":
          return "Enter"
        case "escape":
          return "Esc"
        case "pageup":
          return "PageUp"
        case "pagedown":
          return "PageDown"
        default:
          return part.length === 1 ? part.toUpperCase() : `${part[0]?.toUpperCase() ?? ""}${part.slice(1)}`
      }
    })
    .join("+")
}

function matches(event: InteractiveKeyEvent, key: ParsedKey): boolean {
  return (
    normalizeName(event.name) === key.name &&
    event.ctrl === key.ctrl &&
    event.meta === key.meta &&
    event.shift === key.shift &&
    Boolean(event.super) === key.super &&
    Boolean(event.hyper) === key.hyper
  )
}

function isNativeKey(event: InteractiveKeyEvent, ...names: readonly string[]): boolean {
  return names.includes(normalizeName(event.name))
}

function normalizeName(name: string): string {
  const lower = name.toLowerCase()
  if (lower === "-") return lower
  const normalized = lower.replaceAll("_", "").replaceAll("-", "")
  if (normalized === "enter") return "return"
  if (normalized === "esc") return "escape"
  return normalized
}

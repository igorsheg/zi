import { BoxRenderable, CliRenderEvents, type CliRenderer, type KeyEvent, TextRenderable } from "@opentui/core"
import type { QueuedInputs } from "@openzi/coding-agent"

import { composerGeometry, createComposer, type Composer } from "../../components/composer.js"
import { createPickerList, type PickerList } from "../../components/picker-list.js"
import type { Theme } from "../../theme.js"
import type { InteractiveCommands } from "../interactive-commands.js"
import type { InteractiveStore } from "../stores/interactive.js"
import { createPromptStore, type PromptStore } from "../stores/prompt.js"
import { ModelSelectorView } from "./model-selector.js"

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

export class PromptView {
  readonly root: BoxRenderable
  readonly input: Composer["input"]

  readonly #renderer: CliRenderer
  readonly #mode: InteractiveStore
  readonly #onExit: () => void
  readonly #theme: Theme
  readonly #store: PromptStore
  readonly #working: BoxRenderable
  readonly #feedback: BoxRenderable
  readonly #feedbackText: TextRenderable
  readonly #queue: BoxRenderable
  readonly #composer: Composer
  readonly #commandPicker: PickerList
  readonly #release: Array<() => void> = []
  #modelSelector: ModelSelectorView | undefined

  constructor(
    renderer: CliRenderer,
    mode: InteractiveStore,
    commands: InteractiveCommands,
    onExit: () => void,
    theme: Theme
  ) {
    this.#renderer = renderer
    this.#mode = mode
    this.#onExit = onExit
    this.#theme = theme
    this.#store = createPromptStore(mode, commands)
    this.root = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })

    this.#working = new BoxRenderable(renderer, { flexDirection: "row", flexShrink: 0 })
    this.#working.add(new TextRenderable(renderer, { fg: theme.text.muted, content: "Working…" }))
    this.#feedback = new BoxRenderable(renderer, { height: 1, paddingLeft: 1, paddingRight: 1, flexShrink: 0 })
    this.#feedbackText = new TextRenderable(renderer, { wrapMode: "none" })
    this.#feedback.add(this.#feedbackText)
    this.#queue = new BoxRenderable(renderer, { flexDirection: "column", flexShrink: 0 })

    const session = mode.getSession()
    const geometry = composerGeometry(renderer.width, renderer.height)
    this.#composer = createComposer(renderer, {
      geometry,
      title: session.sessionManager.header.cwd,
      bottomTitle: modelTitle(session),
      theme,
      onSubmit: () => this.#submit("steer"),
      onContentChange: () => this.#store.draftChanged(this.input.plainText, this.input.cursorOffset)
    })
    this.input = this.#composer.input
    this.#commandPicker = createPickerList(renderer, { rows: [], height: 0, theme })

    this.root.add(this.#working)
    this.root.add(this.#feedback)
    this.root.add(this.#queue)
    this.root.add(this.#composer.root)
    this.root.add(this.#commandPicker.root)

    const update = () => this.#update()
    this.#release.push(this.#store.$state.subscribe(update), mode.$promptRevision.subscribe(update))
    renderer.keyInput.on("keypress", this.#onKeyPress)
    renderer.on(CliRenderEvents.RESIZE, update)
    this.#release.push(() => renderer.keyInput.off("keypress", this.#onKeyPress))
    this.#release.push(() => renderer.off(CliRenderEvents.RESIZE, update))
    this.input.focus()
  }

  focus(): void {
    if (this.#modelSelector) this.#modelSelector.focus()
    else this.input.focus()
  }

  destroy(): void {
    for (const release of this.#release.splice(0)) release()
    this.#modelSelector?.destroy()
    this.#modelSelector = undefined
    this.#store.dispose()
    this.root.destroyRecursively()
  }

  #update = (): void => {
    const session = this.#mode.getSession()
    const prompt = this.#store.$state.get()
    const geometry = composerGeometry(this.#renderer.width, this.#renderer.height)
    const composerVisible = prompt.surface.type === "composer"
    const completion = composerVisible ? prompt.surface.completion : { type: "none" as const }
    const completionVisible = completion.type === "command"
    const feedbackVisible = composerVisible && prompt.feedback.type !== "none"
    const fixedRows =
      geometry.protectedRows + (session.isStreaming ? 1 : 0) + (feedbackVisible ? 1 : 0) + (completionVisible ? 1 : 0)

    if (composerVisible && this.#modelSelector) {
      this.root.remove(this.#modelSelector.root)
      this.#modelSelector.destroy()
      this.#modelSelector = undefined
      this.input.focus()
    } else if (!composerVisible && !this.#modelSelector) {
      this.#modelSelector = new ModelSelectorView(
        this.#renderer,
        this.#store,
        this.#theme,
        session.model,
        prompt.surface.initialSearch
      )
      this.root.add(this.#modelSelector.root)
    }

    this.#working.visible = composerVisible && session.isStreaming
    this.#feedback.visible = feedbackVisible
    this.#feedbackText.content = feedbackVisible
      ? truncateToCells(prompt.feedback.message, Math.max(0, this.#renderer.width - 2))
      : ""
    this.#feedbackText.fg = prompt.feedback.type === "error" ? this.#theme.text.error : this.#theme.text.muted
    if (composerVisible) this.#renderQueue(session.queuedInputs, Math.max(0, this.#renderer.height - fixedRows))
    else this.#queue.visible = false
    this.#composer.root.visible = composerVisible
    this.#commandPicker.update({
      rows:
        completion.type === "command"
          ? [
              {
                id: completion.command.name,
                label: `/${completion.command.name}`,
                ...(completion.command.argumentHint ? { detail: completion.command.argumentHint } : {}),
                metadata: completion.command.description
              }
            ]
          : [],
      ...(completion.type === "command" ? { selectedId: completion.command.name } : {}),
      height: completionVisible ? 1 : 0,
      theme: this.#theme
    })
    this.#composer.update(geometry, session.sessionManager.header.cwd, modelTitle(session))
  }

  #renderQueue(queue: QueuedInputs, maxRows: number): void {
    clear(this.#queue)
    if ((queue.steering.length === 0 && queue.followUp.length === 0) || maxRows === 0) {
      this.#queue.visible = false
      return
    }
    this.#queue.visible = true
    const width = Math.max(0, this.#renderer.width - 2)
    const rows = [
      ...queue.steering.map(entry => ({ id: entry.id, text: `Steering: ${firstLine(entry.text)}` })),
      ...queue.followUp.map(entry => ({ id: entry.id, text: `Follow-up: ${firstLine(entry.text)}` }))
    ]
    const overflow = rows.length + 1 - maxRows
    const visibleRows = overflow > 0 ? rows.slice(0, Math.max(0, maxRows - 2)) : rows
    const footerRows =
      maxRows === 1
        ? [`${rows.length} queued · Alt+Up to edit all`]
        : [
            ...(overflow > 0 ? [`… ${rows.length - visibleRows.length} more queued`] : []),
            "↳ Alt+Up to edit all queued messages"
          ]

    for (const row of visibleRows) this.#queue.add(this.#queueRow(row.id, row.text, width))
    for (const text of footerRows) this.#queue.add(this.#queueRow(text, text, width))
  }

  #queueRow(id: string | number, text: string, width: number): BoxRenderable {
    const row = new BoxRenderable(this.#renderer, {
      id: `queued-${id}`,
      height: 1,
      paddingLeft: 1,
      paddingRight: 1,
      flexShrink: 0
    })
    row.add(
      new TextRenderable(this.#renderer, {
        fg: this.#theme.text.dim,
        wrapMode: "none",
        content: truncateToCells(text, width)
      })
    )
    return row
  }

  #submit(delivery: "steer" | "followUp"): void {
    if (this.#store.submit(this.input.plainText, delivery)) this.input.setText("")
  }

  #restore(abort: boolean): void {
    const text = abort
      ? this.#store.abortAndRestoreQueuedInputs(this.input.plainText)
      : this.#store.restoreQueuedInputs(this.input.plainText)
    if (text !== this.input.plainText) this.input.setText(text)
  }

  #onKeyPress = (key: KeyEvent): void => {
    const surface = this.#store.$state.get().surface
    if (surface.type !== "composer") return

    const bare = !key.shift && !key.ctrl && !key.meta && !key.super && !key.hyper
    if (surface.completion.type === "command") {
      if (bare && key.name === "return") {
        key.preventDefault()
        key.stopPropagation()
        const completion = this.#store.completeSlashCommand()
        if (completion) {
          this.input.setText(completion)
          this.#submit("steer")
        }
        return
      }
      if (bare && key.name === "tab") {
        key.preventDefault()
        key.stopPropagation()
        const completion = this.#store.completeSlashCommand()
        if (completion) this.input.setText(completion)
        return
      }
      if (bare && key.name === "escape") {
        key.preventDefault()
        key.stopPropagation()
        this.#store.dismissSlashCommand()
        return
      }
      if (bare && (key.name === "up" || key.name === "down")) {
        key.preventDefault()
        key.stopPropagation()
        return
      }
    }

    if (key.name === "return") {
      const withoutExtraModifiers = !key.shift && !key.ctrl && !key.super && !key.hyper
      if (withoutExtraModifiers) {
        key.preventDefault()
        key.stopPropagation()
        this.#submit(key.meta ? "followUp" : "steer")
        return
      }
      const newline = key.shift && !key.ctrl && !key.meta && !key.super && !key.hyper
      if (!newline) {
        key.preventDefault()
        key.stopPropagation()
      }
      return
    }

    if (key.name === "up" && key.meta && !key.shift && !key.ctrl && !key.super && !key.hyper) {
      key.preventDefault()
      key.stopPropagation()
      this.#restore(false)
      return
    }

    const session = this.#mode.getSession()
    if (
      key.name === "escape" &&
      !key.shift &&
      !key.ctrl &&
      !key.meta &&
      !key.super &&
      !key.hyper &&
      session.isStreaming
    ) {
      key.preventDefault()
      key.stopPropagation()
      this.#restore(true)
      return
    }

    if (!key.ctrl) return
    if (key.name === "c") {
      key.preventDefault()
      key.stopPropagation()
      const selectedText = this.#renderer.getSelection()?.getSelectedText()
      if (selectedText) {
        let copied = false
        try {
          copied = this.#renderer.copyToClipboardOSC52(selectedText)
        } catch {
          return
        }
        if (copied) this.#renderer.clearSelection()
        return
      }
      this.input.setText("")
      this.#store.clear()
    } else if (key.name === "d" && this.input.plainText.length === 0) {
      key.preventDefault()
      key.stopPropagation()
      this.#onExit()
    }
  }
}

function modelTitle(session: ReturnType<InteractiveStore["getSession"]>): string {
  return session.thinkingLevel === "off" ? session.model.id : `${session.model.id} (${session.thinkingLevel})`
}

function clear(root: BoxRenderable): void {
  for (const child of root.getChildren()) {
    root.remove(child)
    child.destroyRecursively()
  }
}

function firstLine(text: string): string {
  return text.split(/\r?\n/, 1)[0] ?? ""
}

function truncateToCells(text: string, maxWidth: number): string {
  if (maxWidth <= 0) return ""
  if (textWidth(text) <= maxWidth) return text
  if (maxWidth <= 3) return ".".repeat(maxWidth)

  let result = ""
  let width = 0
  const target = maxWidth - 3
  for (const { segment } of graphemes.segment(text)) {
    const segmentWidth = graphemeWidth(segment)
    if (width + segmentWidth > target) break
    result += segment
    width += segmentWidth
  }
  return `${result}...`
}

function textWidth(text: string): number {
  let width = 0
  for (const { segment } of graphemes.segment(text)) width += graphemeWidth(segment)
  return width
}

function graphemeWidth(segment: string): number {
  if (/^[\p{Control}\p{Mark}\p{Default_Ignorable_Code_Point}]+$/u.test(segment)) return 0
  if (/\p{Extended_Pictographic}/u.test(segment) || /^\p{Regional_Indicator}{2}$/u.test(segment)) return 2
  const codePoint = segment.codePointAt(0) ?? 0
  return isWideCodePoint(codePoint) ? 2 : 1
}

function isWideCodePoint(codePoint: number): boolean {
  return (
    codePoint >= 0x1100 &&
    (codePoint <= 0x115f ||
      codePoint === 0x2329 ||
      codePoint === 0x232a ||
      (codePoint >= 0x2e80 && codePoint <= 0xa4cf && codePoint !== 0x303f) ||
      (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
      (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
      (codePoint >= 0xfe10 && codePoint <= 0xfe19) ||
      (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
      (codePoint >= 0xff00 && codePoint <= 0xff60) ||
      (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
      (codePoint >= 0x20000 && codePoint <= 0x3fffd))
  )
}

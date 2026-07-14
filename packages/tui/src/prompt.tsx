import type { TextareaRenderable } from "@opentui/core"
import { useKeyboard, useTerminalDimensions } from "@opentui/react"
import type { ImageContent, QueuedInputs } from "@openzi/coding-agent"
import { useRef, useState } from "react"

import { useSession } from "./session-context.js"
import { useTheme } from "./theme.js"

type PromptFeedback = { type: "none" } | { type: "status"; message: string } | { type: "error"; message: string }

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

export function Prompt({ onExit }: { onExit: () => void }) {
  const session = useSession()
  const input = useRef<TextareaRenderable>(null)
  const [feedback, setFeedback] = useState<PromptFeedback>({ type: "none" })
  const [draftImages, setDraftImages] = useState<readonly ImageContent[]>([])
  const theme = useTheme()
  const { width, height } = useTerminalDimensions()
  const bordered = height >= 6 && width >= 4
  const maxHeight = Math.max(1, Math.min(5, Math.floor(height * 0.3)))
  const fixedRows = maxHeight + (bordered ? 2 : 0) + (session.isStreaming ? 1 : 0) + (feedback.type === "none" ? 0 : 1)
  const maxQueueRows = Math.max(0, height - fixedRows)
  const queued = session.queuedInputs

  const showError = (cause: unknown) => {
    setFeedback({ type: "error", message: cause instanceof Error ? cause.message : String(cause) })
  }

  const submit = (delivery: "steer" | "followUp") => {
    const editor = input.current
    if (!editor) return

    const text = editor.plainText.trim()
    if (!text) return

    try {
      const settled = session.prompt(text, {
        ...(draftImages.length === 0 ? {} : { images: [...draftImages] }),
        ...(session.isStreaming ? { streamingBehavior: delivery } : {})
      })
      editor.setText("")
      setDraftImages([])
      setFeedback({ type: "none" })
      void settled.catch(showError)
    } catch (cause) {
      showError(cause)
    }
  }

  const restore = (queue: QueuedInputs, status: boolean) => {
    const editor = input.current
    if (!editor) return
    const entries = [...queue.steering, ...queue.followUp]
    const texts = entries.map(entry => entry.text)
    const images = entries.flatMap(entry => entry.images)
    if (texts.length > 0) editor.setText([...texts, editor.plainText].filter(text => text.length > 0).join("\n\n"))
    if (images.length > 0) setDraftImages(current => [...images, ...current])
    if (status) {
      setFeedback({
        type: "status",
        message:
          texts.length === 0
            ? "No queued messages to restore"
            : `Restored ${texts.length} queued message${texts.length === 1 ? "" : "s"} to editor${
                images.length === 0 ? "" : ` with ${images.length} image${images.length === 1 ? "" : "s"}`
              }`
      })
    }
  }

  useKeyboard(key => {
    const editor = input.current
    if (!editor) return

    if (key.name === "return") {
      const withoutExtraModifiers = !key.shift && !key.ctrl && !key.super && !key.hyper
      if (withoutExtraModifiers) {
        key.preventDefault()
        key.stopPropagation()
        submit(key.meta ? "followUp" : "steer")
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
      try {
        restore(session.takeQueuedInputs(), true)
      } catch (cause) {
        showError(cause)
      }
      return
    }

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
      try {
        const aborted = session.takeQueuedInputsAndAbort()
        restore(aborted, false)
        setFeedback({ type: "none" })
        void aborted.settled.catch(showError)
      } catch (cause) {
        showError(cause)
      }
      return
    }

    if (!key.ctrl) return
    if (key.name === "c") {
      key.preventDefault()
      key.stopPropagation()
      editor.setText("")
      setDraftImages([])
      setFeedback({ type: "none" })
    } else if (key.name === "d" && editor.plainText.length === 0) {
      key.preventDefault()
      key.stopPropagation()
      onExit()
    }
  })

  return (
    <box flexDirection="column" flexShrink={0}>
      {session.isStreaming ? <WorkingStatus /> : null}
      {feedback.type !== "none" ? (
        <box height={1} paddingLeft={1} paddingRight={1}>
          <text fg={feedback.type === "error" ? theme.text.error : theme.text.muted} wrapMode="none">
            {truncateToCells(feedback.message, Math.max(0, width - 2))}
          </text>
        </box>
      ) : null}
      <QueuedInputRows queue={queued} width={width} maxRows={maxQueueRows} />
      <box
        border={bordered}
        borderStyle="rounded"
        borderColor={theme.border.default}
        backgroundColor={theme.surface.composer}
        title={session.sessionManager.header.cwd}
        titleColor={theme.text.muted}
        bottomTitle={
          session.thinkingLevel === "off" ? session.model.id : `${session.model.id} (${session.thinkingLevel})`
        }
        bottomTitleAlignment="right">
        <textarea
          id="prompt-input"
          ref={input}
          focused
          minHeight={1}
          maxHeight={maxHeight}
          wrapMode="word"
          textColor={theme.text.primary}
          focusedTextColor={theme.text.primary}
          cursorColor={theme.text.primary}
          backgroundColor={theme.surface.composer}
          focusedBackgroundColor={theme.surface.composer}
          keyBindings={[
            { name: "return", action: "submit" },
            { name: "return", shift: true, action: "newline" }
          ]}
          onSubmit={() => submit("steer")}
        />
      </box>
    </box>
  )
}

function QueuedInputRows({ queue, width, maxRows }: { queue: QueuedInputs; width: number; maxRows: number }) {
  if ((queue.steering.length === 0 && queue.followUp.length === 0) || maxRows === 0) return null
  const availableWidth = Math.max(0, width - 2)
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

  return (
    <box flexDirection="column" flexShrink={0}>
      {visibleRows.map(row => (
        <QueueRow key={row.id} text={row.text} width={availableWidth} />
      ))}
      {footerRows.map(text => (
        <QueueRow key={text} text={text} width={availableWidth} />
      ))}
    </box>
  )
}

function QueueRow({ text, width }: { text: string; width: number }) {
  const theme = useTheme()
  return (
    <box height={1} paddingLeft={1} paddingRight={1}>
      <text fg={theme.text.dim} wrapMode="none">
        {truncateToCells(text, width)}
      </text>
    </box>
  )
}

function WorkingStatus() {
  const theme = useTheme()
  return (
    <box flexDirection="row" flexShrink={0}>
      <text fg={theme.text.muted}>Working…</text>
    </box>
  )
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

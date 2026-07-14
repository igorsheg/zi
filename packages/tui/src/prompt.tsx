import type { TextareaRenderable } from "@opentui/core"
import { useKeyboard, useTerminalDimensions } from "@opentui/react"
import { useRef, useState } from "react"

import { useSession } from "./session-context.js"
import { useTheme } from "./theme.js"

export function Prompt({ onExit }: { onExit: () => void }) {
  const session = useSession()
  const input = useRef<TextareaRenderable>(null)
  const [error, setError] = useState<string>()
  const theme = useTheme()
  const { width, height } = useTerminalDimensions()
  const bordered = height >= 6 && width >= 4
  const maxHeight = Math.max(1, Math.min(5, Math.floor(height * 0.3)))

  useKeyboard(key => {
    if (!key.ctrl) return
    const editor = input.current
    if (!editor) return

    if (key.name === "c") {
      key.preventDefault()
      key.stopPropagation()
      editor.setText("")
      setError(undefined)
    } else if (key.name === "d" && editor.plainText.length === 0) {
      key.preventDefault()
      key.stopPropagation()
      onExit()
    }
  })

  const submit = () => {
    const editor = input.current
    if (!editor) return

    const text = editor.plainText.trim()
    if (!text) return

    setError(undefined)
    editor.setText("")
    void session.prompt(text, session.isStreaming ? { streamingBehavior: "steer" } : {}).catch(cause => {
      setError(cause instanceof Error ? cause.message : String(cause))
    })
  }

  return (
    <box flexDirection="column" flexShrink={0}>
      {session.isStreaming ? <WorkingStatus /> : null}
      {error ? (
        <box paddingLeft={1} paddingRight={1}>
          <text fg={theme.text.error}>{error}</text>
        </box>
      ) : null}
      <box
        border={bordered}
        borderStyle="rounded"
        borderColor={theme.border.default}
        backgroundColor={theme.surface.composer}
        title={session.sessionManager.header.cwd}
        titleColor={theme.text.muted}
        bottomTitle={`${session.model.provider}/${session.model.id} · ${session.thinkingLevel}`}
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
          placeholderColor={theme.text.muted}
          cursorColor={theme.text.primary}
          backgroundColor={theme.surface.composer}
          focusedBackgroundColor={theme.surface.composer}
          placeholder="Ask anything"
          keyBindings={[
            { name: "return", action: "submit" },
            { name: "return", shift: true, action: "newline" }
          ]}
          onSubmit={submit}
        />
      </box>
    </box>
  )
}

function WorkingStatus() {
  const theme = useTheme()
  return (
    <box paddingLeft={1} paddingRight={1} flexDirection="row" gap={1} flexShrink={0}>
      <text fg={theme.text.accent}>Working…</text>
      <text fg={theme.text.muted}>esc to interrupt</text>
    </box>
  )
}

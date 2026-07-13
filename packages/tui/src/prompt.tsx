import type { TextareaRenderable } from "@opentui/core"
import { useState } from "react"
import { useSession } from "./session-context.js"

export function Prompt() {
  const session = useSession()
  const [input, setInput] = useState<TextareaRenderable>()
  const [error, setError] = useState<string>()

  const submit = () => {
    if (!input) return
    const text = input.plainText.trim()
    if (!text) return

    setError(undefined)
    input.setText("")
    void session.prompt(text, session.isStreaming ? { streamingBehavior: "steer" } : {}).catch((cause) => {
      setError(cause instanceof Error ? cause.message : String(cause))
    })
  }

  return (
    <box flexDirection="column" flexShrink={0}>
      {session.isStreaming ? (
        <box paddingLeft={1}>
          <text fg="#7D8590">working · esc to interrupt</text>
        </box>
      ) : null}
      {error ? (
        <box paddingLeft={1}>
          <text fg="#F85149">{error}</text>
        </box>
      ) : null}
      <box
        border
        borderStyle="rounded"
        borderColor="#6E7681"
        backgroundColor="#090E13"
        title={session.sessionManager.header.cwd}
        bottomTitle={`${session.model.provider}/${session.model.id} · ${session.thinkingLevel}`}
      >
        <textarea
          ref={(value) => setInput(value ?? undefined)}
          focused
          minHeight={1}
          maxHeight={8}
          wrapMode="word"
          backgroundColor="#090E13"
          focusedBackgroundColor="#090E13"
          placeholder="Ask anything"
          keyBindings={[
            { name: "return", action: "submit" },
            { name: "return", shift: true, action: "newline" },
          ]}
          onSubmit={submit}
        />
      </box>
    </box>
  )
}

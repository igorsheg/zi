import { Prompt } from "./prompt.js"
import { Transcript } from "./transcript.js"

export function SessionScreen({ onExit }: { onExit: () => void }) {
  return (
    <box flexDirection="column" flexGrow={1} minHeight={0}>
      <Transcript />
      <Prompt onExit={onExit} />
    </box>
  )
}

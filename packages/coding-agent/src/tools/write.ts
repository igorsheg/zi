import { mkdir, writeFile } from "node:fs/promises"
import { dirname } from "node:path"
import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { withFileMutation } from "./mutation-queue.js"
import { resolveToolPath } from "./path.js"

const parameters = Type.Object({
  path: Type.String({ description: "Path to the file to write (relative or absolute)" }),
  content: Type.String({ description: "Content to write to the file" }),
})

export function createWriteTool(cwd: string): AgentTool<typeof parameters> {
  return {
    name: "write",
    label: "write",
    description: "Write content to a file. Creates parent directories and overwrites an existing file.",
    parameters,
    async execute(_id, input, signal) {
      const path = resolveToolPath(input.path, cwd)
      return withFileMutation(path, async () => {
        throwIfAborted(signal)
        await mkdir(dirname(path), { recursive: true })
        throwIfAborted(signal)
        await writeFile(path, input.content, "utf8")
        throwIfAborted(signal)
        return {
          content: [{ type: "text", text: `Successfully wrote ${Buffer.byteLength(input.content)} bytes to ${input.path}` }],
          details: undefined,
        }
      })
    },
  }
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new Error("Operation aborted")
}

import { readFile } from "node:fs/promises"
import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { resolveToolPath } from "./path.js"
import { DEFAULT_MAX_BYTES, truncateHead, type TruncationResult } from "./truncate.js"

const parameters = Type.Object({
  path: Type.String({ description: "Path to the file to read (relative or absolute)" }),
  offset: Type.Optional(Type.Integer({ minimum: 1, description: "Line number to start reading from (1-indexed)" })),
  limit: Type.Optional(Type.Integer({ minimum: 1, description: "Maximum number of lines to read" })),
})

export interface ReadToolDetails {
  truncation?: TruncationResult
}

export function createReadTool(cwd: string): AgentTool<typeof parameters, ReadToolDetails | undefined> {
  return {
    name: "read",
    label: "read",
    description:
      "Read text file contents. Output is truncated to 2,000 lines or 50 KiB. Use offset and limit to continue through large files.",
    parameters,
    async execute(_id, input, signal) {
      throwIfAborted(signal)
      const path = resolveToolPath(input.path, cwd)
      const content = await readFile(path, "utf8")
      throwIfAborted(signal)

      const lines = content.split("\n")
      const start = (input.offset ?? 1) - 1
      if (start >= lines.length) throw new Error(`Offset ${input.offset} is beyond end of file (${lines.length} lines total)`)
      const selected = lines.slice(start, input.limit === undefined ? undefined : start + input.limit).join("\n")
      const truncation = truncateHead(selected)

      if (truncation.firstLineExceedsLimit) {
        const line = start + 1
        return {
          content: [
            {
              type: "text",
              text: `[Line ${line} exceeds the ${DEFAULT_MAX_BYTES} byte limit. Use bash to inspect a bounded byte range.]`,
            },
          ],
          details: { truncation },
        }
      }

      let text = truncation.content
      if (truncation.truncated) {
        const first = start + 1
        const last = first + truncation.outputLines - 1
        text += `\n\n[Showing lines ${first}-${last} of ${lines.length}. Use offset=${last + 1} to continue.]`
      }
      return { content: [{ type: "text", text }], details: truncation.truncated ? { truncation } : undefined }
    },
  }
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new Error("Operation aborted")
}

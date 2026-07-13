import { access, readFile, writeFile } from "node:fs/promises"
import type { AgentTool } from "@earendil-works/pi-agent-core"
import { Type } from "@earendil-works/pi-ai"
import { withFileMutation } from "./mutation-queue.js"
import { resolveToolPath } from "./path.js"

const replacement = Type.Object({
  oldText: Type.String({ description: "Exact, unique text to replace in the original file" }),
  newText: Type.String({ description: "Replacement text" }),
})

const parameters = Type.Object({
  path: Type.String({ description: "Path to the file to edit (relative or absolute)" }),
  edits: Type.Array(replacement, { minItems: 1, description: "Non-overlapping replacements" }),
})

export interface EditToolDetails {
  replacements: number
}

export function createEditTool(cwd: string): AgentTool<typeof parameters, EditToolDetails> {
  return {
    name: "edit",
    label: "edit",
    description:
      "Edit one file with exact text replacements. Every oldText must be unique in the original file and replacements must not overlap.",
    parameters,
    prepareArguments: prepareArguments,
    async execute(_id, input, signal) {
      const path = resolveToolPath(input.path, cwd)
      return withFileMutation(path, async () => {
        throwIfAborted(signal)
        await access(path)
        const raw = await readFile(path, "utf8")
        throwIfAborted(signal)

        const bom = raw.startsWith("\uFEFF") ? "\uFEFF" : ""
        const source = normalize(raw.slice(bom.length))
        const edits = input.edits.map((edit) => ({ oldText: normalize(edit.oldText), newText: normalize(edit.newText) }))
        const matches = edits.map((edit, index) => match(source, edit.oldText, input.path, index, edits.length))
        const ordered = matches.map((item, index) => ({ ...item, newText: edits[index]!.newText })).sort((a, b) => a.start - b.start)

        for (let index = 1; index < ordered.length; index++) {
          const previous = ordered[index - 1]!
          const current = ordered[index]!
          if (previous.end > current.start) throw new Error(`Overlapping edits in ${input.path}`)
        }

        let output = source
        for (const edit of ordered.toReversed()) {
          output = output.slice(0, edit.start) + edit.newText + output.slice(edit.end)
        }
        if (output === source) throw new Error(`Edit produced no change in ${input.path}`)

        const lineEnding = raw.includes("\r\n") ? "\r\n" : "\n"
        await writeFile(path, bom + (lineEnding === "\r\n" ? output.replace(/\n/g, "\r\n") : output), "utf8")
        throwIfAborted(signal)
        return {
          content: [{ type: "text", text: `Successfully replaced ${edits.length} block(s) in ${input.path}` }],
          details: { replacements: edits.length },
        }
      })
    },
  }
}

function prepareArguments(input: unknown) {
  if (!input || typeof input !== "object") return input as { path: string; edits: { oldText: string; newText: string }[] }
  const args = input as Record<string, unknown>
  if (Array.isArray(args.edits)) return args as { path: string; edits: { oldText: string; newText: string }[] }
  if (typeof args.oldText === "string" && typeof args.newText === "string") {
    return { path: args.path, edits: [{ oldText: args.oldText, newText: args.newText }] } as {
      path: string
      edits: { oldText: string; newText: string }[]
    }
  }
  return args as { path: string; edits: { oldText: string; newText: string }[] }
}

function match(source: string, text: string, path: string, index: number, count: number) {
  if (!text) throw new Error(`edits[${index}].oldText must not be empty`)
  const start = source.indexOf(text)
  const label = count === 1 ? "oldText" : `edits[${index}].oldText`
  if (start < 0) throw new Error(`Could not find ${label} in ${path}`)
  if (source.indexOf(text, start + text.length) >= 0) throw new Error(`${label} is not unique in ${path}`)
  return { start, end: start + text.length }
}

function normalize(text: string): string {
  return text.replace(/\r\n?/g, "\n")
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new Error("Operation aborted")
}

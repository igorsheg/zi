import { isEditToolDetails, type EditToolDetails } from "../edit.js"
import { truncateHead } from "../truncate.js"
import type { ToolNotice, ToolPresentation, ToolPresentationSource } from "./types.js"
import {
  boundHead,
  boundInline,
  isPartialSource,
  isTerminalSource,
  matchesToolOutcome,
  normalizeToolText,
  recordValue,
  resultDetails,
  stringValue
} from "./values.js"

const maxPresentedChanges = 8

export function projectEdit(source: ToolPresentationSource): ToolPresentation | undefined {
  const args = recordValue(source.args)
  const path = stringValue(args?.path)
  const edits = editValues(args?.edits)
  if (!isPartialSource(source) && (!path || !edits)) return undefined

  let details: EditToolDetails | undefined
  if ("result" in source && source.result !== undefined) {
    const value = resultDetails(source.result)
    if (!isEditToolDetails(value) || !matchesToolOutcome(source, value.outcome)) return undefined
    details = value
  } else if (isTerminalSource(source)) {
    return undefined
  }

  const notices: ToolNotice[] = []
  if (edits && edits.length > maxPresentedChanges) {
    notices.push({
      type: "message",
      tone: "warning",
      text: `${edits.length - maxPresentedChanges} replacements omitted`
    })
  }
  if (details?.outcome === "success" && details.diffTruncated) {
    notices.push({ type: "message", tone: "warning", text: "Diff truncated at 2,000 lines or 50 KiB" })
  }
  if (details?.outcome === "error") notices.push({ type: "message", tone: "error", text: boundInline(details.error) })

  const headerDetails: string[] = []
  if (details) headerDetails.push(`${details.replacements} replacement${details.replacements === 1 ? "" : "s"}`)
  if (details?.outcome === "success" && details.firstChangedLine !== undefined) {
    headerDetails.push(`from line ${details.firstChangedLine}`)
  }

  const argumentBody = edits ? replacementBody(edits.slice(0, maxPresentedChanges)) : undefined
  const body =
    details?.outcome === "success"
      ? ({ type: "diff", text: boundHead(details.diff), path: boundInline(path ?? "") } as const)
      : argumentBody
        ? ({ type: "text", text: argumentBody, tone: "normal" } as const)
        : undefined

  return {
    header: {
      label: "Edit",
      subject: { type: "path", path: boundInline(path ?? "…") },
      details: headerDetails.map(detail => boundInline(detail))
    },
    ...(body ? { body } : {}),
    notices,
    preview: { type: "head", rows: 12 }
  }
}

function editValues(value: unknown): readonly { readonly oldText: string; readonly newText: string }[] | undefined {
  if (!Array.isArray(value)) return undefined
  const edits: { oldText: string; newText: string }[] = []
  for (const candidate of value) {
    const edit = recordValue(candidate)
    const oldText = stringValue(edit?.oldText)
    const newText = stringValue(edit?.newText)
    if (oldText === undefined || newText === undefined) return undefined
    edits.push({ oldText, newText })
  }
  return edits.length > 0 ? edits : undefined
}

function replacementBody(edits: readonly { readonly oldText: string; readonly newText: string }[]): string {
  const sections: string[] = []
  for (const edit of edits) {
    sections.push(`- ${boundedReplacement(edit.oldText)}\n+ ${boundedReplacement(edit.newText)}`)
  }
  return truncateHead(sections.join("\n\n")).content
}

function boundedReplacement(value: string): string {
  const scalars = Array.from(normalizeToolText(value))
  return scalars.length <= 8_192 ? scalars.join("") : `${scalars.slice(0, 8_191).join("")}…`
}

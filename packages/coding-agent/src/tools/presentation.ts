import { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES, truncateHead, truncateTail, type TruncationResult } from "./truncate.js"

export type ToolDisplay = CommandToolDisplay | ReadToolDisplay | WriteToolDisplay | EditToolDisplay | GenericToolDisplay

export interface ToolDisplayInput {
  readonly name: string
  readonly args: unknown
  readonly result?: unknown
  readonly isError: boolean
}

export interface ToolDisplayNotice {
  readonly tone: "muted" | "warning" | "error"
  readonly text: string
}

export interface CommandToolDisplay {
  readonly type: "command"
  readonly command: string
  readonly timeout?: number
  readonly output: string
  readonly notices: readonly ToolDisplayNotice[]
}

export interface ReadToolDisplay {
  readonly type: "read"
  readonly path: string
  readonly offset?: number
  readonly limit?: number
  readonly output: string
  readonly notices: readonly ToolDisplayNotice[]
}

export interface WriteToolDisplay {
  readonly type: "write"
  readonly path: string
  readonly content: string
  readonly contentLines: number
  readonly contentShownLines: number
  readonly contentBytes: number
  readonly contentTruncated: boolean
  readonly error?: string
}

export interface EditToolChangeDisplay {
  readonly oldText: string
  readonly newText: string
}

export interface EditToolDisplay {
  readonly type: "edit"
  readonly path: string
  readonly changes: readonly EditToolChangeDisplay[]
  readonly changesTruncated: boolean
  readonly diff?: string
  readonly diffTruncated: boolean
  readonly error?: string
}

export interface GenericToolDisplay {
  readonly type: "generic"
  readonly name: string
  readonly args: string
  readonly output: string
  readonly notices: readonly ToolDisplayNotice[]
}

const maxPathLength = 4_096
const maxTitleLength = 8_192
const maxNoticeLength = 4_096
const maxNotices = 8
const maxNoticeScanLength = maxNoticeLength * maxNotices * 2
const maxEditChanges = 8

export function projectToolDisplay({ name, args, result, isError }: ToolDisplayInput): ToolDisplay {
  const record = asRecord(args)
  switch (name) {
    case "bash":
      return projectCommand(record, result, isError)
    case "read":
      return projectRead(record, result, isError)
    case "write":
      return projectWrite(record, result, isError)
    case "edit":
      return projectEdit(record, result, isError)
    default:
      return projectGeneric(name, args, result, isError)
  }
}

function projectCommand(
  args: Record<string, unknown> | undefined,
  result: unknown,
  isError: boolean
): CommandToolDisplay {
  const details = resultDetails(result)
  const truncation = truncationDetails(details?.truncation)
  const fullOutputPath = boundedInline(stringValue(details?.fullOutputPath) ?? "", maxPathLength)
  const extracted = extractTrailingNotices(resultText(result))
  const notices: ToolDisplayNotice[] = []
  if (fullOutputPath) appendNotice(notices, "warning", `Full output: ${fullOutputPath}`)
  if (truncation?.truncated) appendNotice(notices, "warning", formatTruncation(truncation, "tail"))
  if (details?.fullOutputTruncated === true) {
    appendNotice(notices, "warning", "Full output file reached its retention limit")
  }
  for (const notice of extracted.notices) {
    if (!noticeCovered(notice, notices)) appendNotice(notices, isError ? "error" : "warning", notice)
  }
  const timeout = numberValue(args?.timeout)
  return {
    type: "command",
    command: boundedInline(stringValue(args?.command) ?? "", maxTitleLength),
    ...(timeout === undefined ? {} : { timeout }),
    output: boundedTail(extracted.text),
    notices
  }
}

function projectRead(args: Record<string, unknown> | undefined, result: unknown, isError: boolean): ReadToolDisplay {
  const details = resultDetails(result)
  const truncation = truncationDetails(details?.truncation)
  const extracted = extractTrailingNotices(resultText(result))
  const notices: ToolDisplayNotice[] = []
  if (truncation?.truncated && !extracted.notices.some(notice => notice.toLowerCase().includes("showing lines"))) {
    appendNotice(notices, "warning", formatTruncation(truncation, "head"))
  }
  for (const notice of extracted.notices) appendNotice(notices, isError ? "error" : "warning", notice)
  const offset = integerValue(args?.offset)
  const limit = integerValue(args?.limit)
  return {
    type: "read",
    path: boundedInline(stringValue(args?.path) ?? "", maxPathLength),
    ...(offset === undefined ? {} : { offset }),
    ...(limit === undefined ? {} : { limit }),
    output: boundedHead(extracted.text),
    notices
  }
}

function projectWrite(args: Record<string, unknown> | undefined, result: unknown, isError: boolean): WriteToolDisplay {
  const content = stringValue(args?.content) ?? ""
  const preview = truncateHead(content)
  const output = resultText(result)
  return {
    type: "write",
    path: boundedInline(stringValue(args?.path) ?? "", maxPathLength),
    content: preview.content,
    contentLines: preview.totalLines,
    contentShownLines: preview.outputLines,
    contentBytes: preview.totalBytes,
    contentTruncated: preview.truncated,
    ...(isError && output ? { error: boundedHead(output) } : {})
  }
}

function projectEdit(args: Record<string, unknown> | undefined, result: unknown, isError: boolean): EditToolDisplay {
  const edits = editValues(args)
  const changes: EditToolChangeDisplay[] = []
  for (const value of edits.slice(0, maxEditChanges)) {
    const edit = asRecord(value)
    if (!edit) continue
    changes.push({
      oldText: boundedHead(stringValue(edit.oldText) ?? ""),
      newText: boundedHead(stringValue(edit.newText) ?? "")
    })
  }
  const details = resultDetails(result)
  const diff = stringValue(details?.diff)
  const output = resultText(result)
  return {
    type: "edit",
    path: boundedInline(stringValue(args?.path) ?? "", maxPathLength),
    changes,
    changesTruncated: edits.length > maxEditChanges,
    ...(diff ? { diff: boundedHead(diff) } : {}),
    diffTruncated: details?.diffTruncated === true,
    ...(isError && output ? { error: boundedHead(output) } : {})
  }
}

function projectGeneric(name: string, args: unknown, result: unknown, isError: boolean): GenericToolDisplay {
  const extracted = extractTrailingNotices(resultText(result))
  return {
    type: "generic",
    name,
    args: boundedHead(json(args)),
    output: boundedHead(extracted.text),
    notices: boundedNotices(extracted.notices, isError ? "error" : "warning")
  }
}

function formatTruncation(truncation: TruncationResult, direction: "head" | "tail"): string {
  if (truncation.firstLineExceedsLimit) return `First line exceeds the ${formatBytes(DEFAULT_MAX_BYTES)} limit`
  if (truncation.lastLinePartial) {
    return `Showing the last ${formatBytes(truncation.outputBytes)} of an oversized line`
  }
  if (truncation.truncatedBy === "lines") {
    return direction === "tail"
      ? `Truncated: showing the last ${truncation.outputLines} of ${truncation.totalLines} lines`
      : `Truncated: showing ${truncation.outputLines} of ${truncation.totalLines} lines`
  }
  return `Truncated: ${truncation.outputLines} lines shown (${formatBytes(DEFAULT_MAX_BYTES)} limit)`
}

function boundedNotices(values: readonly string[], tone: ToolDisplayNotice["tone"]): ToolDisplayNotice[] {
  const notices: ToolDisplayNotice[] = []
  for (const value of values) appendNotice(notices, tone, value)
  return notices
}

function appendNotice(notices: ToolDisplayNotice[], tone: ToolDisplayNotice["tone"], text: string): void {
  if (notices.length === maxNotices) return
  notices.push({ tone, text: boundedInline(text, maxNoticeLength) })
}

function noticeCovered(candidate: string, notices: readonly ToolDisplayNotice[]): boolean {
  const normalized = candidate.toLowerCase()
  return notices.some(notice => {
    const text = notice.text.toLowerCase()
    return normalized.includes(text) || (normalized.includes("full output") && text.includes("full output"))
  })
}

function extractTrailingNotices(text: string): { text: string; notices: readonly string[] } {
  const suffix = text.length > maxNoticeScanLength ? text.slice(-maxNoticeScanLength) : text
  const match = suffix.match(/(?:\n\n|^)((?:\[[^\n]+\](?:\n|$))+)\s*$/)
  if (!match || match.index === undefined) return { text, notices: [] }
  const notices = match[1]!
    .trim()
    .split("\n")
    .map(line => line.slice(1, -1))
  const noticeStart = text.length - suffix.length + match.index
  return { text: text.slice(0, noticeStart).trimEnd(), notices }
}

function boundedHead(text: string): string {
  return truncateHead(text, DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES).content
}

function boundedTail(text: string): string {
  return truncateTail(text, DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES).content
}

function boundedInline(text: string, limit: number): string {
  if (text.length <= limit) return text
  return `${text.slice(0, limit - 1)}…`
}

function resultText(result: unknown): string {
  if (!isRecord(result) || !Array.isArray(result.content)) return ""
  return result.content
    .map(part => (isRecord(part) && part.type === "text" && typeof part.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
}

function resultDetails(result: unknown): Record<string, unknown> | undefined {
  return isRecord(result) ? asRecord(result.details) : undefined
}

function truncationDetails(value: unknown): TruncationResult | undefined {
  if (!isRecord(value)) return undefined
  if (
    typeof value.content !== "string" ||
    typeof value.truncated !== "boolean" ||
    (value.truncatedBy !== "lines" && value.truncatedBy !== "bytes" && value.truncatedBy !== null) ||
    typeof value.totalLines !== "number" ||
    typeof value.totalBytes !== "number" ||
    typeof value.outputLines !== "number" ||
    typeof value.outputBytes !== "number" ||
    typeof value.firstLineExceedsLimit !== "boolean" ||
    typeof value.lastLinePartial !== "boolean"
  ) {
    return undefined
  }
  return {
    content: value.content,
    truncated: value.truncated,
    truncatedBy: value.truncatedBy,
    totalLines: value.totalLines,
    totalBytes: value.totalBytes,
    outputLines: value.outputLines,
    outputBytes: value.outputBytes,
    firstLineExceedsLimit: value.firstLineExceedsLimit,
    lastLinePartial: value.lastLinePartial
  }
}

function editValues(args: Record<string, unknown> | undefined): readonly unknown[] {
  if (Array.isArray(args?.edits)) return args.edits
  if (typeof args?.edits === "string") {
    try {
      const parsed: unknown = JSON.parse(args.edits)
      if (Array.isArray(parsed)) return parsed
    } catch {}
  }
  if (typeof args?.oldText === "string" && typeof args.newText === "string") {
    return [{ oldText: args.oldText, newText: args.newText }]
  }
  return []
}

function json(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2) ?? ""
  } catch {
    return "[unserializable arguments]"
  }
}

function formatBytes(bytes: number): string {
  return bytes % 1024 === 0 ? `${bytes / 1024} KiB` : `${bytes} bytes`
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

function integerValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) ? value : undefined
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return isRecord(value) ? value : undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

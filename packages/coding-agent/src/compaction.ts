import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import { isContextOverflow, type Api, type AssistantMessage, type Context, type Model } from "@earendil-works/pi-ai"

import { formatCompactionSummary, type AgentMessage } from "./messages.js"
import {
  maxCompactionFilePaths,
  maxCompactionPathBytes,
  maxCompactionSummaryBytes,
  sessionEntryToContextMessage,
  type CompactionDetails,
  type CompactionEntry,
  type SessionEntry
} from "./session-manager.js"

export { formatCompactionSummary } from "./messages.js"
export { maxCompactionFilePaths, maxCompactionPathBytes, maxCompactionSummaryBytes } from "./session-manager.js"

export const maxCompactionInstructionsBytes = 16 * 1024
export const maxCompactionChunks = 8
export const maxCompactionErrorBytes = 2_000
export const maxCompactionOperationMs = 10 * 60_000
export const maxSerializedToolResultChars = 2_000

const estimatedImageTokens = 1_200
const structuredValueChars = 2_000

export interface CompactionSettings {
  readonly reserveTokens: number
  readonly keepRecentTokens: number
}

export interface EffectiveCompactionSettings {
  readonly reserveTokens: number
  readonly keepRecentTokens: number
  readonly triggerTokens: number
  readonly summaryMaxTokens: number
}

export interface ContextAccountingSnapshot {
  readonly tokens: number
  readonly quality: "measured" | "estimated"
}

export interface CompactionPlan {
  readonly firstKeptEntryId: string
  readonly previousSummary?: string
  readonly sourceMessages: readonly AgentMessage[]
  readonly retainedMessages: readonly AgentMessage[]
  readonly tokensBefore: number
  readonly estimatedTokensBefore: number
  readonly compactedEntries: number
  readonly details: CompactionDetails
  readonly excludedFailureEntryId?: string
}

export type CompactionPreparation =
  | { readonly type: "ready"; readonly plan: CompactionPlan }
  | { readonly type: "nothing_to_compact" }

export interface SummaryRequest {
  readonly context: Context
  readonly maxTokens: number
  readonly thinkingLevel?: Exclude<ThinkingLevel, "off">
}

export type SummarySampler = (request: SummaryRequest, signal: AbortSignal) => Promise<AssistantMessage>

export function effectiveCompactionSettings(
  model: Pick<Model<Api>, "contextWindow" | "maxTokens">,
  configured: CompactionSettings
): EffectiveCompactionSettings | undefined {
  const contextWindow = Math.floor(model.contextWindow)
  if (contextWindow <= 0) return undefined
  const reserveTokens = Math.max(1, Math.min(configured.reserveTokens, Math.floor(contextWindow / 4)))
  const triggerTokens = Math.max(1, contextWindow - reserveTokens)
  const keepRecentTokens = Math.max(
    1,
    Math.min(configured.keepRecentTokens, Math.floor((contextWindow - reserveTokens) / 2))
  )
  const modelOutputCap = model.maxTokens > 0 ? Math.floor(model.maxTokens) : reserveTokens
  const summaryMaxTokens = Math.max(1, Math.min(modelOutputCap, Math.floor(reserveTokens * 0.8)))
  return Object.freeze({ reserveTokens, keepRecentTokens, triggerTokens, summaryMaxTokens })
}

export function shouldCompact(tokens: number, settings: EffectiveCompactionSettings): boolean {
  return tokens > settings.triggerTokens
}

export function estimateMessageTokens(message: AgentMessage): number {
  switch (message.role) {
    case "user":
    case "custom":
    case "toolResult":
      return estimateTextAndImages(message.content)
    case "assistant": {
      let bytes = 0
      for (const part of message.content) {
        if (part.type === "text") bytes += Buffer.byteLength(part.text)
        else if (part.type === "thinking") bytes += Buffer.byteLength(part.thinking)
        else bytes += Buffer.byteLength(part.name) + Buffer.byteLength(safeJson(part.arguments))
      }
      if (message.errorMessage) bytes += Buffer.byteLength(message.errorMessage)
      return bytesToTokens(bytes)
    }
    case "bashExecution":
      return bytesToTokens(Buffer.byteLength(message.command) + Buffer.byteLength(message.output))
    case "branchSummary":
    case "compactionSummary":
      return bytesToTokens(Buffer.byteLength(message.summary))
    default:
      return assertNever(message)
  }
}

export function estimateMessagesTokens(messages: readonly AgentMessage[]): number {
  let tokens = 0
  for (const message of messages) tokens += estimateMessageTokens(message)
  return tokens
}

export interface EstimatedContextTokens {
  readonly tokens: number
  readonly usageTokens: number
  readonly trailingTokens: number
  readonly lastUsageIndex: number | null
}

export function estimateContextTokens(
  messages: readonly AgentMessage[],
  minimumAnchorIndex = 0
): EstimatedContextTokens {
  for (let index = messages.length - 1; index >= minimumAnchorIndex; index--) {
    const usage = validAssistantUsage(messages[index]!)
    if (usage === undefined) continue
    const trailingTokens = estimateMessagesTokens(messages.slice(index + 1))
    return { tokens: usage + trailingTokens, usageTokens: usage, trailingTokens, lastUsageIndex: index }
  }
  const tokens = estimateMessagesTokens(messages)
  return { tokens, usageTokens: 0, trailingTokens: tokens, lastUsageIndex: null }
}

export function prepareCompaction(
  entries: readonly SessionEntry[],
  settings: EffectiveCompactionSettings,
  accounting: ContextAccountingSnapshot,
  excludedFailureEntryId?: string
): CompactionPreparation {
  const latestMarker = findLatestMarker(entries)
  const exactEntries = projectedExactEntries(entries, latestMarker, excludedFailureEntryId)
  if (exactEntries.length < 2) return { type: "nothing_to_compact" }

  let retainedTokens = 0
  let boundaryIndex = -1
  for (let index = exactEntries.length - 1; index >= 0; index--) {
    retainedTokens += estimateMessageTokens(exactEntries[index]!.message)
    if (retainedTokens < settings.keepRecentTokens) continue
    boundaryIndex = safeRetainedBoundary(exactEntries, index)
    break
  }
  if (boundaryIndex < 0) boundaryIndex = safeRetainedBoundary(exactEntries, 0)
  if (boundaryIndex <= 0) return { type: "nothing_to_compact" }

  const sourceEntries = exactEntries.slice(0, boundaryIndex)
  const retainedEntries = exactEntries.slice(boundaryIndex)
  const firstKept = retainedEntries[0]
  if (!firstKept || firstKept.message.role === "toolResult") return { type: "nothing_to_compact" }

  const sourceMessages = sourceEntries.map(entry => entry.message)
  const retainedMessages = retainedEntries.map(entry => entry.message)
  const activeMessages = exactEntries.map(entry => entry.message)
  const details = collectCompactionDetails(sourceMessages, latestMarker?.details)
  return {
    type: "ready",
    plan: Object.freeze({
      firstKeptEntryId: firstKept.id,
      ...(latestMarker ? { previousSummary: latestMarker.summary } : {}),
      sourceMessages: Object.freeze(sourceMessages),
      retainedMessages: Object.freeze(retainedMessages),
      tokensBefore: accounting.tokens,
      estimatedTokensBefore:
        estimateMessagesTokens(activeMessages) +
        (latestMarker ? estimateNarrativeAndDetails(latestMarker.summary, latestMarker.details) : 0),
      compactedEntries: sourceEntries.length,
      details,
      ...(excludedFailureEntryId ? { excludedFailureEntryId } : {})
    })
  }
}

export function validateCompactionReduction(plan: CompactionPlan, summary: string): number {
  const estimatedTokensAfter =
    estimateNarrativeAndDetails(summary, plan.details) + estimateMessagesTokens(plan.retainedMessages)
  if (estimatedTokensAfter >= plan.estimatedTokensBefore) {
    throw new Error("Compaction summary did not reduce the active context")
  }
  return estimatedTokensAfter
}

export async function generateCompactionSummary(
  plan: CompactionPlan,
  model: Model<Api>,
  settings: EffectiveCompactionSettings,
  customInstructions: string | undefined,
  thinkingLevel: ThinkingLevel,
  sampler: SummarySampler,
  signal: AbortSignal
): Promise<string> {
  assertCustomInstructions(customInstructions)
  const items = plan.sourceMessages.map(serializeCompactionMessage)
  const inputBudgetTokens = model.contextWindow - settings.summaryMaxTokens
  if (inputBudgetTokens <= 0) throw new Error("Selected model cannot fit a compaction request")

  const queue = initialSummaryChunks(items, inputBudgetTokens, plan.previousSummary, customInstructions)
  let summary = plan.previousSummary
  let completed = 0
  let attempts = 0
  while (queue.length > 0) {
    if (signal.aborted) throw cancellationError()
    if (completed + queue.length > maxCompactionChunks) throw new Error("Compaction source exceeds the 8-chunk limit")

    let chunk = queue.shift()!
    let prompt = buildSummaryPrompt(chunk, summary, customInstructions)
    while (estimatePromptTokens(prompt) > inputBudgetTokens) {
      const split = splitSerializedItem(chunk)
      if (!split) throw new Error("Compaction source cannot fit the selected model context")
      chunk = split[0]
      queue.unshift(split[1])
      if (completed + queue.length + 1 > maxCompactionChunks) {
        throw new Error("Compaction source exceeds the 8-chunk limit")
      }
      prompt = buildSummaryPrompt(chunk, summary, customInstructions)
    }

    const context: Context = {
      systemPrompt: summarizationSystemPrompt,
      messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }]
    }
    if (attempts === maxCompactionChunks) throw new Error("Compaction source exceeds the 8-chunk limit")
    attempts++
    // Chunks update one summary in source order; parallel sampling would lose the previous chunk's checkpoint.
    // oxlint-disable-next-line no-await-in-loop
    const response = await sampler(
      {
        context,
        maxTokens: settings.summaryMaxTokens,
        ...(model.reasoning && thinkingLevel !== "off" ? { thinkingLevel } : {})
      },
      signal
    )
    if (isContextOverflow(response, model.contextWindow)) {
      const split = splitSerializedItem(chunk)
      if (!split || completed + queue.length + 2 > maxCompactionChunks) {
        throw new Error("Compaction source cannot fit the selected model context")
      }
      queue.unshift(split[1])
      queue.unshift(split[0])
      continue
    }
    summary = validateSummaryResponse(response)
    completed++
  }
  if (!summary) throw new Error("Compaction produced no summary")
  return summary
}

export function serializeCompactionMessage(message: AgentMessage): string {
  switch (message.role) {
    case "user":
      return `[User]\n${serializeTextAndImages(message.content)}`
    case "assistant": {
      const parts: string[] = []
      for (const part of message.content) {
        if (part.type === "text") parts.push(`[Assistant]\n${part.text}`)
        else if (part.type === "thinking") parts.push(`[Assistant thinking]\n${part.thinking}`)
        else parts.push(`[Assistant tool call]\n${part.name}(${safeJson(part.arguments, structuredValueChars)})`)
      }
      if (message.errorMessage)
        parts.push(`[Provider error]\n${truncateChars(message.errorMessage, structuredValueChars)}`)
      return parts.join("\n\n") || "[Assistant]\n(empty)"
    }
    case "toolResult": {
      const content = serializeTextAndImages(message.content)
      return `[Tool result: ${message.toolName}${message.isError ? ", error" : ""}]\n${truncateChars(content, maxSerializedToolResultChars)}`
    }
    case "bashExecution":
      return `[Shell command]\n${message.command}\n[Shell output]\n${truncateChars(message.output, maxSerializedToolResultChars)}`
    case "custom":
      return `[${message.customType}]\n${serializeTextAndImages(message.content)}`
    case "branchSummary":
      return `[Branch summary]\n${message.summary}`
    case "compactionSummary":
      return `[Previous compaction summary]\n${message.summary}`
    default:
      return assertNever(message)
  }
}

export function splitUtf8(text: string, maxBytes: number): string[] {
  if (maxBytes < 1) throw new Error("UTF-8 split size must be positive")
  if (Buffer.byteLength(text) <= maxBytes) return [text]
  const parts: string[] = []
  let current = ""
  let bytes = 0
  for (const character of text) {
    const characterBytes = Buffer.byteLength(character)
    if (characterBytes > maxBytes) throw new Error("UTF-8 split size cannot fit one code point")
    if (bytes > 0 && bytes + characterBytes > maxBytes) {
      parts.push(current)
      current = ""
      bytes = 0
    }
    current += character
    bytes += characterBytes
  }
  if (current) parts.push(current)
  return parts
}

export function validateSummaryResponse(response: AssistantMessage): string {
  if (response.stopReason === "aborted") throw cancellationError(response.errorMessage)
  if (response.stopReason === "error") {
    throw new Error(
      boundedCompactionErrorMessage(response.errorMessage || "Unknown provider error", "Compaction failed: ")
    )
  }
  const summary = response.content
    .flatMap(part => (part.type === "text" ? [part.text] : []))
    .join("\n")
    .trim()
  if (!summary) throw new Error("Compaction produced an empty summary")
  if (Buffer.byteLength(summary) > maxCompactionSummaryBytes) {
    throw new Error(`Compaction summary cannot exceed ${maxCompactionSummaryBytes} bytes`)
  }
  return summary
}

export function normalizeCompactionError(cause: unknown): Error {
  return new Error(boundedCompactionErrorMessage(cause))
}

export function assertCustomInstructions(value: string | undefined): void {
  if (value !== undefined && Buffer.byteLength(value) > maxCompactionInstructionsBytes) {
    throw new Error(`Compaction focus cannot exceed ${maxCompactionInstructionsBytes} bytes`)
  }
}

const summarizationSystemPrompt = `You are a context summarization assistant. Summarize the supplied conversation instead of continuing it. Preserve exact paths, symbols, decisions, constraints, and error messages. Output only the structured checkpoint.`

const initialSummaryInstruction = `Create a concise checkpoint using exactly these sections:\n\n## Goal\n## Constraints & Preferences\n## Progress\n### Done\n### In Progress\n### Blocked\n## Key Decisions\n## Next Steps\n## Critical Context`

const updateSummaryInstruction = `Update the checkpoint in <previous-summary> with the new conversation. Preserve still-relevant facts and exact paths, symbols, decisions, constraints, and errors. Use exactly these sections:\n\n## Goal\n## Constraints & Preferences\n## Progress\n### Done\n### In Progress\n### Blocked\n## Key Decisions\n## Next Steps\n## Critical Context`

function buildSummaryPrompt(chunk: string, previousSummary: string | undefined, focus: string | undefined): string {
  const previous = previousSummary ? `\n\n<previous-summary>\n${previousSummary}\n</previous-summary>` : ""
  const instruction = previousSummary ? updateSummaryInstruction : initialSummaryInstruction
  const additionalFocus = focus ? `\n\nAdditional focus: ${focus}` : ""
  return `<conversation>\n${chunk}\n</conversation>${previous}\n\n${instruction}${additionalFocus}`
}

function initialSummaryChunks(
  items: readonly string[],
  budgetTokens: number,
  previousSummary: string | undefined,
  focus: string | undefined
): string[] {
  const chunks: string[] = []
  let current = ""
  for (const item of items) {
    const candidate = current ? `${current}\n\n${item}` : item
    if (estimatePromptTokens(buildSummaryPrompt(candidate, previousSummary, focus)) <= budgetTokens) {
      current = candidate
      continue
    }
    if (current) {
      chunks.push(current)
      current = ""
    }
    const availableBytes = Math.max(
      1,
      budgetTokens * 4 - Buffer.byteLength(buildSummaryPrompt("", previousSummary, focus))
    )
    if (chunks.length + Math.ceil(Buffer.byteLength(item) / availableBytes) > maxCompactionChunks) {
      throw new Error("Compaction source exceeds the 8-chunk limit")
    }
    const parts = splitUtf8(item, availableBytes)
    for (const [index, part] of parts.entries()) {
      chunks.push(parts.length === 1 ? part : `[item part ${index + 1}/${parts.length}]\n${part}`)
      if (chunks.length > maxCompactionChunks) throw new Error("Compaction source exceeds the 8-chunk limit")
    }
  }
  if (current) chunks.push(current)
  if (chunks.length === 0) throw new Error("Nothing to compact")
  if (chunks.length > maxCompactionChunks) throw new Error("Compaction source exceeds the 8-chunk limit")
  return chunks
}

function splitSerializedItem(value: string): readonly [string, string] | undefined {
  if (Buffer.byteLength(value) < 2) return undefined
  const parts = splitUtf8(value, Math.max(1, Math.floor(Buffer.byteLength(value) / 2)))
  if (parts.length < 2) return undefined
  const midpoint = Math.ceil(parts.length / 2)
  return [parts.slice(0, midpoint).join(""), parts.slice(midpoint).join("")]
}

interface ExactContextEntry {
  readonly id: string
  readonly message: AgentMessage
}

function projectedExactEntries(
  entries: readonly SessionEntry[],
  latestMarker: CompactionEntry | undefined,
  operationExcluded: string | undefined
): ExactContextEntry[] {
  const excluded = new Set(
    [
      latestMarker?.excludedFailureEntryId,
      operationExcluded,
      ...entries.flatMap(entry => (entry.type === "retry" ? [entry.failedEntryId] : []))
    ].filter(id => id !== undefined)
  )
  const messages = (values: readonly SessionEntry[]) =>
    values.flatMap(entry => {
      if (entry.type === "compaction" || excluded.has(entry.id)) return []
      const message = sessionEntryToContextMessage(entry)
      return message ? [{ id: entry.id, message }] : []
    })
  if (!latestMarker) return messages(entries)
  const markerIndex = entries.indexOf(latestMarker)
  const boundaryIndex = entries.findIndex(entry => entry.id === latestMarker.firstKeptEntryId)
  return [...messages(entries.slice(boundaryIndex, markerIndex)), ...messages(entries.slice(markerIndex + 1))]
}

function safeRetainedBoundary(entries: readonly ExactContextEntry[], fromIndex: number): number {
  for (let index = Math.max(0, fromIndex); index < entries.length; index++) {
    if (entries[index]!.message.role !== "toolResult") return index
  }
  const trailingResultIds = new Set(
    entries.slice(fromIndex).flatMap(entry => (entry.message.role === "toolResult" ? [entry.message.toolCallId] : []))
  )
  for (let index = fromIndex - 1; index >= 0; index--) {
    const message = entries[index]!.message
    if (message.role !== "assistant") continue
    if (message.content.some(part => part.type === "toolCall" && trailingResultIds.has(part.id))) return index
  }
  return -1
}

function findLatestMarker(entries: readonly SessionEntry[]): CompactionEntry | undefined {
  return entries.findLast((entry): entry is CompactionEntry => entry.type === "compaction")
}

function collectCompactionDetails(
  messages: readonly AgentMessage[],
  previous: CompactionDetails | undefined
): CompactionDetails {
  const read = new Set(previous?.readFiles ?? [])
  const modified = new Set(previous?.modifiedFiles ?? [])
  let omittedReadFiles = previous?.omittedReadFiles ?? 0
  let omittedModifiedFiles = previous?.omittedModifiedFiles ?? 0
  const calls = new Map<string, { readonly name: string; readonly path: string }>()

  for (const message of messages) {
    if (message.role === "assistant") {
      for (const part of message.content) {
        if (part.type !== "toolCall" || (part.name !== "read" && part.name !== "write" && part.name !== "edit"))
          continue
        const path =
          isRecord(part.arguments) && typeof part.arguments.path === "string" ? part.arguments.path : undefined
        if (path) calls.set(part.id, { name: part.name, path })
      }
      continue
    }
    if (message.role !== "toolResult" || message.isError) continue
    const call = calls.get(message.toolCallId)
    if (!call) continue
    if (call.name === "read") read.add(call.path)
    else modified.add(call.path)
  }
  for (const path of modified) read.delete(path)
  const boundedRead = boundPaths(read)
  const boundedModified = boundPaths(modified)
  omittedReadFiles += boundedRead.omitted
  omittedModifiedFiles += boundedModified.omitted
  return Object.freeze({
    readFiles: Object.freeze(boundedRead.paths),
    modifiedFiles: Object.freeze(boundedModified.paths),
    omittedReadFiles,
    omittedModifiedFiles
  })
}

function boundPaths(paths: ReadonlySet<string>): { readonly paths: string[]; readonly omitted: number } {
  const valid = [...paths].filter(path => Buffer.byteLength(path) <= maxCompactionPathBytes).toSorted()
  const invalid = paths.size - valid.length
  return {
    paths: valid.slice(0, maxCompactionFilePaths),
    omitted: invalid + Math.max(0, valid.length - maxCompactionFilePaths)
  }
}

function estimateNarrativeAndDetails(summary: string, details: CompactionDetails): number {
  return bytesToTokens(Buffer.byteLength(formatCompactionSummary(summary, details)))
}

function validAssistantUsage(message: AgentMessage): number | undefined {
  if (message.role !== "assistant" || message.stopReason === "error" || message.stopReason === "aborted")
    return undefined
  const usage =
    message.usage.totalTokens ||
    message.usage.input + message.usage.output + message.usage.cacheRead + message.usage.cacheWrite
  return Number.isFinite(usage) && usage > 0 ? usage : undefined
}

function estimateTextAndImages(content: unknown): number {
  if (typeof content === "string") return bytesToTokens(Buffer.byteLength(content))
  if (!Array.isArray(content)) return 0
  let tokens = 0
  for (const part of content) {
    if (!isRecord(part)) continue
    if (part.type === "text" && typeof part.text === "string") tokens += bytesToTokens(Buffer.byteLength(part.text))
    else if (part.type === "image") tokens += estimatedImageTokens
  }
  return tokens
}

function serializeTextAndImages(content: unknown): string {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .flatMap(part => {
      if (!isRecord(part)) return []
      if (part.type === "text" && typeof part.text === "string") return [part.text]
      if (part.type === "image" && typeof part.mimeType === "string") return [`[image: ${part.mimeType}]`]
      return []
    })
    .join("\n")
}

function estimatePromptTokens(prompt: string): number {
  return bytesToTokens(Buffer.byteLength(summarizationSystemPrompt) + Buffer.byteLength(prompt))
}

function bytesToTokens(bytes: number): number {
  return Math.ceil(bytes / 4)
}

function truncateChars(text: string, maximum: number): string {
  if (text.length <= maximum) return text
  return `${text.slice(0, maximum)}\n[… ${text.length - maximum} characters omitted]`
}

function safeJson(value: unknown, maximum = Number.POSITIVE_INFINITY): string {
  let serialized: string
  try {
    serialized = JSON.stringify(value) ?? "undefined"
  } catch {
    serialized = "[unserializable]"
  }
  return truncateChars(serialized, maximum)
}

function boundedCompactionErrorMessage(cause: unknown, prefix = ""): string {
  const message = cause instanceof Error ? cause.message : String(cause)
  const suffix = "…"
  const budget = maxCompactionErrorBytes - Buffer.byteLength(suffix)
  let result = ""
  let bytes = 0

  for (const part of [prefix, message]) {
    for (const character of part) {
      const next = Buffer.byteLength(character)
      if (bytes + next > budget) return result + suffix
      result += character
      bytes += next
    }
  }
  return result
}

function cancellationError(message = "Compaction cancelled"): Error {
  return new Error(boundedCompactionErrorMessage(message), { cause: "cancelled" })
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected message: ${String(value)}`)
}

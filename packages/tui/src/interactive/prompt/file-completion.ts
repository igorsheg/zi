import type { TextareaRenderable } from "@opentui/core"
import {
  maxProjectFileSearchQueryBytes,
  type ProjectFileMatch,
  type ProjectFileSearchResult,
  validateProjectFileSearchQuery
} from "@openzi/coding-agent"

import {
  promptTextIndex,
  promptTextOffsetIsBoundary,
  promptTextSlice,
  promptTextWidth
} from "../../components/cell-text.js"
import { fileFrame, promptPickerFrameIds } from "./frames.js"
import type { PickerStack } from "./picker.js"

export const fileCompletionDebounceMs = 20

export const maxFileCompletionContextCells = maxProjectFileSearchQueryBytes + 4

export interface FileCompletionInput {
  readonly cursorOffset: number
  readonly beforeCursor: string
  readonly afterCursor: string
  readonly beforeTruncated: boolean
  readonly afterTruncated: boolean
  readonly lineTerminated: boolean
  readonly validCursor: boolean
}

export interface FileCompletionContext {
  readonly triggerStart: number
  readonly tokenEnd: number
  readonly cursorOffset: number
  readonly query: string
  readonly quoted: boolean
}

export interface FileCompletionSearchSession {
  searchProjectFiles(query: string, signal: AbortSignal): Promise<ProjectFileSearchResult>
}

export interface FileCompletionRangeEdit {
  readonly startOffset: number
  readonly endOffset: number
  readonly replacement: string
  readonly cursorOffset: number
}

interface PendingFileCompletion {
  readonly operationId: number
  readonly session: FileCompletionSearchSession
  readonly draftRevision: number
  readonly context: FileCompletionContext
}

type FileCompletionState =
  | { readonly type: "closed" }
  | { readonly type: "waiting"; readonly pending: PendingFileCompletion; readonly timer: ReturnType<typeof setTimeout> }
  | {
      readonly type: "searching"
      readonly active: PendingFileCompletion
      readonly controller: AbortController
      readonly settled: Promise<void>
    }
  | {
      readonly type: "switching"
      readonly pending: PendingFileCompletion
      readonly timer: ReturnType<typeof setTimeout>
      readonly previousSettled: Promise<void>
    }
  | { readonly type: "showing"; readonly request: PendingFileCompletion; readonly result: ProjectFileSearchResult }
  | {
      readonly type: "dismissed"
      readonly draftRevision: number
      readonly triggerStart: number
      readonly acceptsPreviousRevision: boolean
    }
  | { readonly type: "disposed" }

export class FileCompletionController {
  readonly #picker: PickerStack
  readonly #requestEdit: (edit: FileCompletionRangeEdit) => void
  #state: FileCompletionState = { type: "closed" }
  #current: PendingFileCompletion | undefined
  #nextOperationId = 0
  #searchReady = true
  #debouncedTimer: ReturnType<typeof setTimeout> | undefined

  constructor(picker: PickerStack, requestEdit: (edit: FileCompletionRangeEdit) => void) {
    this.#picker = picker
    this.#requestEdit = requestEdit
  }

  update(session: FileCompletionSearchSession, draftRevision: number, input: FileCompletionInput): void {
    if (this.#state.type === "disposed") return
    const context = parseFileCompletionContext(input)
    if (!context) {
      this.#current = undefined
      if (this.#state.type === "dismissed") {
        this.#closeFrame()
        return
      }
      this.close()
      return
    }

    const current: PendingFileCompletion = { operationId: ++this.#nextOperationId, session, draftRevision, context }
    const previousCurrent = this.#current
    if (
      previousCurrent &&
      previousCurrent.session === session &&
      previousCurrent.draftRevision === draftRevision &&
      sameFileCompletionContext(previousCurrent.context, context)
    ) {
      return
    }
    this.#current = current

    const state = this.#state
    if (
      state.type === "dismissed" &&
      (state.draftRevision === draftRevision ||
        (state.acceptsPreviousRevision && state.draftRevision === draftRevision + 1)) &&
      state.triggerStart === context.triggerStart
    ) {
      return
    }

    this.#closeFrame()
    switch (state.type) {
      case "waiting":
        this.#cancelTimer(state.timer)
        this.#wait(current)
        return
      case "searching":
        state.controller.abort()
        this.#switch(current, state.settled)
        return
      case "switching":
        this.#cancelTimer(state.timer)
        this.#switch(current, state.previousSettled)
        return
      case "closed":
      case "showing":
      case "dismissed":
        this.#wait(current)
        return
      default:
        return assertNever(state)
    }
  }

  complete(selectedId: string, input: FileCompletionInput): boolean {
    const state = this.#state
    if (state.type !== "showing") return false
    const context = parseFileCompletionContext(input)
    if (
      !context ||
      !sameRequestContext(state.request, this.#current) ||
      !sameFileCompletionContext(context, state.request.context)
    ) {
      this.close()
      return false
    }
    const match = state.result.matches.find(candidate => fileCompletionCandidateId(candidate) === selectedId)
    if (!match) return false

    const capturedFollowingText = promptTextSlice(input.afterCursor, context.tokenEnd - context.cursorOffset)
    const followingText = capturedFollowingText || (input.lineTerminated ? "\n" : "")
    const formatted = formatFileReference(match, context, followingText)
    const cursorTarget = context.triggerStart + formatted.cursorAfterTrigger
    this.#state =
      match.type === "file"
        ? {
            type: "dismissed",
            draftRevision: state.request.draftRevision + 1,
            triggerStart: context.triggerStart,
            acceptsPreviousRevision: true
          }
        : { type: "closed" }
    this.#current = undefined
    this.#closeFrame()
    this.#requestEdit({
      startOffset: context.triggerStart,
      endOffset: context.tokenEnd,
      replacement: formatted.replacement,
      cursorOffset: cursorTarget
    })
    return true
  }

  dismiss(): void {
    const state = this.#state
    if (state.type !== "showing") return
    this.#state = {
      type: "dismissed",
      draftRevision: state.request.draftRevision,
      triggerStart: state.request.context.triggerStart,
      acceptsPreviousRevision: false
    }
    this.#closeFrame()
  }

  close(): void {
    const state = this.#state
    if (state.type === "dismissed") {
      this.#current = undefined
      this.#closeFrame()
      return
    }
    switch (state.type) {
      case "waiting":
        this.#cancelTimer(state.timer)
        break
      case "searching":
        state.controller.abort()
        break
      case "switching":
        this.#cancelTimer(state.timer)
        break
      case "closed":
      case "showing":
        break
      case "disposed":
        return
      default:
        assertNever(state)
    }
    this.#state = { type: "closed" }
    this.#current = undefined
    this.#closeFrame()
  }

  dispose(): void {
    const state = this.#state
    if (state.type === "disposed") return
    if (state.type === "waiting" || state.type === "switching") this.#cancelTimer(state.timer)
    if (state.type === "searching") state.controller.abort()
    this.#debouncedTimer = undefined
    this.#state = { type: "disposed" }
    this.#current = undefined
    this.#closeFrame()
  }

  #wait(pending: PendingFileCompletion): void {
    let timer!: ReturnType<typeof setTimeout>
    timer = setTimeout(() => this.#debounceFinished(timer), fileCompletionDebounceMs)
    this.#state = { type: "waiting", pending, timer }
  }

  #switch(pending: PendingFileCompletion, previousSettled: Promise<void>): void {
    let timer!: ReturnType<typeof setTimeout>
    timer = setTimeout(() => this.#debounceFinished(timer), fileCompletionDebounceMs)
    this.#state = { type: "switching", pending, timer, previousSettled }
  }

  #debounceFinished(timer: ReturnType<typeof setTimeout>): void {
    const state = this.#state
    if ((state.type !== "waiting" && state.type !== "switching") || state.timer !== timer) return
    this.#debouncedTimer = timer
    this.#startDebounced()
  }

  #startDebounced(): void {
    if (!this.#searchReady || this.#debouncedTimer === undefined) return
    const state = this.#state
    if (
      (state.type !== "waiting" && state.type !== "switching") ||
      state.timer !== this.#debouncedTimer ||
      !sameRequestContext(state.pending, this.#current)
    ) {
      return
    }
    this.#debouncedTimer = undefined
    this.#start(state.pending)
  }

  #cancelTimer(timer: ReturnType<typeof setTimeout>): void {
    clearTimeout(timer)
    if (this.#debouncedTimer === timer) this.#debouncedTimer = undefined
  }

  #start(active: PendingFileCompletion): void {
    const controller = new AbortController()
    const settlement = deferred()
    this.#state = { type: "searching", active, controller, settled: settlement.promise }
    this.#searchReady = false
    void settlement.promise.then(() => {
      this.#searchReady = true
      this.#startDebounced()
      return undefined
    })

    void Promise.resolve()
      .then(() => active.session.searchProjectFiles(active.context.query, controller.signal))
      .then(result => {
        if (!this.#isCurrentSearch(active)) return undefined
        if (result.matches.length === 0) {
          this.#state = { type: "closed" }
          this.#closeFrame()
          return undefined
        }
        const presentation = this.#picker.presentation("")
        if (presentation && presentation.frame.id !== promptPickerFrameIds.files) {
          this.#state = { type: "closed" }
          return undefined
        }
        this.#state = { type: "showing", request: active, result }
        this.#picker.open(fileFrame(result, active.context.query))
        return undefined
      })
      .catch(() => {
        if (!this.#isCurrentSearch(active)) return
        this.#state = { type: "closed" }
        this.#closeFrame()
      })
      .finally(settlement.resolve)
  }

  #isCurrentSearch(active: PendingFileCompletion): boolean {
    return (
      this.#state.type === "searching" &&
      sameRequest(this.#state.active, active) &&
      sameRequestContext(active, this.#current)
    )
  }

  #closeFrame(): void {
    if (this.#picker.presentation("")?.frame.id === promptPickerFrameIds.files) this.#picker.close()
  }
}

export function captureFileCompletionInput(input: TextareaRenderable): FileCompletionInput {
  const cursorOffset = input.cursorOffset
  const lineStart = input.editBuffer.getLineStartOffset(input.logicalCursor.row)
  const lineEnd = input.editBuffer.getEOL().offset
  const beforeStart = Math.max(lineStart, cursorOffset - maxFileCompletionContextCells)
  const afterEnd = Math.min(lineEnd, cursorOffset + maxFileCompletionContextCells)
  return {
    cursorOffset,
    beforeCursor: input.editBuffer.getTextRange(beforeStart, cursorOffset),
    afterCursor: input.editBuffer.getTextRange(cursorOffset, afterEnd),
    beforeTruncated: beforeStart > lineStart,
    afterTruncated: afterEnd < lineEnd,
    lineTerminated: input.logicalCursor.row < input.lineCount - 1,
    validCursor: true
  }
}

/** Pure test adapter; production parsing uses native edit-buffer ranges. */
export function fileCompletionInputFromText(text: string, cursorOffset: number): FileCompletionInput {
  if (!promptTextOffsetIsBoundary(text, cursorOffset)) {
    return {
      cursorOffset,
      beforeCursor: "",
      afterCursor: "",
      beforeTruncated: false,
      afterTruncated: false,
      lineTerminated: false,
      validCursor: false
    }
  }
  const cursorIndex = promptTextIndex(text, cursorOffset)
  const lineStartIndex = text.lastIndexOf("\n", cursorIndex - 1) + 1
  const nextNewline = text.indexOf("\n", cursorIndex)
  const lineEndIndex = nextNewline === -1 ? text.length : nextNewline
  return {
    cursorOffset,
    beforeCursor: text.slice(lineStartIndex, cursorIndex),
    afterCursor: text.slice(cursorIndex, lineEndIndex),
    beforeTruncated: false,
    afterTruncated: false,
    lineTerminated: nextNewline !== -1,
    validCursor: true
  }
}

export function parseFileCompletionContext(input: FileCompletionInput): FileCompletionContext | undefined {
  if (!input.validCursor) return undefined
  const before = input.beforeCursor
  let triggerIndex = before.lastIndexOf("@")
  while (triggerIndex !== -1) {
    if (triggerIndex === 0 && input.beforeTruncated) return undefined
    const predecessor = previousCodePoint(before, triggerIndex)
    if (!predecessor || !/[\p{L}\p{N}_]/u.test(predecessor)) break
    triggerIndex = before.lastIndexOf("@", triggerIndex - 1)
  }
  if (triggerIndex === -1) return undefined

  const quoted = before[triggerIndex + 1] === '"'
  if (!quoted && before.length === triggerIndex + 1 && input.afterCursor.startsWith('"')) return undefined
  const queryStart = triggerIndex + (quoted ? 2 : 1)
  if (queryStart > before.length) return undefined
  const query = before.slice(queryStart)
  if (
    query.length > maxProjectFileSearchQueryBytes ||
    query.includes('"') ||
    Buffer.byteLength(query) > maxProjectFileSearchQueryBytes
  ) {
    return undefined
  }
  try {
    validateProjectFileSearchQuery(query)
  } catch {
    return undefined
  }

  let tokenSuffix: string
  if (quoted) {
    const closingQuote = input.afterCursor.indexOf('"')
    if (closingQuote === -1 && input.afterTruncated) return undefined
    tokenSuffix = closingQuote === -1 ? input.afterCursor : input.afterCursor.slice(0, closingQuote + 1)
  } else {
    const delimiter = input.afterCursor.search(/[\s,;]/u)
    if (delimiter === -1 && input.afterTruncated) return undefined
    tokenSuffix = delimiter === -1 ? input.afterCursor : input.afterCursor.slice(0, delimiter)
  }

  const triggerWidth = promptTextWidth(before.slice(triggerIndex))
  return Object.freeze({
    triggerStart: input.cursorOffset - triggerWidth,
    tokenEnd: input.cursorOffset + promptTextWidth(tokenSuffix),
    cursorOffset: input.cursorOffset,
    query,
    quoted
  })
}

export function formatFileReference(
  match: ProjectFileMatch,
  context: FileCompletionContext,
  followingText: string
): { readonly replacement: string; readonly cursorAfterTrigger: number } {
  const path = match.type === "directory" ? `${match.path}/` : match.path
  const quoted = context.quoted || /[\s,;]/u.test(path)
  const reference = quoted ? `@"${path}"` : `@${path}`
  if (match.type === "directory") {
    return {
      replacement: reference,
      cursorAfterTrigger: quoted ? promptTextWidth(reference) - 1 : promptTextWidth(reference)
    }
  }

  if (!followingText) {
    const replacement = `${reference} `
    return { replacement, cursorAfterTrigger: promptTextWidth(replacement) }
  }
  if (/^[ \t]/u.test(followingText)) {
    return {
      replacement: reference,
      cursorAfterTrigger: promptTextWidth(reference) + promptTextWidth(followingText[0]!)
    }
  }
  return { replacement: reference, cursorAfterTrigger: promptTextWidth(reference) }
}

export function fileCompletionCandidateId(match: ProjectFileMatch): string {
  return `${match.type}:${match.path}`
}

function previousCodePoint(text: string, index: number): string | undefined {
  if (index === 0) return undefined
  const trailing = text.charCodeAt(index - 1)
  if (trailing >= 0xdc00 && trailing <= 0xdfff && index > 1) {
    const leading = text.charCodeAt(index - 2)
    if (leading >= 0xd800 && leading <= 0xdbff) return text.slice(index - 2, index)
  }
  return text[index - 1]
}

function sameFileCompletionContext(left: FileCompletionContext, right: FileCompletionContext): boolean {
  return (
    left.triggerStart === right.triggerStart &&
    left.tokenEnd === right.tokenEnd &&
    left.cursorOffset === right.cursorOffset &&
    left.query === right.query &&
    left.quoted === right.quoted
  )
}

function sameRequest(left: PendingFileCompletion, right: PendingFileCompletion): boolean {
  return left.operationId === right.operationId && left.session === right.session
}

function sameRequestContext(left: PendingFileCompletion, right: PendingFileCompletion | undefined): boolean {
  return (
    right !== undefined &&
    left.session === right.session &&
    left.draftRevision === right.draftRevision &&
    sameFileCompletionContext(left.context, right.context)
  )
}

function deferred(): { readonly promise: Promise<void>; readonly resolve: () => void } {
  let resolve!: () => void
  const promise = new Promise<void>(settle => {
    resolve = settle
  })
  return { promise, resolve }
}

function assertNever(value: never): never {
  throw new Error(`Unknown file completion state: ${String(value)}`)
}

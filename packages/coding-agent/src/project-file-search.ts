import { spawn, type ChildProcess } from "node:child_process"
import { opendir, open, stat } from "node:fs/promises"
import { isAbsolute, join } from "node:path"

import ignore, { type Ignore } from "ignore"

import type { OpenZiPaths } from "./paths.js"

export const maxProjectFileSearchResults = 20
export const maxProjectFileSearchQueryBytes = 4 * 1024
export const maxProjectFileSearchPathBytes = 16 * 1024
export const maxProjectFileSearchEntries = 100_000
export const maxProjectFileSearchOutputBytes = 16 * 1024 * 1024
export const maxProjectFileSearchDirectories = 16_384
export const maxProjectFileSearchQueuedPathBytes = 4 * 1024 * 1024
export const maxProjectFileSearchDirectoryEntries = 4_096
export const maxProjectFileSearchDepth = 64
export const maxProjectFileSearchIgnoreBytes = 4 * 1024 * 1024
export const maxProjectFileSearchSymlinkStats = 64
export const maxProjectFileSearchDurationMs = 2_000
export const maxProjectFileSearchSettlementMs = 250

export interface ProjectFileMatch {
  /** Slash-normalized path relative to OpenZiPaths.cwd, without @ or quotes. */
  readonly path: string
  readonly type: "file" | "directory"
}

export interface ProjectFileSearchResult {
  readonly matches: readonly ProjectFileMatch[]
  readonly truncated: boolean
}

type ProjectFileSearchBackend = "unknown" | "git" | "walk"

type ProjectFileSearchState =
  | { readonly type: "idle"; readonly backend: ProjectFileSearchBackend }
  | {
      readonly type: "searching"
      readonly backend: ProjectFileSearchBackend
      readonly operationId: number
      readonly controller: AbortController
      readonly settled: Promise<void>
    }
  | { readonly type: "disposed"; readonly settled: Promise<void> }

interface RankedMatch extends ProjectFileMatch {
  readonly rank: readonly [number, number, number, number, number, number]
}

interface SearchSourceResult {
  readonly accumulator: MatchAccumulator
  readonly truncated: boolean
}

interface IgnoreScope {
  readonly directory: string
  readonly matcher: Ignore
  readonly parent: IgnoreScope | undefined
}

interface IgnoreAdmission {
  readonly bytes: number
  readonly truncated: boolean
  readonly scope: IgnoreScope | undefined
}

interface WalkDirectory {
  readonly path: string
  readonly depth: number
  readonly ignoreScope: IgnoreScope | undefined
}

const strictUtf8 = new TextDecoder("utf-8", { fatal: true })
const deadlineReason = Symbol("project-file-search-deadline")
const disposeReason = Symbol("project-file-search-dispose")
const invalidPathCharacters = /[\p{Cc}\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069\ufffd"]/u
const windowsDrivePath = /^[a-zA-Z]:/

export class ProjectFileSearch {
  readonly #cwd: string
  #state: ProjectFileSearchState = { type: "idle", backend: "unknown" }
  #nextOperationId = 0

  constructor(paths: OpenZiPaths) {
    this.#cwd = paths.cwd
  }

  search(query: string, signal: AbortSignal): Promise<ProjectFileSearchResult> {
    const normalizedQuery = validateProjectFileSearchQuery(query)
    if (signal.aborted) return Promise.reject(abortError())
    if (this.#state.type === "disposed") return Promise.reject(new Error("ProjectFileSearch is disposed"))
    if (this.#state.type === "searching") {
      return Promise.reject(new Error("ProjectFileSearch already has an active operation"))
    }

    const backend = this.#state.backend
    const operationId = ++this.#nextOperationId
    const controller = new AbortController()
    const settlement = deferred()
    this.#state = { type: "searching", backend, operationId, controller, settled: settlement.promise }
    const abort = () => controller.abort(signal.reason)
    signal.addEventListener("abort", abort, { once: true })
    const deadline = setTimeout(() => controller.abort(deadlineReason), maxProjectFileSearchDurationMs)

    return this.#run(normalizedQuery, backend, controller.signal)
      .then(result => Object.freeze({ matches: Object.freeze(result.matches), truncated: result.truncated }))
      .finally(() => {
        clearTimeout(deadline)
        signal.removeEventListener("abort", abort)
        if (this.#state.type === "searching" && this.#state.operationId === operationId) {
          this.#state = { type: "idle", backend: this.#state.backend }
        }
        settlement.resolve()
      })
  }

  waitForIdle(): Promise<void> {
    return this.#state.type === "idle" ? Promise.resolve() : this.#state.settled
  }

  dispose(): Promise<void> {
    const state = this.#state
    if (state.type === "disposed") return state.settled
    if (state.type === "idle") {
      const settled = Promise.resolve()
      this.#state = { type: "disposed", settled }
      return settled
    }
    state.controller.abort(disposeReason)
    const settled = settleWithin(state.settled, maxProjectFileSearchSettlementMs)
    this.#state = { type: "disposed", settled }
    return settled
  }

  async #run(query: string, backend: ProjectFileSearchBackend, signal: AbortSignal): Promise<ProjectFileSearchResult> {
    if (backend !== "walk") {
      try {
        const source = await searchGit(this.#cwd, query, signal)
        this.#setBackend("git")
        return resultFromSource(source)
      } catch (cause) {
        throwIfCancelled(signal)
        if (!(cause instanceof GitUnavailableError)) throw cause
        this.#setBackend("walk")
      }
    }

    const source = await searchWalk(this.#cwd, query, signal)
    return resultFromSource(source)
  }

  #setBackend(backend: Exclude<ProjectFileSearchBackend, "unknown">): void {
    if (this.#state.type === "searching") this.#state = { ...this.#state, backend }
  }
}

export function validateProjectFileSearchQuery(query: string): string {
  if (Buffer.byteLength(query) > maxProjectFileSearchQueryBytes) {
    throw new ProjectFileSearchQueryError("Project file search query is too long")
  }
  if (
    isAbsolute(query) ||
    windowsDrivePath.test(query) ||
    query.startsWith("\\") ||
    query === "~" ||
    query.startsWith("~/") ||
    query.startsWith("~\\")
  ) {
    throw new ProjectFileSearchQueryError("Project file search query must be project-relative")
  }
  if (hasControlCharacter(query)) {
    throw new ProjectFileSearchQueryError("Project file search query contains a control character")
  }

  const normalized = query.startsWith("./") ? query.slice(2) : query
  if (normalized.split(/[\\/]/u).some(segment => segment === "..")) {
    throw new ProjectFileSearchQueryError("Project file search query cannot traverse parent directories")
  }
  return normalized.replaceAll("\\", "/")
}

export class ProjectFileSearchQueryError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ProjectFileSearchQueryError"
  }
}

class GitUnavailableError extends Error {}

class MatchAccumulator {
  readonly #query: string
  readonly #matches = new Map<string, RankedMatch>()

  constructor(query: string) {
    this.#query = query
  }

  add(path: string, type: ProjectFileMatch["type"]): void {
    const ranked = rankMatch(path, type, this.#query)
    if (!ranked) return
    const key = `${type}:${path}`
    const previous = this.#matches.get(key)
    if (previous) return
    this.#matches.set(key, ranked)
    if (this.#matches.size <= maxProjectFileSearchResults) return

    const worst = [...this.#matches].toSorted((left, right) => compareRank(right[1], left[1]))[0]
    if (worst) this.#matches.delete(worst[0])
  }

  result(): readonly ProjectFileMatch[] {
    return [...this.#matches.values()]
      .toSorted(compareRank)
      .map(match => Object.freeze({ path: match.path, type: match.type }))
  }
}

async function searchGit(cwd: string, query: string, signal: AbortSignal): Promise<SearchSourceResult> {
  const accumulator = new MatchAccumulator(query)
  let child: ChildProcess
  try {
    child = spawn("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true
    })
  } catch (cause) {
    throw new GitUnavailableError(String(cause))
  }

  let outputBytes = 0
  let entries = 0
  let pending: Buffer = Buffer.alloc(0)
  let truncated = false
  let spawnFailure: unknown
  const stop = () => stopChild(child)
  signal.addEventListener("abort", stop, { once: true })
  child.stderr?.resume()
  child.once("error", cause => {
    spawnFailure = cause
  })

  child.stdout?.on("data", (chunk: Buffer) => {
    if (signal.aborted || truncated) return
    outputBytes += chunk.byteLength
    if (outputBytes > maxProjectFileSearchOutputBytes) {
      truncated = true
      stopChild(child)
      return
    }
    pending = pending.length === 0 ? chunk : Buffer.concat([pending, chunk])
    let delimiter = pending.indexOf(0)
    while (delimiter !== -1) {
      entries++
      if (entries > maxProjectFileSearchEntries) {
        truncated = true
        stopChild(child)
        return
      }
      admitGitPath(pending.subarray(0, delimiter), query, accumulator)
      pending = pending.subarray(delimiter + 1)
      delimiter = pending.indexOf(0)
    }
    if (pending.byteLength > maxProjectFileSearchPathBytes) {
      truncated = true
      stopChild(child)
    }
  })

  const exit = await childExit(child)
  signal.removeEventListener("abort", stop)
  if (signal.aborted && signal.reason !== deadlineReason) throw abortError()
  if (signal.reason === deadlineReason) truncated = true
  if (spawnFailure || (!truncated && exit.code !== 0)) throw new GitUnavailableError("Git file enumeration failed")
  return { accumulator, truncated }
}

function admitGitPath(bytes: Uint8Array, query: string, accumulator: MatchAccumulator): void {
  if (bytes.byteLength === 0 || bytes.byteLength > maxProjectFileSearchPathBytes) return
  let path: string
  try {
    path = strictUtf8.decode(bytes)
  } catch {
    return
  }
  const normalized = validProjectPath(path)
  if (!normalized) return
  accumulator.add(normalized, "file")
  const parts = normalized.split("/")
  parts.pop()
  while (parts.length > 0) {
    const directory = parts.join("/")
    if (!(query.endsWith("/") && directory.toLowerCase() === query.slice(0, -1).toLowerCase())) {
      accumulator.add(directory, "directory")
    }
    parts.pop()
  }
}

async function searchWalk(cwd: string, query: string, signal: AbortSignal): Promise<SearchSourceResult> {
  const accumulator = new MatchAccumulator(query)
  const queue: Array<WalkDirectory | undefined> = [{ path: "", depth: 0, ignoreScope: undefined }]
  let queueIndex = 0
  let queuedBytes = 0
  let entries = 0
  let directories = 0
  let ignoreBytes = 0
  let symlinkStats = 0
  let truncated = false

  while (queueIndex < queue.length) {
    if (signal.aborted) {
      if (signal.reason === deadlineReason) {
        truncated = true
        break
      }
      throw abortError()
    }
    const current = queue[queueIndex]!
    queue[queueIndex++] = undefined
    queuedBytes -= Buffer.byteLength(current.path)
    directories++
    if (directories > maxProjectFileSearchDirectories) {
      truncated = true
      break
    }

    // Ignore inheritance and breadth-first admission make this traversal intentionally sequential.
    // oxlint-disable-next-line no-await-in-loop
    const ignoreAdmission = await loadIgnoreScope(cwd, current.path, current.ignoreScope, ignoreBytes)
    ignoreBytes = ignoreAdmission.bytes
    if (ignoreAdmission.truncated) {
      truncated = true
      continue
    }

    let directory
    try {
      // oxlint-disable-next-line no-await-in-loop
      directory = await opendir(join(cwd, ...splitProjectPath(current.path)))
    } catch {
      continue
    }
    const admitted = []
    // oxlint-disable-next-line no-await-in-loop
    for await (const entry of directory) {
      if (admitted.length === maxProjectFileSearchDirectoryEntries) {
        truncated = true
        break
      }
      admitted.push(entry)
    }
    admitted.sort((left, right) => compareCodePoints(left.name, right.name))

    for (const entry of admitted) {
      if (signal.aborted) {
        if (signal.reason === deadlineReason) {
          truncated = true
          break
        }
        throw abortError()
      }
      entries++
      if (entries > maxProjectFileSearchEntries) {
        truncated = true
        break
      }
      if (entry.name === ".git") continue
      const path = current.path ? `${current.path}/${entry.name}` : entry.name
      const normalized = validProjectPath(path)
      if (!normalized) continue

      let type: ProjectFileMatch["type"] | undefined
      let traversable = false
      if (entry.isDirectory()) {
        type = "directory"
        traversable = true
      } else if (entry.isFile()) {
        type = "file"
      } else if (entry.isSymbolicLink() && symlinkStats < maxProjectFileSearchSymlinkStats) {
        symlinkStats++
        try {
          // oxlint-disable-next-line no-await-in-loop
          const target = await stat(join(cwd, ...splitProjectPath(normalized)))
          type = target.isDirectory() ? "directory" : target.isFile() ? "file" : undefined
        } catch {
          type = undefined
        }
      }
      if (!type || isIgnored(ignoreAdmission.scope, normalized, type === "directory")) continue
      if (
        !(type === "directory" && query.endsWith("/") && normalized.toLowerCase() === query.slice(0, -1).toLowerCase())
      ) {
        accumulator.add(normalized, type)
      }

      if (traversable) {
        const nextDepth = current.depth + 1
        const bytes = Buffer.byteLength(normalized)
        if (
          nextDepth > maxProjectFileSearchDepth ||
          queue.length - queueIndex >= maxProjectFileSearchDirectories ||
          bytes > maxProjectFileSearchQueuedPathBytes - queuedBytes
        ) {
          truncated = true
        } else {
          queue.push({ path: normalized, depth: nextDepth, ignoreScope: ignoreAdmission.scope })
          queuedBytes += bytes
        }
      }
      // oxlint-disable-next-line no-await-in-loop
      if (entries % 128 === 0) await new Promise<void>(resolve => setImmediate(resolve))
    }
    if (entries > maxProjectFileSearchEntries) break
  }

  if (signal.aborted && signal.reason !== deadlineReason) throw abortError()
  if (signal.reason === deadlineReason) truncated = true
  return { accumulator, truncated }
}

async function loadIgnoreScope(
  cwd: string,
  directory: string,
  parent: IgnoreScope | undefined,
  used: number
): Promise<IgnoreAdmission> {
  const path = join(cwd, ...splitProjectPath(directory), ".gitignore")
  let file
  try {
    file = await open(path, "r")
  } catch (cause) {
    return missingPath(cause)
      ? { bytes: used, truncated: false, scope: parent }
      : { bytes: used, truncated: true, scope: parent }
  }
  try {
    const remaining = maxProjectFileSearchIgnoreBytes - used
    const fileInfo = await file.stat()
    if (fileInfo.size > remaining) return { bytes: used, truncated: true, scope: parent }
    const buffer = Buffer.allocUnsafe(fileInfo.size)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      // oxlint-disable-next-line no-await-in-loop
      const read = await file.read(buffer, bytesRead, buffer.length - bytesRead, bytesRead)
      if (read.bytesRead === 0) break
      bytesRead += read.bytesRead
    }
    let text: string
    try {
      text = strictUtf8.decode(buffer.subarray(0, bytesRead))
    } catch {
      return { bytes: used + bytesRead, truncated: true, scope: parent }
    }
    const matcher = ignore().add(text)
    return { bytes: used + bytesRead, truncated: false, scope: { directory, matcher, parent } }
  } finally {
    await file.close()
  }
}

function isIgnored(scope: IgnoreScope | undefined, path: string, directory: boolean): boolean {
  if (!scope) return false
  let ignored = isIgnored(scope.parent, path, directory)
  const relativePath = scope.directory ? path.slice(scope.directory.length + 1) : path
  const result = scope.matcher.test(directory ? `${relativePath}/` : relativePath)
  if (result.ignored) ignored = true
  else if (result.unignored) ignored = false
  return ignored
}

function missingPath(cause: unknown): boolean {
  if (typeof cause !== "object" || cause === null || !("code" in cause)) return false
  return cause.code === "ENOENT" || cause.code === "ENOTDIR"
}

function validProjectPath(path: string): string | undefined {
  if (path.includes("\\")) return undefined
  const normalized = path.replace(/^\.\//u, "")
  if (
    !normalized ||
    normalized.endsWith("/") ||
    normalized.startsWith("/") ||
    normalized.startsWith("//") ||
    windowsDrivePath.test(normalized) ||
    isAbsolute(normalized) ||
    Buffer.byteLength(normalized) > maxProjectFileSearchPathBytes ||
    invalidPathCharacters.test(normalized)
  ) {
    return undefined
  }
  const segments = normalized.split("/")
  if (segments.some(segment => !segment || segment === "." || segment === ".." || segment === ".git")) return undefined
  return normalized
}

function rankMatch(path: string, type: ProjectFileMatch["type"], query: string): RankedMatch | undefined {
  const candidate = path.toLowerCase()
  const needle = query.toLowerCase().replace(/^\.\//u, "").replace(/\/+$/u, "")
  const basename = candidate.slice(candidate.lastIndexOf("/") + 1)
  const depth = candidate.split("/").length - 1
  let matchClass: number
  let gap = 0
  let start = 0

  if (!needle) {
    matchClass = 0
  } else if (candidate === needle) {
    matchClass = 0
  } else if (basename === needle) {
    matchClass = 1
  } else if (basename.startsWith(needle)) {
    matchClass = 2
  } else {
    const segmentMatch = orderedSegmentPrefix(candidate, needle)
    if (segmentMatch) {
      matchClass = 3
      gap = segmentMatch.gap
      start = segmentMatch.start
    } else {
      if (needle.includes("/")) return undefined
      const basenameMatch = fuzzySubsequence(basename, needle)
      if (basenameMatch) {
        matchClass = 4
        gap = basenameMatch.gap
        start = basenameMatch.start
      } else {
        const pathMatch = fuzzySubsequence(candidate, needle.replaceAll("/", ""))
        if (!pathMatch) return undefined
        matchClass = 5
        gap = pathMatch.gap
        start = pathMatch.start
      }
    }
  }

  return { path, type, rank: [matchClass, gap, start, depth, type === "directory" ? 0 : 1, codePointLength(path)] }
}

function orderedSegmentPrefix(
  path: string,
  query: string
): { readonly gap: number; readonly start: number } | undefined {
  const pathSegments = path.split("/")
  const querySegments = query.split("/").filter(Boolean)
  let pathIndex = 0
  let first = -1
  let gap = 0
  for (const segment of querySegments) {
    while (pathIndex < pathSegments.length && !pathSegments[pathIndex]!.startsWith(segment)) {
      pathIndex++
      gap++
    }
    if (pathIndex === pathSegments.length) return undefined
    if (first === -1) first = pathIndex
    gap += pathSegments[pathIndex]!.length - segment.length
    pathIndex++
  }
  return { gap, start: first }
}

function fuzzySubsequence(value: string, query: string): { readonly gap: number; readonly start: number } | undefined {
  let queryIndex = 0
  let first = -1
  let previous = -1
  let gap = 0
  for (let index = 0; index < value.length && queryIndex < query.length; index++) {
    if (value[index] !== query[queryIndex]) continue
    if (first === -1) first = index
    if (previous !== -1) gap += index - previous - 1
    previous = index
    queryIndex++
  }
  return queryIndex === query.length ? { gap, start: first } : undefined
}

function compareRank(left: RankedMatch, right: RankedMatch): number {
  for (let index = 0; index < left.rank.length; index++) {
    const difference = left.rank[index]! - right.rank[index]!
    if (difference !== 0) return difference
  }
  return compareCodePoints(left.path, right.path)
}

function compareCodePoints(left: string, right: string): number {
  let leftIndex = 0
  let rightIndex = 0
  while (leftIndex < left.length && rightIndex < right.length) {
    const leftPoint = left.codePointAt(leftIndex)!
    const rightPoint = right.codePointAt(rightIndex)!
    if (leftPoint !== rightPoint) return leftPoint - rightPoint
    leftIndex += leftPoint > 0xffff ? 2 : 1
    rightIndex += rightPoint > 0xffff ? 2 : 1
  }
  return left.length - right.length
}

function codePointLength(value: string): number {
  let length = 0
  for (let index = 0; index < value.length; length++) {
    const point = value.codePointAt(index)!
    index += point > 0xffff ? 2 : 1
  }
  return length
}

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length;) {
    const point = value.codePointAt(index)!
    if (point <= 0x1f || (point >= 0x7f && point <= 0x9f)) return true
    index += point > 0xffff ? 2 : 1
  }
  return false
}

function resultFromSource(source: SearchSourceResult): ProjectFileSearchResult {
  return { matches: source.accumulator.result(), truncated: source.truncated }
}

function splitProjectPath(path: string): string[] {
  return path ? path.split("/") : []
}

function throwIfCancelled(signal: AbortSignal): void {
  if (!signal.aborted) return
  if (signal.reason === deadlineReason) return
  throw abortError()
}

function abortError(): Error {
  const error = new Error("Project file search aborted")
  error.name = "AbortError"
  return error
}

function stopChild(child: ChildProcess): void {
  if (child.exitCode !== null || child.signalCode !== null) return
  child.kill("SIGKILL")
}

function childExit(
  child: ChildProcess
): Promise<{ readonly code: number | null; readonly signal: NodeJS.Signals | null }> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise(resolve => child.once("close", (code, signal) => resolve({ code, signal })))
}

function deferred(): { readonly promise: Promise<void>; resolve(): void } {
  let resolve!: () => void
  const promise = new Promise<void>(settle => {
    resolve = settle
  })
  return { promise, resolve }
}

async function settleWithin(settled: Promise<void>, milliseconds: number): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined
  await Promise.race([
    settled,
    new Promise<void>(resolve => {
      timer = setTimeout(resolve, milliseconds)
    })
  ])
  if (timer) clearTimeout(timer)
}

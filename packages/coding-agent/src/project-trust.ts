import {
  chmodSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync
} from "node:fs"
import { basename, dirname, isAbsolute, join, resolve } from "node:path"

import lockfile from "proper-lockfile"

import type { ZiPaths } from "./paths.js"

export const maxProjectTrustFileBytes = 1024 * 1024
export const maxProjectTrustDecisions = 1024
export const maxProjectTrustPathBytes = 4096

export type ProjectConfigurationAdmission = "trusted" | "untrusted" | "absent"

export type ProjectTrustDecision =
  | { readonly type: "trusted"; readonly cwd: string; readonly source: "interactive" | "runtime" }
  | { readonly type: "untrusted"; readonly cwd: string; readonly source: "interactive" | "runtime" }

export interface ProjectTrustDiagnostic {
  readonly cwd: string
  readonly path: string
  readonly message: string
}

export type ProjectTrustResolution =
  | {
      readonly type: "not_required"
      readonly cwd: string
      readonly reason: "no_project_configuration" | "project_configuration_is_global"
      readonly diagnostic?: never
    }
  | { readonly type: "unresolved"; readonly cwd: string; readonly diagnostic: ProjectTrustDiagnostic }
  | {
      readonly type: "trusted"
      readonly cwd: string
      readonly source: "stored" | "interactive" | "runtime"
      readonly savedCwd?: string
      readonly diagnostic?: never
    }
  | {
      readonly type: "untrusted"
      readonly cwd: string
      readonly source: "stored" | "interactive" | "runtime"
      readonly savedCwd?: string
      readonly diagnostic?: ProjectTrustDiagnostic
    }

export type StoredProjectTrust =
  | { readonly type: "unresolved"; readonly cwd: string }
  | { readonly type: "trusted"; readonly cwd: string; readonly savedCwd: string }
  | { readonly type: "untrusted"; readonly cwd: string; readonly savedCwd: string }

export type ProjectTrustUpdate =
  | { readonly type: "trusted"; readonly cwd: string }
  | { readonly type: "untrusted"; readonly cwd: string }
  | { readonly type: "removed"; readonly cwd: string }

/** Owns bounded global persistence of canonical cwd trust decisions. */
export class ProjectTrustStore {
  readonly #path: string

  constructor(paths: ZiPaths) {
    this.#path = paths.trustFile
  }

  async lookup(cwd: string): Promise<StoredProjectTrust> {
    const canonicalCwd = canonicalProjectPath(cwd)
    if (!existsSync(this.#path)) return { type: "unresolved", cwd: canonicalCwd }
    const decisions = readTrustFile(this.#path)
    let candidate = canonicalCwd
    while (true) {
      const trusted = decisions[candidate]
      if (trusted !== undefined) {
        return { type: trusted ? "trusted" : "untrusted", cwd: canonicalCwd, savedCwd: candidate }
      }
      const parent = dirname(candidate)
      if (parent === candidate) return { type: "unresolved", cwd: canonicalCwd }
      candidate = parent
    }
  }

  async update(updates: readonly ProjectTrustUpdate[]): Promise<void> {
    if (updates.length === 0) return
    if (updates.length > maxProjectTrustDecisions) {
      throw new Error(`Project trust updates cannot exceed ${maxProjectTrustDecisions} decisions`)
    }
    const admitted = updates.map(update => Object.freeze({ ...update, cwd: canonicalProjectPath(update.cwd) }))
    this.#ensureFile()
    const release = await lockfile.lock(this.#path, {
      realpath: false,
      retries: { retries: 10, factor: 2, minTimeout: 20, maxTimeout: 500, randomize: true },
      stale: 30_000
    })
    try {
      const decisions = readTrustFile(this.#path)
      for (const update of admitted) {
        if (update.type === "removed") delete decisions[update.cwd]
        else decisions[update.cwd] = update.type === "trusted"
      }
      validateDecisionCount(decisions, this.#path)
      writeTrustFile(this.#path, decisions)
    } finally {
      await release()
    }
  }

  #ensureFile(): void {
    mkdirSync(dirname(this.#path), { recursive: true, mode: 0o700 })
    if (existsSync(this.#path)) return
    try {
      writeFileSync(this.#path, "{}\n", { encoding: "utf8", flag: "wx", mode: 0o600 })
    } catch (error) {
      if (!hasCode(error, "EEXIST")) throw error
    }
  }
}

export async function resolveProjectTrust(
  paths: ZiPaths,
  decision?: ProjectTrustDecision
): Promise<ProjectTrustResolution> {
  const cwd = canonicalProjectPath(paths.cwd)
  if (decision !== undefined) {
    validateProjectTrustDecision(decision)
    const decisionCwd = canonicalProjectPath(decision.cwd)
    if (decisionCwd !== cwd) {
      throw new Error(`Project trust decision for ${decisionCwd} does not match runtime cwd ${cwd}`)
    }
  }
  if (paths.projectConfigIsGlobal) {
    return Object.freeze({ type: "not_required", cwd, reason: "project_configuration_is_global" })
  }

  const hasProjectConfiguration = hasTrustRequiringProjectConfiguration(paths)
  if (decision !== undefined) {
    if (decision.type === "trusted") {
      return Object.freeze({ type: "trusted", cwd, source: decision.source })
    }
    return Object.freeze({
      type: "untrusted",
      cwd,
      source: decision.source,
      ...(hasProjectConfiguration ? { diagnostic: untrustedDiagnostic(paths, cwd) } : {})
    })
  }

  let stored: StoredProjectTrust
  try {
    stored = await new ProjectTrustStore(paths).lookup(cwd)
  } catch (cause) {
    const diagnostic = Object.freeze({
      cwd,
      path: paths.trustFile,
      message: `Project configuration was ignored because project trust could not be read: ${errorMessage(cause)}`
    })
    return Object.freeze({ type: "unresolved", cwd, diagnostic })
  }

  if (stored.type === "trusted") {
    return Object.freeze({ type: "trusted", cwd, source: "stored", savedCwd: stored.savedCwd })
  }
  if (stored.type === "untrusted") {
    return Object.freeze({
      type: "untrusted",
      cwd,
      source: "stored",
      savedCwd: stored.savedCwd,
      ...(hasProjectConfiguration ? { diagnostic: untrustedDiagnostic(paths, cwd) } : {})
    })
  }
  if (!hasProjectConfiguration) {
    return Object.freeze({ type: "not_required", cwd, reason: "no_project_configuration" })
  }
  return Object.freeze({ type: "unresolved", cwd, diagnostic: unresolvedDiagnostic(paths, cwd) })
}

export function projectConfigurationAdmission(trust: ProjectTrustResolution): ProjectConfigurationAdmission {
  if (trust.type === "trusted") return "trusted"
  if (trust.type === "not_required") {
    return trust.reason === "project_configuration_is_global" ? "trusted" : "absent"
  }
  return "untrusted"
}

export function hasTrustRequiringProjectConfiguration(paths: ZiPaths): boolean {
  if (paths.projectConfigIsGlobal) return false
  return [
    paths.projectSettingsFile,
    paths.projectSystemPromptFile,
    paths.projectAppendSystemPromptFile,
    paths.projectResourceDir("extensions"),
    paths.projectResourceDir("skills"),
    paths.projectResourceDir("prompts"),
    paths.projectResourceDir("themes")
  ].some(existsSync)
}

function validateProjectTrustDecision(decision: unknown): asserts decision is ProjectTrustDecision {
  if (!isRecord(decision)) throw new Error("Project trust decisions must be objects")
  if (decision.type !== "trusted" && decision.type !== "untrusted") {
    throw new Error(`Unknown project trust decision: ${String(decision.type)}`)
  }
  if (typeof decision.cwd !== "string") throw new Error("Project trust decisions require a cwd")
  if (decision.source !== "interactive" && decision.source !== "runtime") {
    throw new Error(`Unknown project trust decision source: ${String(decision.source)}`)
  }
}

function untrustedDiagnostic(paths: ZiPaths, cwd: string): ProjectTrustDiagnostic {
  return Object.freeze({
    cwd,
    path: paths.projectDir,
    message: `Project configuration is not trusted and was ignored: ${paths.projectDir}`
  })
}

function unresolvedDiagnostic(paths: ZiPaths, cwd: string): ProjectTrustDiagnostic {
  return Object.freeze({
    cwd,
    path: paths.projectDir,
    message: `Project configuration trust is unresolved and was ignored: ${paths.projectDir}`
  })
}

function canonicalProjectPath(path: string): string {
  if (!isAbsolute(path)) throw new Error("Project trust paths must be absolute")
  const absolute = resolve(path)
  let canonical: string
  try {
    canonical = realpathSync.native(absolute)
  } catch {
    canonical = absolute
  }
  if (Buffer.byteLength(canonical) > maxProjectTrustPathBytes) {
    throw new Error(`Project trust paths cannot exceed ${maxProjectTrustPathBytes} bytes`)
  }
  return canonical
}

function readTrustFile(path: string): Record<string, boolean> {
  let value: unknown
  try {
    value = JSON.parse(readBoundedFile(path))
  } catch (error) {
    const detail = error instanceof Error ? `: ${error.message}` : ""
    throw new Error(`Could not read project trust ${path}${detail}`, { cause: error })
  }
  if (!isRecord(value)) throw new Error(`Invalid project trust object: ${path}`)
  validateDecisionCount(value, path)

  const decisions: Record<string, boolean> = {}
  for (const [cwd, trusted] of Object.entries(value)) {
    if (!isAbsolute(cwd) || Buffer.byteLength(cwd) > maxProjectTrustPathBytes || resolve(cwd) !== cwd) {
      throw new Error(`Project trust keys must be absolute normalized paths: ${path}`)
    }
    if (typeof trusted !== "boolean") throw new Error(`Invalid project trust decision for ${cwd}: ${path}`)
    decisions[cwd] = trusted
  }
  return decisions
}

function validateDecisionCount(decisions: Record<string, unknown>, path: string): void {
  if (Object.keys(decisions).length > maxProjectTrustDecisions) {
    throw new Error(`Project trust files cannot contain more than ${maxProjectTrustDecisions} decisions: ${path}`)
  }
}

function readBoundedFile(path: string): string {
  const file = openSync(path, "r")
  try {
    const buffer = Buffer.allocUnsafe(maxProjectTrustFileBytes + 1)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      const count = readSync(file, buffer, bytesRead, buffer.length - bytesRead, null)
      if (count === 0) break
      bytesRead += count
    }
    if (bytesRead > maxProjectTrustFileBytes) {
      throw new Error(`Project trust files cannot exceed ${maxProjectTrustFileBytes} bytes: ${path}`)
    }
    return buffer.toString("utf8", 0, bytesRead)
  } finally {
    closeSync(file)
  }
}

function writeTrustFile(path: string, decisions: Record<string, boolean>): void {
  const sorted = Object.fromEntries(Object.entries(decisions).toSorted(([left], [right]) => left.localeCompare(right)))
  const serialized = `${JSON.stringify(sorted, null, 2)}\n`
  if (Buffer.byteLength(serialized) > maxProjectTrustFileBytes) {
    throw new Error(`Project trust files cannot exceed ${maxProjectTrustFileBytes} bytes: ${path}`)
  }
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`)
  try {
    writeFileSync(temporary, serialized, { encoding: "utf8", mode: 0o600 })
    renameSync(temporary, path)
    chmodSync(path, 0o600)
  } finally {
    if (existsSync(temporary)) unlinkSync(temporary)
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function hasCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

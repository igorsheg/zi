import { createHash } from "node:crypto"
import { closeSync, openSync, statSync } from "node:fs"
import { isAbsolute, join, resolve } from "node:path"

import type { ZiPaths } from "../paths.js"
import type { ProjectConfigurationAdmission } from "../project-trust.js"
import { canonicalResourcePath, readResourceDirectory } from "../resource-files.js"
import { resolveResourceRoots } from "../resource-roots.js"
import type { SettingsManager } from "../settings-manager.js"
import type { ExtensionDiagnostic } from "./protocol.js"

export const maxExtensionSources = 128
export const maxExplicitExtensionPaths = 128
export const maxExtensionPathBytes = 4096
export const maxExtensionDiscoveryDiagnostics = 256

export interface ExtensionSource {
  readonly id: string
  readonly declaredPath: string
  readonly entryPath: string
  readonly scope: "global" | "project" | "temporary"
  readonly origin: "directory" | "settings" | "package" | "cli"
}

export interface ExtensionLoadPlan {
  readonly cwd: string
  readonly sources: readonly ExtensionSource[]
}

export interface ExtensionDiscoveryDiagnostic {
  readonly type: "missing" | "unreadable" | "unsupported" | "duplicate" | "limit"
  readonly path: string
  readonly message: string
  readonly omitted?: number
}

export interface ExtensionDiscoveryResult {
  readonly plan: ExtensionLoadPlan
  readonly diagnostics: readonly ExtensionDiscoveryDiagnostic[]
  readonly omittedDiagnostics: number
}

interface SourceCandidate {
  readonly declaredPath: string
  readonly entryPath: string
  readonly scope: ExtensionSource["scope"]
  readonly origin: ExtensionSource["origin"]
}

class Discovery {
  readonly #sources: ExtensionSource[] = []
  readonly #seen = new Set<string>()
  readonly #diagnostics: ExtensionDiscoveryDiagnostic[] = []
  #omittedDiagnostics = 0

  constructor(
    readonly paths: ZiPaths,
    readonly settings: SettingsManager | undefined
  ) {}

  run(project: ProjectConfigurationAdmission, explicitPaths: readonly string[]): ExtensionDiscoveryResult {
    if (project !== "trusted" && project !== "untrusted" && project !== "absent") {
      throw new Error(`Unknown project extension admission: ${String(project)}`)
    }

    const admittedExplicit = explicitPaths.slice(0, maxExplicitExtensionPaths)
    for (const path of admittedExplicit) this.#discoverExplicit(path)
    if (explicitPaths.length > admittedExplicit.length) {
      this.#diagnose({
        type: "limit",
        path: this.paths.cwd,
        message: `Explicit extension paths cannot exceed ${maxExplicitExtensionPaths}`,
        omitted: explicitPaths.length - admittedExplicit.length
      })
    }

    for (const root of resolveResourceRoots(this.paths, this.settings, project, "extensions")) {
      if (root.source === "settings") this.#discoverConfigured(root.path, root.scope)
      else this.#discoverDirectory(root.path, root.scope, "directory")
    }

    const sources = Object.freeze([...this.#sources])
    return Object.freeze({
      plan: Object.freeze({ cwd: this.paths.cwd, sources }),
      diagnostics: Object.freeze([...this.#diagnostics]),
      omittedDiagnostics: this.#omittedDiagnostics
    })
  }

  #discoverExplicit(input: string): void {
    if (!isAbsolute(input) || Buffer.byteLength(input) > maxExtensionPathBytes) {
      this.#diagnose({
        type: "unsupported",
        path: input,
        message: `Explicit extension paths must be absolute and at most ${maxExtensionPathBytes} bytes`
      })
      return
    }
    const path = resolve(input)
    const inspection = inspectExtensionPath(path)
    if (inspection.type === "missing") {
      this.#diagnose({ type: "missing", path, message: "Extension path does not exist" })
      return
    }
    if (inspection.type === "unreadable") {
      this.#diagnose({ type: "unreadable", path, message: inspection.message })
      return
    }
    if (inspection.type === "unsupported") {
      this.#diagnose({ type: "unsupported", path, message: "Extension path is not a file or directory" })
      return
    }
    if (inspection.type === "file") {
      if (!isExtensionFile(path)) {
        this.#diagnose({ type: "unsupported", path, message: "Extension files must end in .ts or .js" })
        return
      }
      if (!this.#add({ declaredPath: path, entryPath: path, scope: "temporary", origin: "cli" })) {
        this.#diagnose({
          type: "limit",
          path,
          message: `Extension sources cannot exceed ${maxExtensionSources}`,
          omitted: 1
        })
      }
      return
    }

    const entry = this.#directoryEntry(path)
    if (entry) {
      if (!this.#add({ declaredPath: path, entryPath: entry, scope: "temporary", origin: "cli" })) {
        this.#diagnose({
          type: "limit",
          path,
          message: `Extension sources cannot exceed ${maxExtensionSources}`,
          omitted: 1
        })
      }
      return
    }
    if (this.#discoverDirectory(path, "temporary", "cli") === 0) {
      this.#diagnose({ type: "unsupported", path, message: "Extension directory has no supported entry points" })
    }
  }

  #discoverConfigured(path: string, scope: "global" | "project"): void {
    const inspection = inspectExtensionPath(path)
    if (inspection.type === "missing") {
      this.#diagnose({ type: "missing", path, message: "Configured extension path does not exist" })
      return
    }
    if (inspection.type === "unreadable") {
      this.#diagnose({ type: "unreadable", path, message: inspection.message })
      return
    }
    if (inspection.type === "unsupported") {
      this.#diagnose({ type: "unsupported", path, message: "Configured extension path is not a file or directory" })
      return
    }
    if (inspection.type === "file") {
      if (!isExtensionFile(path)) {
        this.#diagnose({ type: "unsupported", path, message: "Extension files must end in .ts or .js" })
        return
      }
      if (!this.#add({ declaredPath: path, entryPath: path, scope, origin: "settings" })) {
        this.#diagnose({
          type: "limit",
          path,
          message: `Extension sources cannot exceed ${maxExtensionSources}`,
          omitted: 1
        })
      }
      return
    }

    const entry = this.#directoryEntry(path)
    if (entry) {
      if (!this.#add({ declaredPath: path, entryPath: entry, scope, origin: "settings" })) {
        this.#diagnose({
          type: "limit",
          path,
          message: `Extension sources cannot exceed ${maxExtensionSources}`,
          omitted: 1
        })
      }
      return
    }
    if (this.#discoverDirectory(path, scope, "settings") === 0) {
      this.#diagnose({
        type: "unsupported",
        path,
        message: "Configured extension directory has no supported entry points"
      })
    }
  }

  #discoverDirectory(
    directory: string,
    scope: ExtensionSource["scope"],
    origin: ExtensionSource["origin"]
  ): number | undefined {
    if (Buffer.byteLength(directory) > maxExtensionPathBytes) {
      this.#diagnose({
        type: "unsupported",
        path: directory,
        message: `Extension paths cannot exceed ${maxExtensionPathBytes} bytes`
      })
      return undefined
    }
    const inspection = inspectExtensionPath(directory)
    if (inspection.type === "missing") return undefined
    if (inspection.type === "unreadable") {
      this.#diagnose({ type: "unreadable", path: directory, message: inspection.message })
      return undefined
    }
    if (inspection.type !== "directory") {
      this.#diagnose({ type: "unsupported", path: directory, message: "Extension root is not a directory" })
      return undefined
    }

    let entries
    try {
      entries = readResourceDirectory(directory)
    } catch (cause) {
      this.#diagnose({
        type: "unreadable",
        path: directory,
        message: cause instanceof Error ? cause.message : String(cause)
      })
      return undefined
    }
    if (entries.truncated) {
      this.#diagnose({
        type: "limit",
        path: directory,
        message: "Extension root omitted because its directory entries exceeded the discovery bound"
      })
      return undefined
    }

    let candidates = 0
    let omittedSources = 0
    for (const entry of entries.entries) {
      const path = join(directory, entry.name)
      if ((entry.isFile() || entry.isSymbolicLink()) && isExtensionFile(entry.name)) {
        candidates++
        if (!this.#add({ declaredPath: path, entryPath: path, scope, origin })) omittedSources++
        continue
      }
      if (entry.isSymbolicLink()) {
        const target = inspectExtensionPath(path)
        if (target.type === "directory") {
          this.#diagnose({
            type: "unsupported",
            path,
            message: "Directory symlinks are not traversed during extension discovery"
          })
        } else if (target.type === "unreadable") {
          this.#diagnose({ type: "unreadable", path, message: target.message })
        } else if (target.type === "missing") {
          this.#diagnose({ type: "missing", path, message: "Extension symlink target does not exist" })
        }
        continue
      }
      if (!entry.isDirectory()) continue
      const index = this.#directoryEntry(path)
      if (!index) {
        this.#diagnose({ type: "unsupported", path, message: "Extension directory requires index.ts or index.js" })
        continue
      }
      candidates++
      if (!this.#add({ declaredPath: path, entryPath: index, scope, origin })) omittedSources++
    }

    if (omittedSources > 0 && this.#sources.length >= maxExtensionSources) {
      this.#diagnose({
        type: "limit",
        path: directory,
        message: `Extension sources cannot exceed ${maxExtensionSources}`,
        omitted: omittedSources
      })
    }
    return candidates
  }

  #directoryEntry(path: string): string | undefined {
    const resolved = directoryEntry(path)
    for (const diagnostic of resolved.diagnostics) this.#diagnose(diagnostic)
    return resolved.entryPath
  }

  #add(candidate: SourceCandidate): boolean {
    if (
      Buffer.byteLength(candidate.declaredPath) > maxExtensionPathBytes ||
      Buffer.byteLength(candidate.entryPath) > maxExtensionPathBytes
    ) {
      this.#diagnose({
        type: "unsupported",
        path: candidate.declaredPath,
        message: `Extension paths cannot exceed ${maxExtensionPathBytes} bytes`
      })
      return true
    }
    const inspection = inspectExtensionPath(candidate.entryPath)
    if (inspection.type === "missing") {
      this.#diagnose({ type: "missing", path: candidate.entryPath, message: "Extension entry point does not exist" })
      return true
    }
    if (inspection.type === "unreadable") {
      this.#diagnose({ type: "unreadable", path: candidate.entryPath, message: inspection.message })
      return true
    }
    if (inspection.type !== "file") {
      this.#diagnose({ type: "unsupported", path: candidate.entryPath, message: "Extension entry point is not a file" })
      return true
    }
    const readError = extensionFileReadError(candidate.entryPath)
    if (readError) {
      this.#diagnose({ ...readError, path: candidate.entryPath })
      return true
    }
    const entryPath = canonicalResourcePath(candidate.entryPath)
    if (Buffer.byteLength(entryPath) > maxExtensionPathBytes) {
      this.#diagnose({
        type: "unsupported",
        path: candidate.declaredPath,
        message: `Canonical extension paths cannot exceed ${maxExtensionPathBytes} bytes`
      })
      return true
    }
    if (this.#seen.has(entryPath)) {
      this.#diagnose({ type: "duplicate", path: candidate.declaredPath, message: "Duplicate extension source omitted" })
      return true
    }
    this.#seen.add(entryPath)
    if (this.#sources.length >= maxExtensionSources) return false

    this.#sources.push(
      Object.freeze({
        id: extensionSourceId(entryPath),
        declaredPath: candidate.declaredPath,
        entryPath,
        scope: candidate.scope,
        origin: candidate.origin
      })
    )
    return true
  }

  #diagnose(diagnostic: ExtensionDiscoveryDiagnostic): void {
    if (this.#diagnostics.length >= maxExtensionDiscoveryDiagnostics) {
      this.#omittedDiagnostics++
      return
    }
    this.#diagnostics.push(Object.freeze(diagnostic))
  }
}

export function discoverExtensionLoadPlan(
  paths: ZiPaths,
  project: ProjectConfigurationAdmission,
  explicitPaths: readonly string[] = [],
  settings?: SettingsManager
): ExtensionDiscoveryResult {
  return new Discovery(paths, settings).run(project, explicitPaths)
}

export function extensionDiscoveryDiagnostic(value: ExtensionDiscoveryDiagnostic): ExtensionDiagnostic {
  return {
    path: value.path,
    phase: "discovery",
    severity: value.type === "duplicate" ? "warning" : "error",
    message: value.message
  }
}

interface DirectoryEntryResolution {
  readonly entryPath: string | undefined
  readonly diagnostics: readonly ExtensionDiscoveryDiagnostic[]
}

function directoryEntry(path: string): DirectoryEntryResolution {
  const diagnostics: ExtensionDiscoveryDiagnostic[] = []
  const indexTs = join(path, "index.ts")
  const typescript = inspectExtensionPath(indexTs)
  if (typescript.type === "file") return { entryPath: indexTs, diagnostics }
  if (typescript.type === "unreadable") {
    diagnostics.push({ type: "unreadable", path: indexTs, message: typescript.message })
  }

  const indexJs = join(path, "index.js")
  const javascript = inspectExtensionPath(indexJs)
  if (javascript.type === "file") return { entryPath: indexJs, diagnostics }
  if (javascript.type === "unreadable") {
    diagnostics.push({ type: "unreadable", path: indexJs, message: javascript.message })
  }
  return { entryPath: undefined, diagnostics }
}

function isExtensionFile(path: string): boolean {
  return path.endsWith(".ts") || path.endsWith(".js")
}

function extensionSourceId(entryPath: string): string {
  return `extension:${createHash("sha256").update(entryPath).digest("hex")}`
}

type ExtensionPathInspection =
  | { readonly type: "file" }
  | { readonly type: "directory" }
  | { readonly type: "missing" }
  | { readonly type: "unreadable"; readonly message: string }
  | { readonly type: "unsupported" }

function inspectExtensionPath(path: string): ExtensionPathInspection {
  try {
    const stat = statSync(path)
    if (stat.isFile()) return { type: "file" }
    if (stat.isDirectory()) return { type: "directory" }
    return { type: "unsupported" }
  } catch (cause) {
    if (hasCode(cause, "ENOENT") || hasCode(cause, "ENOTDIR")) return { type: "missing" }
    const detail = cause instanceof Error ? `: ${cause.message}` : ""
    return { type: "unreadable", message: `Extension path cannot be inspected${detail}` }
  }
}

function extensionFileReadError(
  path: string
): { readonly type: "missing" | "unreadable"; readonly message: string } | undefined {
  try {
    const file = openSync(path, "r")
    closeSync(file)
    return undefined
  } catch (cause) {
    if (hasCode(cause, "ENOENT") || hasCode(cause, "ENOTDIR")) {
      return { type: "missing", message: "Extension entry point disappeared during discovery" }
    }
    const detail = cause instanceof Error ? `: ${cause.message}` : ""
    return { type: "unreadable", message: `Extension entry point cannot be read${detail}` }
  }
}

function hasCode(cause: unknown, code: string): boolean {
  return typeof cause === "object" && cause !== null && "code" in cause && cause.code === code
}

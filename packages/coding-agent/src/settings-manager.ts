import { closeSync, existsSync, mkdirSync, openSync, readSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { basename, dirname, join } from "node:path"

import type { ThinkingLevel } from "@earendil-works/pi-agent-core"
import lockfile from "proper-lockfile"

import type { OpenZiPaths } from "./paths.js"

export interface AgentSettings {
  model?: string
  thinkingLevel: ThinkingLevel
  steeringMode: "all" | "one-at-a-time"
  followUpMode: "all" | "one-at-a-time"
}

export const maxSettingsFileBytes = 1024 * 1024

const defaults: AgentSettings = {
  thinkingLevel: "medium",
  steeringMode: "one-at-a-time",
  followUpMode: "one-at-a-time"
}

export type SettingsScope = "global" | "project"

export interface SettingsError {
  readonly scope: SettingsScope
  readonly path: string
  readonly error: Error
}

type SettingsScopeState =
  | { readonly type: "missing"; readonly path: string }
  | { readonly type: "loaded"; readonly path: string; readonly settings: Partial<AgentSettings> }
  | { readonly type: "invalid"; readonly path: string; readonly error: Error }

export class SettingsManager {
  #global: SettingsScopeState
  #project: SettingsScopeState
  #runtime: Partial<AgentSettings> = {}
  #settings: Readonly<AgentSettings>
  #paths: OpenZiPaths | undefined
  #sharedSettingsFile = false
  #errors: SettingsError[] = []

  constructor(settings: Partial<AgentSettings> = {}) {
    this.#global = { type: "loaded", path: "<memory>", settings: { ...settings } }
    this.#project = { type: "missing", path: "<memory>" }
    this.#settings = mergeSettings(settings)
  }

  static create(paths: OpenZiPaths, runtime: Partial<AgentSettings> = {}): SettingsManager {
    const manager = new SettingsManager()
    manager.#paths = paths
    manager.#sharedSettingsFile = paths.globalSettingsFile === paths.projectSettingsFile
    manager.#global = loadScope(paths.globalSettingsFile)
    manager.#project = manager.#sharedSettingsFile
      ? { type: "missing", path: paths.projectSettingsFile }
      : loadScope(paths.projectSettingsFile)
    manager.#runtime = { ...runtime }
    manager.#recordLoadError("global", manager.#global)
    manager.#recordLoadError("project", manager.#project)
    manager.#recompute()
    return manager
  }

  get(): Readonly<AgentSettings> {
    return this.#settings
  }

  getGlobal(): Readonly<Partial<AgentSettings>> {
    return Object.freeze({ ...scopeSettings(this.#global) })
  }

  getProject(): Readonly<Partial<AgentSettings>> {
    return Object.freeze({ ...scopeSettings(this.#project) })
  }

  updateGlobal(patch: Partial<AgentSettings>): void {
    this.#global = this.#updateScope("global", this.#global, patch)
    clearRuntimeOverrides(this.#runtime, patch)
    this.#recompute()
  }

  updateProject(patch: Partial<AgentSettings>): void {
    if (this.#sharedSettingsFile) {
      this.updateGlobal(patch)
      return
    }
    this.#project = this.#updateScope("project", this.#project, patch)
    clearRuntimeOverrides(this.#runtime, patch)
    this.#recompute()
  }

  applyRuntime(patch: Partial<AgentSettings>): void {
    this.#runtime = { ...this.#runtime, ...patch }
    this.#recompute()
  }

  reload(): void {
    if (!this.#paths) return
    this.#global = loadScope(this.#paths.globalSettingsFile)
    this.#project = this.#sharedSettingsFile
      ? { type: "missing", path: this.#paths.projectSettingsFile }
      : loadScope(this.#paths.projectSettingsFile)
    this.#recordLoadError("global", this.#global)
    this.#recordLoadError("project", this.#project)
    this.#recompute()
  }

  drainErrors(): SettingsError[] {
    const errors = this.#errors
    this.#errors = []
    return errors
  }

  #updateScope(scope: SettingsScope, state: SettingsScopeState, patch: Partial<AgentSettings>): SettingsScopeState {
    if (state.type === "invalid") {
      throw new Error(`Cannot update invalid ${scope} settings: ${state.path}`, { cause: state.error })
    }
    if (this.#paths) persistSettings(state.path, patch)
    return { type: "loaded", path: state.path, settings: { ...scopeSettings(state), ...patch } }
  }

  #recordLoadError(scope: SettingsScope, state: SettingsScopeState): void {
    if (state.type === "invalid") this.#errors.push({ scope, path: state.path, error: state.error })
  }

  #recompute(): void {
    this.#settings = mergeSettings(scopeSettings(this.#global), scopeSettings(this.#project), this.#runtime)
  }
}

function loadScope(path: string): SettingsScopeState {
  if (!existsSync(path)) return { type: "missing", path }
  try {
    return { type: "loaded", path, settings: loadSettings(path) }
  } catch (cause) {
    const error = cause instanceof Error ? cause : new Error(String(cause))
    return { type: "invalid", path, error }
  }
}

function scopeSettings(state: SettingsScopeState): Partial<AgentSettings> {
  return state.type === "loaded" ? state.settings : {}
}

function mergeSettings(...layers: readonly Partial<AgentSettings>[]): Readonly<AgentSettings> {
  return Object.freeze(Object.assign({}, defaults, ...layers))
}

function clearRuntimeOverrides(runtime: Partial<AgentSettings>, patch: Partial<AgentSettings>): void {
  if ("model" in patch) delete runtime.model
  if ("thinkingLevel" in patch) delete runtime.thinkingLevel
  if ("steeringMode" in patch) delete runtime.steeringMode
  if ("followUpMode" in patch) delete runtime.followUpMode
}

function persistSettings(path: string, patch: Partial<AgentSettings>): void {
  mkdirSync(dirname(path), { recursive: true })
  if (!existsSync(path)) {
    try {
      writeFileSync(path, "{}", { flag: "wx" })
    } catch (error) {
      if (!hasCode(error, "EEXIST")) throw error
    }
  }

  const release = acquireLock(path)
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`)
  try {
    const current: unknown = JSON.parse(readSettingsFile(path))
    if (!isRecord(current)) throw new Error(`Invalid settings object: ${path}`)
    const serialized = `${JSON.stringify({ ...current, ...patch }, null, 2)}\n`
    if (Buffer.byteLength(serialized) > maxSettingsFileBytes) {
      throw new Error(`Settings files cannot exceed ${maxSettingsFileBytes} bytes: ${path}`)
    }
    writeFileSync(temporary, serialized)
    renameSync(temporary, path)
  } finally {
    try {
      if (existsSync(temporary)) unlinkSync(temporary)
    } finally {
      release()
    }
  }
}

function acquireLock(path: string): () => void {
  for (let attempt = 1; ; attempt++) {
    try {
      return lockfile.lockSync(path, { realpath: false })
    } catch (error) {
      if (!hasCode(error, "ELOCKED") || attempt === 10) throw error
      const resumeAt = Date.now() + 20
      while (Date.now() < resumeAt) {}
    }
  }
}

function loadSettings(path: string): Partial<AgentSettings> {
  if (!existsSync(path)) return {}

  let value: unknown
  try {
    value = JSON.parse(readSettingsFile(path))
  } catch (error) {
    const detail = error instanceof Error ? `: ${error.message}` : ""
    throw new Error(`Could not read settings ${path}${detail}`, { cause: error })
  }
  if (!isRecord(value)) throw new Error(`Invalid settings object: ${path}`)

  const settings: Partial<AgentSettings> = {}
  if (value.model !== undefined) {
    if (typeof value.model !== "string") throw invalidSetting(path, "model")
    settings.model = value.model
  }
  if (value.thinkingLevel !== undefined) {
    if (!isThinkingLevel(value.thinkingLevel)) throw invalidSetting(path, "thinkingLevel")
    settings.thinkingLevel = value.thinkingLevel
  }
  if (value.steeringMode !== undefined) {
    if (!isQueueMode(value.steeringMode)) throw invalidSetting(path, "steeringMode")
    settings.steeringMode = value.steeringMode
  }
  if (value.followUpMode !== undefined) {
    if (!isQueueMode(value.followUpMode)) throw invalidSetting(path, "followUpMode")
    settings.followUpMode = value.followUpMode
  }
  return settings
}

function readSettingsFile(path: string): string {
  const file = openSync(path, "r")
  try {
    const buffer = Buffer.allocUnsafe(maxSettingsFileBytes + 1)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      const read = readSync(file, buffer, bytesRead, buffer.length - bytesRead, null)
      if (read === 0) break
      bytesRead += read
    }
    if (bytesRead > maxSettingsFileBytes) {
      throw new Error(`Settings files cannot exceed ${maxSettingsFileBytes} bytes: ${path}`)
    }
    return buffer.toString("utf8", 0, bytesRead)
  } finally {
    closeSync(file)
  }
}

function invalidSetting(path: string, field: keyof AgentSettings): Error {
  return new Error(`Invalid ${field} setting: ${path}`)
}

function isQueueMode(value: unknown): value is AgentSettings["steeringMode"] {
  return value === "all" || value === "one-at-a-time"
}

function isThinkingLevel(value: unknown): value is ThinkingLevel {
  return (
    value === "off" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh" ||
    value === "max"
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function hasCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code
}

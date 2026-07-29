import { closeSync, existsSync, mkdirSync, openSync, readSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { basename, dirname, join } from "node:path"

import type { QueueMode, ThinkingLevel } from "@earendil-works/pi-agent-core"
import lockfile from "proper-lockfile"

import type { ZiPaths } from "./paths.js"
import type { ProjectConfigurationAdmission } from "./project-trust.js"
import { isRetryCount, isRetryDelay } from "./retry.js"

export { maxRetryBaseDelayMs, maxRetryCount } from "./retry.js"

export interface AgentSettings {
  defaultProvider?: string
  defaultModel?: string
  defaultThinkingLevel?: ThinkingLevel
  externalEditor?: string
  steeringMode: QueueMode
  followUpMode: QueueMode
  codexFastMode: boolean
  retryEnabled: boolean
  retryMaxRetries: number
  retryBaseDelayMs: number
  compactionEnabled: boolean
  compactionReserveTokens: number
  compactionKeepRecentTokens: number
}

export const maxSettingsFileBytes = 1024 * 1024
export const maxExternalEditorCommandLength = 16 * 1024

const defaults: AgentSettings = {
  steeringMode: "one-at-a-time",
  followUpMode: "one-at-a-time",
  codexFastMode: false,
  retryEnabled: true,
  retryMaxRetries: 3,
  retryBaseDelayMs: 2_000,
  compactionEnabled: true,
  compactionReserveTokens: 16_384,
  compactionKeepRecentTokens: 20_000
}

export type SettingsScope = "global" | "project"

export interface SettingsError {
  readonly scope: SettingsScope
  readonly path: string
  readonly error: Error
}

type SettingsScopeState =
  | { readonly type: "absent"; readonly path: string }
  | { readonly type: "excluded"; readonly path: string }
  | { readonly type: "missing"; readonly path: string }
  | { readonly type: "loaded"; readonly path: string; readonly settings: Partial<AgentSettings> }
  | { readonly type: "invalid"; readonly path: string; readonly error: Error }

export class SettingsManager {
  #global: SettingsScopeState
  #project: SettingsScopeState
  #overrides: Partial<AgentSettings> = {}
  #settings: Readonly<AgentSettings>
  #paths: ZiPaths | undefined
  #sharedSettingsFile = false
  #errors: SettingsError[] = []
  readonly #externalEditorFallback: string

  constructor(settings: Partial<AgentSettings> = {}) {
    validateSettingsPatch(settings)
    this.#externalEditorFallback = resolveExternalEditorFallback(process.env, process.platform)
    this.#global = { type: "loaded", path: "<memory>", settings: { ...settings } }
    this.#project = { type: "missing", path: "<memory>" }
    this.#settings = mergeSettings(settings)
  }

  static create(
    paths: ZiPaths,
    projectAdmission: ProjectConfigurationAdmission,
    overrides: Partial<AgentSettings> = {}
  ): SettingsManager {
    if (projectAdmission !== "trusted" && projectAdmission !== "untrusted" && projectAdmission !== "absent") {
      throw new Error(`Unknown project configuration admission: ${String(projectAdmission)}`)
    }
    validateSettingsPatch(overrides)
    const manager = new SettingsManager()
    manager.#paths = paths
    manager.#sharedSettingsFile = paths.projectConfigIsGlobal
    manager.#global = loadScope(paths.globalSettingsFile)
    manager.#project = manager.#sharedSettingsFile
      ? { type: "missing", path: paths.projectSettingsFile }
      : projectAdmission === "trusted"
        ? loadScope(paths.projectSettingsFile)
        : { type: projectAdmission === "absent" ? "absent" : "excluded", path: paths.projectSettingsFile }
    manager.#overrides = { ...overrides }
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

  getDefaultProvider(): string | undefined {
    return this.#settings.defaultProvider
  }

  getDefaultModel(): string | undefined {
    return this.#settings.defaultModel
  }

  getDefaultThinkingLevel(): ThinkingLevel | undefined {
    return this.#settings.defaultThinkingLevel
  }

  getExternalEditorCommand(): string {
    return this.#settings.externalEditor ?? this.#externalEditorFallback
  }

  setDefaultModelAndProvider(provider: string, modelId: string): void {
    this.updateGlobal({ defaultProvider: provider, defaultModel: modelId })
  }

  setDefaultThinkingLevel(level: ThinkingLevel, scope: SettingsScope = "global"): void {
    if (scope === "global") this.updateGlobal({ defaultThinkingLevel: level })
    else this.updateProject({ defaultThinkingLevel: level })
  }

  updateGlobal(patch: Partial<AgentSettings>): void {
    this.#global = this.#updateScope("global", this.#global, patch)
    clearOverrides(this.#overrides, patch)
    this.#recompute()
  }

  updateProject(patch: Partial<AgentSettings>): void {
    if (this.#sharedSettingsFile) {
      this.updateGlobal(patch)
      return
    }
    if (this.#project.type === "excluded") {
      throw new Error(`Cannot update project settings before project trust: ${this.#project.path}`)
    }
    this.#project = this.#updateScope("project", this.#project, patch)
    clearOverrides(this.#overrides, patch)
    this.#recompute()
  }

  reload(): void {
    if (!this.#paths) return
    const projectState = this.#project.type
    this.#errors = []
    this.#global = loadScope(this.#paths.globalSettingsFile)
    this.#project = this.#sharedSettingsFile
      ? { type: "missing", path: this.#paths.projectSettingsFile }
      : projectState === "excluded" || projectState === "absent"
        ? { type: projectState, path: this.#paths.projectSettingsFile }
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
    validateSettingsPatch(patch)
    if (state.type === "invalid") {
      throw new Error(`Cannot update invalid ${scope} settings: ${state.path}`, { cause: state.error })
    }
    if (this.#paths) {
      if (state.type === "absent") persistNewProjectSettings(state.path, patch)
      else persistSettings(state.path, patch)
    }
    return { type: "loaded", path: state.path, settings: { ...scopeSettings(state), ...patch } }
  }

  #recordLoadError(scope: SettingsScope, state: SettingsScopeState): void {
    if (state.type === "invalid") this.#errors.push({ scope, path: state.path, error: state.error })
  }

  #recompute(): void {
    this.#settings = mergeSettings(scopeSettings(this.#global), scopeSettings(this.#project), this.#overrides)
  }
}

function validateSettingsPatch(patch: Partial<AgentSettings>): void {
  if ("defaultProvider" in patch && (typeof patch.defaultProvider !== "string" || patch.defaultProvider.length === 0)) {
    throw new Error("Invalid defaultProvider setting")
  }
  if ("defaultModel" in patch && (typeof patch.defaultModel !== "string" || patch.defaultModel.length === 0)) {
    throw new Error("Invalid defaultModel setting")
  }
  if ("defaultThinkingLevel" in patch && !isThinkingLevel(patch.defaultThinkingLevel)) {
    throw new Error("Invalid defaultThinkingLevel setting")
  }
  if ("externalEditor" in patch && !isExternalEditorCommand(patch.externalEditor)) {
    throw new Error("Invalid externalEditor setting")
  }
  if ("steeringMode" in patch && !isQueueMode(patch.steeringMode)) {
    throw new Error("Invalid steeringMode setting")
  }
  if ("followUpMode" in patch && !isQueueMode(patch.followUpMode)) {
    throw new Error("Invalid followUpMode setting")
  }
  if ("codexFastMode" in patch && typeof patch.codexFastMode !== "boolean") {
    throw new Error("Invalid codexFastMode setting")
  }
  if ("retryEnabled" in patch && typeof patch.retryEnabled !== "boolean") {
    throw new Error("Invalid retryEnabled setting")
  }
  if ("retryMaxRetries" in patch && !isRetryCount(patch.retryMaxRetries)) {
    throw new Error("Invalid retryMaxRetries setting")
  }
  if ("retryBaseDelayMs" in patch && !isRetryDelay(patch.retryBaseDelayMs)) {
    throw new Error("Invalid retryBaseDelayMs setting")
  }
  if ("compactionEnabled" in patch && typeof patch.compactionEnabled !== "boolean") {
    throw new Error("Invalid compactionEnabled setting")
  }
  if ("compactionReserveTokens" in patch && !isCompactionTokenSetting(patch.compactionReserveTokens)) {
    throw new Error("Invalid compactionReserveTokens setting")
  }
  if ("compactionKeepRecentTokens" in patch && !isCompactionTokenSetting(patch.compactionKeepRecentTokens)) {
    throw new Error("Invalid compactionKeepRecentTokens setting")
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

function clearOverrides(overrides: Partial<AgentSettings>, patch: Partial<AgentSettings>): void {
  if ("defaultProvider" in patch) delete overrides.defaultProvider
  if ("defaultModel" in patch) delete overrides.defaultModel
  if ("defaultThinkingLevel" in patch) delete overrides.defaultThinkingLevel
  if ("externalEditor" in patch) delete overrides.externalEditor
  if ("steeringMode" in patch) delete overrides.steeringMode
  if ("followUpMode" in patch) delete overrides.followUpMode
  if ("codexFastMode" in patch) delete overrides.codexFastMode
  if ("retryEnabled" in patch) delete overrides.retryEnabled
  if ("retryMaxRetries" in patch) delete overrides.retryMaxRetries
  if ("retryBaseDelayMs" in patch) delete overrides.retryBaseDelayMs
  if ("compactionEnabled" in patch) delete overrides.compactionEnabled
  if ("compactionReserveTokens" in patch) delete overrides.compactionReserveTokens
  if ("compactionKeepRecentTokens" in patch) delete overrides.compactionKeepRecentTokens
}

function persistNewProjectSettings(path: string, patch: Partial<AgentSettings>): void {
  mkdirSync(dirname(path), { recursive: true })
  const serialized = `${JSON.stringify(patch, null, 2)}\n`
  if (Buffer.byteLength(serialized) > maxSettingsFileBytes) {
    throw new Error(`Settings files cannot exceed ${maxSettingsFileBytes} bytes: ${path}`)
  }
  try {
    writeFileSync(path, serialized, { flag: "wx" })
  } catch (cause) {
    if (hasCode(cause, "EEXIST")) {
      throw new Error(`Cannot create project settings before project trust because the file now exists: ${path}`, {
        cause
      })
    }
    throw cause
  }
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
  if (value.defaultProvider !== undefined) {
    if (typeof value.defaultProvider !== "string" || value.defaultProvider.length === 0) {
      throw invalidSetting(path, "defaultProvider")
    }
    settings.defaultProvider = value.defaultProvider
  }
  if (value.defaultModel !== undefined) {
    if (typeof value.defaultModel !== "string" || value.defaultModel.length === 0) {
      throw invalidSetting(path, "defaultModel")
    }
    settings.defaultModel = value.defaultModel
  }
  if (value.defaultThinkingLevel !== undefined) {
    if (!isThinkingLevel(value.defaultThinkingLevel)) throw invalidSetting(path, "defaultThinkingLevel")
    settings.defaultThinkingLevel = value.defaultThinkingLevel
  }
  if (value.externalEditor !== undefined) {
    if (!isExternalEditorCommand(value.externalEditor)) throw invalidSetting(path, "externalEditor")
    settings.externalEditor = value.externalEditor
  }
  if (value.steeringMode !== undefined) {
    if (!isQueueMode(value.steeringMode)) throw invalidSetting(path, "steeringMode")
    settings.steeringMode = value.steeringMode
  }
  if (value.followUpMode !== undefined) {
    if (!isQueueMode(value.followUpMode)) throw invalidSetting(path, "followUpMode")
    settings.followUpMode = value.followUpMode
  }
  if (value.codexFastMode !== undefined) {
    if (typeof value.codexFastMode !== "boolean") throw invalidSetting(path, "codexFastMode")
    settings.codexFastMode = value.codexFastMode
  }
  if (value.retryEnabled !== undefined) {
    if (typeof value.retryEnabled !== "boolean") throw invalidSetting(path, "retryEnabled")
    settings.retryEnabled = value.retryEnabled
  }
  if (value.retryMaxRetries !== undefined) {
    if (!isRetryCount(value.retryMaxRetries)) throw invalidSetting(path, "retryMaxRetries")
    settings.retryMaxRetries = value.retryMaxRetries
  }
  if (value.retryBaseDelayMs !== undefined) {
    if (!isRetryDelay(value.retryBaseDelayMs)) throw invalidSetting(path, "retryBaseDelayMs")
    settings.retryBaseDelayMs = value.retryBaseDelayMs
  }
  if (value.compactionEnabled !== undefined) {
    if (typeof value.compactionEnabled !== "boolean") throw invalidSetting(path, "compactionEnabled")
    settings.compactionEnabled = value.compactionEnabled
  }
  if (value.compactionReserveTokens !== undefined) {
    if (!isCompactionTokenSetting(value.compactionReserveTokens)) {
      throw invalidSetting(path, "compactionReserveTokens")
    }
    settings.compactionReserveTokens = value.compactionReserveTokens
  }
  if (value.compactionKeepRecentTokens !== undefined) {
    if (!isCompactionTokenSetting(value.compactionKeepRecentTokens)) {
      throw invalidSetting(path, "compactionKeepRecentTokens")
    }
    settings.compactionKeepRecentTokens = value.compactionKeepRecentTokens
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

function isExternalEditorCommand(value: unknown): value is string {
  return (
    typeof value === "string" && value.trim().length > 0 && Buffer.byteLength(value) <= maxExternalEditorCommandLength
  )
}

function resolveExternalEditorFallback(env: NodeJS.ProcessEnv, platform: NodeJS.Platform): string {
  if (isExternalEditorCommand(env.VISUAL)) return env.VISUAL
  if (isExternalEditorCommand(env.EDITOR)) return env.EDITOR
  return platform === "win32" ? "notepad" : "nano"
}

function isQueueMode(value: unknown): value is AgentSettings["steeringMode"] {
  return value === "all" || value === "one-at-a-time"
}

function isCompactionTokenSetting(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 1_000_000
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

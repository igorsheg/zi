import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
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

const defaults: AgentSettings = {
  thinkingLevel: "medium",
  steeringMode: "one-at-a-time",
  followUpMode: "one-at-a-time"
}

export class SettingsManager {
  #global: Partial<AgentSettings>
  #project: Partial<AgentSettings> = {}
  #runtime: Partial<AgentSettings> = {}
  #settings: Readonly<AgentSettings>
  #paths: OpenZiPaths | undefined
  #sharedSettingsFile = false

  constructor(settings: Partial<AgentSettings> = {}) {
    this.#global = { ...settings }
    this.#settings = mergeSettings(this.#global)
  }

  static create(paths: OpenZiPaths, runtime: Partial<AgentSettings> = {}): SettingsManager {
    const manager = new SettingsManager()
    manager.#paths = paths
    manager.#sharedSettingsFile = paths.globalSettingsFile === paths.projectSettingsFile
    manager.#global = loadSettings(paths.globalSettingsFile)
    manager.#project = manager.#sharedSettingsFile ? {} : loadSettings(paths.projectSettingsFile)
    manager.#runtime = { ...runtime }
    manager.#settings = mergeSettings(manager.#global, manager.#project, manager.#runtime)
    return manager
  }

  get(): Readonly<AgentSettings> {
    return this.#settings
  }

  getGlobal(): Readonly<Partial<AgentSettings>> {
    return Object.freeze({ ...this.#global })
  }

  getProject(): Readonly<Partial<AgentSettings>> {
    return Object.freeze({ ...this.#project })
  }

  update(patch: Partial<AgentSettings>): void {
    if (this.#paths) persistSettings(this.#paths.globalSettingsFile, patch)
    this.#global = { ...this.#global, ...patch }
    clearRuntimeOverrides(this.#runtime, patch)
    this.#settings = mergeSettings(this.#global, this.#project, this.#runtime)
  }

  updateProject(patch: Partial<AgentSettings>): void {
    if (this.#sharedSettingsFile) {
      this.update(patch)
      return
    }
    if (this.#paths) persistSettings(this.#paths.projectSettingsFile, patch)
    this.#project = { ...this.#project, ...patch }
    clearRuntimeOverrides(this.#runtime, patch)
    this.#settings = mergeSettings(this.#global, this.#project, this.#runtime)
  }

  applyRuntime(patch: Partial<AgentSettings>): void {
    this.#runtime = { ...this.#runtime, ...patch }
    this.#settings = mergeSettings(this.#global, this.#project, this.#runtime)
  }
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
    const current: unknown = JSON.parse(readFileSync(path, "utf8"))
    if (!isRecord(current)) throw new Error(`Invalid settings object: ${path}`)
    writeFileSync(temporary, `${JSON.stringify({ ...current, ...patch }, null, 2)}\n`)
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
    value = JSON.parse(readFileSync(path, "utf8"))
  } catch (error) {
    throw new Error(`Could not read settings ${path}`, { cause: error })
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

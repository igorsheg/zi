import type { ThinkingLevel } from "@earendil-works/pi-agent-core"

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
  #settings: AgentSettings

  constructor(settings: Partial<AgentSettings> = {}) {
    this.#settings = { ...defaults, ...settings }
  }

  get(): Readonly<AgentSettings> {
    return this.#settings
  }

  update(patch: Partial<AgentSettings>): void {
    this.#settings = { ...this.#settings, ...patch }
  }
}

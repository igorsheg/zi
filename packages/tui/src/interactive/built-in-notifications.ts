import type { ReadableAtom } from "nanostores"

import type { AutomaticCompactionNoticeEvent } from "./interactive-store.js"
import {
  maxNotificationMessageBytes,
  type NotificationCenter,
  type NotificationGroupProducer,
  type NotificationLevel
} from "./notifications.js"

export type ReloadNoticeOutcome = "success" | "warning" | "error"

export interface BuiltInNoticeActions {
  promptProgress(message: string): void
  promptInfo(message: string): void
  promptWarning(message: string): void
  promptError(message: string): void
  clearPrompt(): void
  backgroundTaskCapacityExceeded(): void
  reloadCompleted(outcome: ReloadNoticeOutcome, message: string): void
  reloadFailed(message: string): void
  setMcp(message: string | undefined): void
}

interface BuiltInNoticeSource {
  readonly $generation: ReadableAtom<number>
  subscribeAutomaticCompaction(listener: (event: AutomaticCompactionNoticeEvent) => void): () => void
}

type BuiltInNoticeOwner = Pick<NotificationCenter, "claimGroup">
type BuiltInNoticeKey = (typeof builtInNoticeKeys)[number]

const promptNoticeKey = "prompt"
const builtInNoticeKeys = [
  "bootstrap",
  "extensions",
  "mcp",
  "project-trust",
  "automatic-compaction",
  "copy",
  "shell-capacity",
  "reload",
  promptNoticeKey
] as const

/** Projects Zi-owned one-line notices through one bounded Fidget group. */
export class BuiltInNotificationPresenter implements BuiltInNoticeActions {
  readonly #notifications: NotificationGroupProducer
  readonly #release: readonly (() => void)[]
  #disposed = false

  constructor(source: BuiltInNoticeSource, notifications: BuiltInNoticeOwner) {
    this.#notifications = notifications.claimGroup(
      "zi.system",
      { name: false, icon: false, ttl: 5, priority: 20 },
      builtInNoticeKeys.length
    )
    const release: (() => void)[] = []
    try {
      release.push(source.$generation.listen(this.#clearSessionNotices))
      release.push(
        source.subscribeAutomaticCompaction(event => {
          if (this.#disposed) return
          if (event.type === "failed") {
            this.#notifications.notify("automatic-compaction", boundedNoticeMessage(event.message), 4, {
              ttl: Infinity
            })
          } else {
            this.#notifications.remove("automatic-compaction")
          }
        })
      )
    } catch (cause) {
      for (const dispose of release) dispose()
      this.#notifications.dispose()
      throw cause
    }
    this.#release = release
  }

  setBootstrap(message: string | undefined): void {
    this.#setPersistent("bootstrap", message)
  }

  setExtension(message: string | undefined): void {
    this.#setPersistent("extensions", message)
  }

  setMcp(message: string | undefined): void {
    this.#setPersistent("mcp", message)
  }

  setProjectTrust(message: string | undefined): void {
    this.#setPersistent("project-trust", message)
  }

  copyFailed(message: string): void {
    this.#notify("copy", message, 3, 5)
  }

  copySucceeded(message?: string): void {
    if (message === undefined) {
      if (!this.#disposed) this.#notifications.remove("copy")
      return
    }
    this.#notify("copy", message, 2, 4)
  }

  promptProgress(message: string): void {
    this.#notify(promptNoticeKey, message, 2, Infinity, true)
  }

  promptInfo(message: string): void {
    this.#notify(promptNoticeKey, message, 2, 4)
  }

  promptWarning(message: string): void {
    this.#notify(promptNoticeKey, message, 3, 5)
  }

  promptError(message: string): void {
    this.#notify(promptNoticeKey, message, 4, Infinity)
  }

  clearPrompt(): void {
    if (!this.#disposed) this.#notifications.remove(promptNoticeKey)
  }

  backgroundTaskCapacityExceeded(): void {
    this.#notify("shell-capacity", "Background task capacity exceeded", 3, 5)
  }

  reloadCompleted(outcome: ReloadNoticeOutcome, message: string): void {
    if (this.#disposed) return
    this.#notifications.remove(promptNoticeKey)
    this.#notifications.remove("extensions")
    this.#notifications.remove("reload")
    this.#publishReload(outcome, message)
  }

  reloadFailed(message: string): void {
    if (this.#disposed) return
    this.#notifications.remove(promptNoticeKey)
    this.#notifications.remove("reload")
    this.#publishReload("error", message)
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const release of this.#release) release()
    this.#notifications.dispose()
  }

  #publishReload(outcome: ReloadNoticeOutcome, message: string): void {
    const level = outcome === "success" ? 2 : outcome === "warning" ? 3 : 4
    this.#notifications.notify("reload", boundedNoticeMessage(message), level, {
      ttl: outcome === "success" ? 4 : Infinity
    })
  }

  #notify(key: BuiltInNoticeKey, message: string, level: NotificationLevel, ttl: number, skipHistory = false): void {
    if (this.#disposed) return
    this.#notifications.notify(key, boundedNoticeMessage(message), level, { ttl, skip_history: skipHistory })
  }

  #setPersistent(key: BuiltInNoticeKey, message: string | undefined): void {
    if (this.#disposed) return
    if (message === undefined) {
      this.#notifications.remove(key)
      return
    }
    this.#notifications.notify(key, boundedNoticeMessage(message), 3, { ttl: Infinity, skip_history: true })
  }

  #clearSessionNotices = (): void => {
    if (this.#disposed) return
    for (const key of builtInNoticeKeys) this.#notifications.remove(key)
  }
}

function boundedNoticeMessage(message: string): string {
  if (Buffer.byteLength(message) <= maxNotificationMessageBytes) return message
  const suffix = "…"
  const prefixBytes = maxNotificationMessageBytes - Buffer.byteLength(suffix)
  let bytes = 0
  let prefix = ""
  for (const scalar of message) {
    const scalarBytes = Buffer.byteLength(scalar)
    if (bytes + scalarBytes > prefixBytes) break
    prefix += scalar
    bytes += scalarBytes
  }
  return `${prefix}${suffix}`
}

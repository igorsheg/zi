import type { ReadableAtom } from "nanostores"

import type { AutomaticCompactionNoticeEvent } from "./interactive-store.js"
import {
  maxNotificationMessageBytes,
  type NotificationCenter,
  type NotificationGroupProducer
} from "./notifications.js"

export type ReloadNoticeOutcome = "success" | "warning" | "error"

export interface SystemNoticeActions {
  backgroundTaskCapacityExceeded(): void
  reloadCompleted(outcome: ReloadNoticeOutcome, message: string): void
  reloadFailed(message: string): void
}

interface SystemNoticeSource {
  readonly $generation: ReadableAtom<number>
  subscribeAutomaticCompaction(listener: (event: AutomaticCompactionNoticeEvent) => void): () => void
}

type SystemNoticeOwner = Pick<NotificationCenter, "claimGroup">
type SystemNoticeKey = (typeof systemNoticeKeys)[number]

const systemNoticeKeys = [
  "bootstrap",
  "extensions",
  "project-trust",
  "automatic-compaction",
  "copy",
  "shell-capacity",
  "reload"
] as const

/** Owns passive mode and session notices that must not compete with prompt feedback. */
export class SystemNotificationPresenter implements SystemNoticeActions {
  readonly #notifications: NotificationGroupProducer
  readonly #release: readonly (() => void)[]
  #disposed = false

  constructor(source: SystemNoticeSource, notifications: SystemNoticeOwner) {
    this.#notifications = notifications.claimGroup(
      "zi.system",
      { name: "System", icon: "❰❰", ttl: 5, priority: 20 },
      systemNoticeKeys.length
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

  setProjectTrust(message: string | undefined): void {
    this.#setPersistent("project-trust", message)
  }

  copyFailed(message: string): void {
    if (this.#disposed) return
    this.#notifications.notify("copy", boundedNoticeMessage(message), 3, { ttl: 5 })
  }

  copySucceeded(): void {
    if (!this.#disposed) this.#notifications.remove("copy")
  }

  backgroundTaskCapacityExceeded(): void {
    if (this.#disposed) return
    this.#notifications.notify("shell-capacity", "Background task capacity exceeded", 3, { ttl: 5 })
  }

  reloadCompleted(outcome: ReloadNoticeOutcome, message: string): void {
    if (this.#disposed) return
    this.#notifications.remove("extensions")
    this.#notifications.remove("reload")
    this.#publishReload(outcome, message)
  }

  reloadFailed(message: string): void {
    if (this.#disposed) return
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

  #setPersistent(key: SystemNoticeKey, message: string | undefined): void {
    if (this.#disposed) return
    if (message === undefined) {
      this.#notifications.remove(key)
      return
    }
    this.#notifications.notify(key, boundedNoticeMessage(message), 3, { ttl: Infinity, skip_history: true })
  }

  #clearSessionNotices = (): void => {
    if (this.#disposed) return
    for (const key of systemNoticeKeys) this.#notifications.remove(key)
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

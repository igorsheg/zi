import { expect, test } from "bun:test"

import { createTestRenderer } from "@opentui/core/testing"
import { atom } from "nanostores"

import { BuiltInNotificationPresenter } from "../../src/interactive/built-in-notifications.js"
import type { AutomaticCompactionNoticeEvent } from "../../src/interactive/interactive-store.js"
import {
  maxNotificationMessageBytes,
  NotificationCenter,
  type NotificationGroupConfig,
  type NotificationGroupProducer,
  type NotificationLevel,
  type NotificationOptions
} from "../../src/interactive/notifications.js"
import { defaultTheme } from "../../src/theme.js"

interface PublishedNotice {
  readonly key: string | number
  readonly message: string | null | undefined
  readonly level: NotificationLevel | null | undefined
  readonly options: Omit<NotificationOptions, "key" | "group"> | undefined
}

test("built-in notifications own keyed passive outcomes and clear session state on recovery or replacement", () => {
  const fixture = createFixture()
  const presenter = new BuiltInNotificationPresenter(fixture.source, fixture.owner)
  fixture.removed.length = 0

  presenter.setBootstrap("Saved model unavailable")
  presenter.setExtension("Extension bad.ts: Cannot find module")
  presenter.setProjectTrust("Project configuration is disabled")
  presenter.copyFailed("Copy failed; the selection was preserved")
  presenter.copySucceeded()
  presenter.copySucceeded("Copied last assistant message to clipboard")
  presenter.backgroundTaskCapacityExceeded()
  presenter.reloadCompleted("warning", "Reloaded with one diagnostic")
  fixture.emitCompaction({ type: "failed", message: "Compaction produced an empty summary" })
  fixture.emitCompaction({ type: "completed" })

  expect(fixture.claim).toEqual({
    key: "zi.system",
    capacity: 8,
    config: { name: false, icon: false, ttl: 5, priority: 20 }
  })
  expect(fixture.published).toEqual([
    persistentNotice("bootstrap", "Saved model unavailable"),
    persistentNotice("extensions", "Extension bad.ts: Cannot find module"),
    persistentNotice("project-trust", "Project configuration is disabled"),
    finiteNotice("copy", "Copy failed; the selection was preserved", 3, 5, false),
    finiteNotice("copy", "Copied last assistant message to clipboard", 2, 4, false),
    finiteNotice("shell-capacity", "Background task capacity exceeded", 3, 5, false),
    finiteNotice("reload", "Reloaded with one diagnostic", 3, Infinity),
    finiteNotice("automatic-compaction", "Compaction produced an empty summary", 4, Infinity)
  ])
  expect(fixture.removed).toEqual(["copy", "prompt", "extensions", "reload", "automatic-compaction"])

  fixture.removed.length = 0
  fixture.generation.set(1)
  expect(fixture.removed).toEqual([
    "bootstrap",
    "extensions",
    "project-trust",
    "automatic-compaction",
    "copy",
    "shell-capacity",
    "reload",
    "prompt"
  ])

  presenter.dispose()
  expect(fixture.released).toBe(true)
  expect(fixture.producerDisposed).toBe(true)
  fixture.emitCompaction({ type: "failed", message: "stale" })
  expect(fixture.published).toHaveLength(8)
})

test("prompt notices replace one stable key with policy-specific lifetimes", () => {
  const fixture = createFixture()
  const presenter = new BuiltInNotificationPresenter(fixture.source, fixture.owner)
  fixture.removed.length = 0

  presenter.promptProgress("Running command…")
  presenter.promptInfo("Command completed")
  presenter.promptWarning("Command needs attention")
  presenter.promptError("Command failed")
  presenter.clearPrompt()

  expect(fixture.published).toEqual([
    { key: "prompt", message: "Running command…", level: 2, options: { ttl: Infinity, skip_history: true } },
    finiteNotice("prompt", "Command completed", 2, 4, false),
    finiteNotice("prompt", "Command needs attention", 3, 5, false),
    finiteNotice("prompt", "Command failed", 4, Infinity, false)
  ])
  expect(fixture.removed).toEqual(["prompt"])
  presenter.dispose()
})

test("settled prompt outcomes re-enter history after in-flight progress", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme)
  const source = { $generation: atom(0), subscribeAutomaticCompaction: () => () => {} }
  const presenter = new BuiltInNotificationPresenter(source, center)

  try {
    presenter.promptProgress("Running command…")
    presenter.promptError("Command failed")
    presenter.clearPrompt()

    expect(center.get_history({ group_key: "zi.system", include_active: false }).map(item => item.message)).toEqual([
      "Command failed"
    ])
  } finally {
    presenter.dispose()
    center.dispose()
    setup.renderer.destroy()
  }
})

test("built-in diagnostics are bounded before notification admission", () => {
  const fixture = createFixture()
  const presenter = new BuiltInNotificationPresenter(fixture.source, fixture.owner)

  presenter.setBootstrap("é".repeat(maxNotificationMessageBytes))

  const message = fixture.published[0]?.message
  expect(typeof message).toBe("string")
  expect(Buffer.byteLength(message ?? "")).toBeLessThanOrEqual(maxNotificationMessageBytes)
  expect(message).toEndWith("…")
  presenter.dispose()
})

test("successful reload notices are finite informational outcomes", () => {
  const fixture = createFixture()
  const presenter = new BuiltInNotificationPresenter(fixture.source, fixture.owner)
  fixture.removed.length = 0

  presenter.reloadCompleted("success", "Reloaded settings, resources, and extensions")

  expect(fixture.removed).toEqual(["prompt", "extensions", "reload"])
  expect(fixture.published).toEqual([finiteNotice("reload", "Reloaded settings, resources, and extensions", 2, 4)])
  presenter.dispose()
})

test("filtered reload recovery removes a persistent error before publishing success", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { filter: 3 })
  const source = { $generation: atom(0), subscribeAutomaticCompaction: () => () => {} }
  const presenter = new BuiltInNotificationPresenter(source, center)

  try {
    presenter.reloadFailed("Reload failed")
    expect(center.get_history({ group_key: "zi.system", include_removed: false })).toHaveLength(1)

    presenter.reloadCompleted("success", "Reloaded")
    expect(center.get_history({ group_key: "zi.system", include_removed: false })).toEqual([])
  } finally {
    presenter.dispose()
    center.dispose()
    setup.renderer.destroy()
  }
})

test("a thrown reload preserves the still-authoritative extension diagnostic", () => {
  const fixture = createFixture()
  const presenter = new BuiltInNotificationPresenter(fixture.source, fixture.owner)
  fixture.removed.length = 0

  presenter.setExtension("Existing extension diagnostic")
  presenter.reloadFailed("Reload failed before replacement")

  expect(fixture.removed).toEqual(["prompt", "reload"])
  expect(fixture.published).toEqual([
    persistentNotice("extensions", "Existing extension diagnostic"),
    finiteNotice("reload", "Reload failed before replacement", 4, Infinity)
  ])
  presenter.dispose()
})

test("built-in notification construction releases its claim when subscription fails", () => {
  const fixture = createFixture()
  const source = {
    $generation: fixture.generation,
    subscribeAutomaticCompaction(): () => void {
      throw new Error("subscription failed")
    }
  }

  expect(() => new BuiltInNotificationPresenter(source, fixture.owner)).toThrow("subscription failed")
  expect(fixture.producerDisposed).toBe(true)
})

function createFixture() {
  const generation = atom(0)
  const published: PublishedNotice[] = []
  const removed: (string | number)[] = []
  let compactionListener: ((event: AutomaticCompactionNoticeEvent) => void) | undefined
  let released = false
  let producerDisposed = false
  let claim: { key: string | number; capacity: number; config: NotificationGroupConfig } | undefined
  const producer: NotificationGroupProducer = {
    notify: (key, message, level, options) => published.push({ key, message, level, options }),
    remove: key => {
      removed.push(key)
      return true
    },
    dispose: () => {
      producerDisposed = true
    }
  }
  const owner: Pick<NotificationCenter, "claimGroup"> = {
    claimGroup(key, config, capacity) {
      claim = { key, capacity, config }
      return producer
    }
  }
  const source = {
    $generation: generation,
    subscribeAutomaticCompaction(listener: (event: AutomaticCompactionNoticeEvent) => void) {
      compactionListener = listener
      return () => {
        released = true
        compactionListener = undefined
      }
    }
  }
  return {
    generation,
    owner,
    source,
    published,
    removed,
    emitCompaction: (event: AutomaticCompactionNoticeEvent) => compactionListener?.(event),
    get claim() {
      return claim
    },
    get released() {
      return released
    },
    get producerDisposed() {
      return producerDisposed
    }
  }
}

function persistentNotice(key: string, message: string): PublishedNotice {
  return { key, message, level: 3, options: { ttl: Infinity, skip_history: true } }
}

function finiteNotice(
  key: string,
  message: string,
  level: NotificationLevel,
  ttl: number,
  skipHistory?: boolean
): PublishedNotice {
  return { key, message, level, options: skipHistory === undefined ? { ttl } : { ttl, skip_history: skipHistory } }
}

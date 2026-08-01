import { expect, test } from "bun:test"

import { BoxRenderable, TextRenderable } from "@opentui/core"
import { createTestRenderer } from "@opentui/core/testing"
import { createModels, createTestAgentRuntime as createAgentRuntime, fauxProvider } from "@with-zi/coding-agent/testing"

import { InteractiveMode } from "../../src/interactive/interactive-mode.js"
import {
  maxNotificationDataBytes,
  maxNotificationDataDepth,
  maxNotificationDataNodes,
  maxNotificationMessageBytes,
  NotificationCenter,
  type NotificationData
} from "../../src/interactive/notifications.js"
import { defaultTheme } from "../../src/theme.js"
import { createInteractiveTest } from "./harness.js"

test("keyed notifications update in place without extending ttl implicitly", async () => {
  const setup = await createTestRenderer({ width: 50, height: 10, useThread: false })
  let now = 1_000
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => now })
  const host = new BoxRenderable(setup.renderer, { width: "100%", height: "100%", position: "relative" })
  setup.renderer.root.add(host)
  center.attach(host)

  try {
    center.notify("Indexing", 2, { key: "index", ttl: 10, data: { step: 1 } })
    now = 1_003
    center.notify(null, 3, { key: "index", annote: "3/5", hidden: true, data: { step: 3 } })

    expect(center.get_history()).toEqual([
      expect.objectContaining({
        key: "index",
        message: "Indexing",
        annote: "3/5",
        level: 3,
        hidden: true,
        expires_at: 1_010,
        last_updated: 1_003,
        data: { step: 3 },
        removed: false
      })
    ])

    center.notify(null, null, { key: "index", hidden: false, annote: null })
    expect(center.get_history()[0]).toEqual(
      expect.objectContaining({ message: "Indexing", hidden: false, expires_at: 1_010 })
    )
    expect(center.get_history()[0]).not.toHaveProperty("annote")
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("update-only and nil messages do not create notifications", async () => {
  const setup = await createTestRenderer({ width: 30, height: 6, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => 0 })

  try {
    center.notify(null, 2, { key: "missing" })
    center.notify("still missing", 2, { key: "missing", update_only: true })
    expect(center.group_keys()).toEqual([])
    expect(center.get_history()).toEqual([])
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("group configuration controls metadata, lifetime, and active group keys", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => 0 })

  try {
    center.set_config("jobs", { name: "Jobs", icon: "↻", ttl: Infinity, priority: 10 }, true)
    center.notify("Building", 2, { key: "build", group: "jobs" })
    expect(center.group_keys()).toEqual(["jobs"])
    expect(center.get_history()[0]).toEqual(
      expect.objectContaining({
        group_key: "jobs",
        group_name: "Jobs",
        group_icon: "↻",
        expires_at: null,
        removed: false
      })
    )
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("producer-owned groups survive public mutation and active-item eviction", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { max_active: 2, now: () => 0 })
  const producer = center.claimGroup("zi.owned", { name: "Owned", ttl: Infinity, priority: 10 }, 1)

  try {
    center.set_config("default", { info_annote: "HIJACKED", annote_separator: " !!! " }, true)
    producer.notify("result", "Result", 2)
    expect(() => producer.notify("overflow", "Overflow", 2)).toThrow("cannot exceed 1 active items")
    center.notify("generic one", 2, { key: "one", ttl: Infinity })
    center.notify("generic two", 2, { key: "two", ttl: Infinity })
    center.notify("generic three", 2, { key: "three", ttl: Infinity })

    expect(center.get_history().map(item => [item.key, item.removed])).toEqual([
      ["result", false],
      ["two", false],
      ["three", false],
      ["one", true]
    ])
    expect(center.get_history("zi.owned")).toEqual([
      expect.objectContaining({ key: "result", message: "Result", annote: "INFO", removed: false })
    ])
    expect(() => center.notify("replace", 2, { key: "result", group: "zi.owned" })).toThrow("producer-owned")
    expect(() => center.remove("zi.owned", "result")).toThrow("producer-owned")
    expect(() => center.set_config("zi.owned", {}, true)).toThrow("producer-owned")

    center.clear()
    center.reset()
    expect(center.group_keys()).toEqual(["zi.owned"])
    expect(producer.remove("result")).toBe(true)
    expect(center.group_keys()).toEqual([])
    producer.dispose()
    expect(() => producer.notify("late", "late")).toThrow("producer is disposed")

    center.notify("past", 2, { key: "past", group: "past", ttl: Infinity })
    center.remove("past", "past")
    expect(() => center.claimGroup("past", {}, 1)).toThrow("already in use")
  } finally {
    producer.dispose()
    center.dispose()
    setup.renderer.destroy()
  }
})

test("active group priority changes reorder presentation immediately", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => 0 })

  try {
    center.set_config("later", { priority: 50 }, true)
    center.set_config("first", { priority: 10 }, true)
    center.notify("later", 2, { group: "later", ttl: Infinity })
    center.notify("first", 2, { group: "first", ttl: Infinity })
    expect(center.group_keys()).toEqual(["first", "later"])

    center.set_config("later", { priority: 1 }, true)
    expect(center.group_keys()).toEqual(["later", "first"])
    center.set_config("later", null)
    expect(center.group_keys()).toEqual(["first", "later"])
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("expiry, removal, clear, and bounded history preserve explicit lifecycle", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  let now = 0
  const center = new NotificationCenter(setup.renderer, defaultTheme, { history_size: 2, now: () => now })

  try {
    center.notify("one", 2, { key: 1, group: "jobs", ttl: 1 })
    center.notify("two", 3, { key: 2, group: "jobs", ttl: Infinity })
    now = 1
    expect(center.get_history()).toEqual([
      expect.objectContaining({ key: 2, removed: false }),
      expect.objectContaining({ key: 1, removed: true, last_updated: 1 })
    ])

    expect(center.remove("jobs", 2)).toBe(true)
    center.notify("three", 4, { key: 3, group: "jobs", ttl: Infinity })
    center.clear("jobs")
    expect(center.group_keys()).toEqual([])
    expect(center.get_history({ include_active: false }).map(item => item.key)).toEqual([2, 3])
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("suppression, close, and reset are distinct surface transitions", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => 0 })
  const host = new BoxRenderable(setup.renderer, { width: "100%", height: "100%", position: "relative" })
  setup.renderer.root.add(host)
  center.attach(host)

  try {
    center.notify("persistent", 2, { key: "item", ttl: Infinity })
    expect(center.root.visible).toBe(true)
    expect(center.close()).toBe(true)
    expect(center.close()).toBe(true)
    expect(center.root.visible).toBe(false)
    center.get_history()
    expect(center.root.visible).toBe(false)
    center.notify(null, null, { key: "item", annote: "UPDATED" })
    expect(center.root.visible).toBe(true)

    center.suppress(true)
    expect(center.root.visible).toBe(false)
    center.reset()
    center.notify("new", 2, { ttl: Infinity })
    expect(center.root.visible).toBe(false)
    center.suppress(false)
    expect(center.root.visible).toBe(true)
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("finite ttl owns one balanced renderer live request", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  let now = 0
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => now })
  const baseline = setup.renderer.liveRequestCount

  try {
    center.notify("one", 2, { ttl: 1 })
    center.notify("two", 2, { ttl: 2 })
    expect(setup.renderer.liveRequestCount).toBe(baseline + 1)
    now = 2
    center.get_history()
    expect(setup.renderer.liveRequestCount).toBe(baseline)
    center.notify("persistent", 2, { ttl: Infinity })
    expect(setup.renderer.liveRequestCount).toBe(baseline)
  } finally {
    center.dispose()
    expect(setup.renderer.liveRequestCount).toBe(baseline)
    setup.renderer.destroy()
  }
})

test("history filters use item age and group", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  let now = 0
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => now })

  try {
    center.notify("old", 2, { key: "old", group: "a", ttl: Infinity })
    now = 5
    center.notify("new", 2, { key: "new", group: "b", ttl: Infinity })
    now = 7

    expect(center.get_history({ before: 6 }).map(item => item.key)).toEqual(["old"])
    expect(center.get_history({ since: 3 }).map(item => item.key)).toEqual(["new"])
    expect(center.get_history("b").map(item => item.key)).toEqual(["new"])
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("notification state and external text are bounded", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { max_active: 2, history_size: 1, now: () => 0 })

  try {
    center.notify("filtered", 1, { key: 0, ttl: Infinity })
    const data = { step: 1 }
    center.notify("one", 2, { key: 1, ttl: Infinity, data })
    data.step = 2
    center.notify("two", 2, { key: 2, ttl: Infinity })
    center.notify("three", 2, { key: 3, ttl: Infinity })
    expect(center.get_history().map(item => [item.key, item.removed])).toEqual([
      [2, false],
      [3, false],
      [1, true]
    ])
    expect(center.get_history({ include_active: false })[0]?.data).toEqual({ step: 1 })
    expect(() => center.notify("x".repeat(maxNotificationMessageBytes + 1))).toThrow("message cannot exceed")
    expect(() => center.notify("large data", 2, { data: "x".repeat(maxNotificationDataBytes + 1) })).toThrow(
      "data cannot exceed"
    )
    let deep: Record<string, NotificationData> = {}
    const root = deep
    for (let depth = 0; depth <= maxNotificationDataDepth; depth++) {
      const child: Record<string, NotificationData> = {}
      deep.child = child
      deep = child
    }
    expect(() => center.notify("deep data", 2, { data: root })).toThrow("cannot exceed depth")
    expect(() => center.notify("wide data", 2, { data: Array(maxNotificationDataNodes + 1).fill(null) })).toThrow(
      "cannot exceed 4096 nodes"
    )
    const cyclic: Record<string, NotificationData> = {}
    cyclic.self = cyclic
    expect(() => center.notify("cyclic data", 2, { data: cyclic })).toThrow("bounded JSON")
    const prototypeKey = JSON.parse('{"__proto__":{"safe":true}}')
    center.notify("prototype key", 2, { key: "prototype", ttl: Infinity, data: prototypeKey })
    expect(center.get_history().find(item => item.key === "prototype")?.data).toEqual(prototypeKey)
    let getterRead = false
    const accessor = {
      get value() {
        getterRead = true
        return 1
      }
    }
    expect(() => center.notify("accessor data", 2, { data: accessor })).toThrow("bounded JSON")
    expect(getterRead).toBe(false)
    expect(() => center.notify("bad annotation", 2, { annote: "two\nlines" })).toThrow("single-line")
    expect(() => center.set_config("bad\ngroup", {}, true)).toThrow("single-line")
    expect(() => new NotificationCenter(setup.renderer, defaultTheme, { max_active: 129 })).toThrow("through 128")
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("hidden items do not consume the global visible-item bound", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { max_visible: 1, now: () => 0 })
  const host = new BoxRenderable(setup.renderer, { width: "100%", height: "100%", position: "relative" })
  setup.renderer.root.add(host)
  center.attach(host)

  try {
    center.notify("hidden", 2, { hidden: true, ttl: Infinity })
    center.notify("visible", 2, { ttl: Infinity })
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("visible INFO")
    expect(setup.captureCharFrame()).not.toContain("hidden")
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("multiline presentation has a hard retained-row bound", async () => {
  const setup = await createTestRenderer({ width: 40, height: 20, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { max_visible_lines: 3, now: () => 0 })
  const host = new BoxRenderable(setup.renderer, { width: "100%", height: "100%", position: "relative" })
  setup.renderer.root.add(host)
  center.attach(host)

  try {
    center.notify(Array.from({ length: 100 }, (_, index) => `line ${index}`).join("\n"), 2, { ttl: Infinity })
    await setup.renderOnce()
    expect(center.root.height).toBe(3)
    const surface = center.root.getChildren()[0]
    if (!(surface instanceof TextRenderable)) throw new Error("Notification surface not found")
    expect(surface.height).toBe(3)
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

test("invalid notification options are rejected before interactive resources are acquired", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const models = createModels()
  models.setProvider(fauxProvider().provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const subscribers = session.memoryDiagnostics.subscribers
  const roots = setup.renderer.root.getChildren().length

  try {
    expect(
      () =>
        new InteractiveMode({
          renderer: setup.renderer,
          session,
          onExit: () => {},
          notificationOptions: { max_active: 0 }
        })
    ).toThrow("max_active")
    expect(session.memoryDiagnostics.subscribers).toBe(subscribers)
    expect(setup.renderer.root.getChildren()).toHaveLength(roots)
  } finally {
    session.dispose()
    setup.renderer.destroy()
  }
})

test("interactive notifications anchor to the transcript above the composer", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(session, { width: 40, height: 8 })

  try {
    setup.mode.notify("Ready", 2, { ttl: Infinity })
    await setup.renderOnce()
    const rows = setup.captureCharFrame().split("\n")
    expect(rows[3]).toEndWith(" Ready INFO  ")
    expect(rows[4]).toEndWith(" Notifications ❰❰  ")
    expect(rows[5]).toStartWith("╭─/work")
  } finally {
    session.dispose()
    setup.destroy()
  }
})

test("notification ownership survives session-screen replacement", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const first = await createAgentRuntime({ cwd: "/first", models, session: { type: "new", persist: false } })
  const second = await createAgentRuntime({ cwd: "/second", models, session: { type: "new", persist: false } })
  const setup = await createInteractiveTest(first.session, { width: 40, height: 8 })

  try {
    setup.mode.notify("Still here", 2, { key: "stable", ttl: Infinity })
    setup.mode.replaceSession(second.session)
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("Still here INFO")
    expect(setup.mode.notifications.get_history()[0]).toEqual(
      expect.objectContaining({ key: "stable", removed: false })
    )
  } finally {
    first.session.dispose()
    second.session.dispose()
    setup.destroy()
  }
})

test("surface is bottom-right, stacks upwards, deduplicates, and never becomes selectable", async () => {
  const setup = await createTestRenderer({ width: 40, height: 8, useThread: false })
  const center = new NotificationCenter(setup.renderer, defaultTheme, { now: () => 0 })
  const host = new BoxRenderable(setup.renderer, { width: "100%", height: "100%", position: "relative" })
  setup.renderer.root.add(host)
  center.attach(host)

  try {
    center.notify("Indexed", 2, { ttl: Infinity })
    center.notify("Indexed", 2, { ttl: Infinity })
    center.notify("Failed", 4, { ttl: Infinity })
    await setup.renderOnce()

    const rows = setup.captureCharFrame().split("\n")
    expect(rows.slice(-4)).toEqual([
      "                          Failed ERROR  ",
      "                     (2x) Indexed INFO  ",
      "                      Notifications ❰❰  ",
      ""
    ])
    expect(center.root.x).toBeGreaterThan(0)
    expect(center.root.y).toBeGreaterThan(0)
    const surface = center.root.getChildren()[0]
    if (!(surface instanceof TextRenderable)) throw new Error("Notification surface not found")
    expect(surface.selectable).toBe(false)
  } finally {
    center.dispose()
    setup.renderer.destroy()
  }
})

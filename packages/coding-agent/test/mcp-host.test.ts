import { afterEach, expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { IsSchema } from "typebox"
import { Compile } from "typebox/compile"

import type {
  McpLoadPlan,
  McpResolvedHttpServer,
  McpResolvedServer,
  McpResolvedStdioServer
} from "../src/mcp/config.js"
import {
  maxMcpCatalogRefreshConcurrency,
  maxMcpConcurrentCalls,
  maxMcpConnectionConcurrency,
  maxMcpReconnectAttempts,
  McpHost
} from "../src/mcp/host.js"
import { createMcpTools } from "../src/mcp/tools.js"
import { createProcessTreeTracker, type ProcessTreeTracker } from "../src/processes/process-tree.js"
import { createMcpHttpFixture, type McpHttpActivity, type McpHttpFixture } from "./fixtures/mcp-http-server.js"

const stdioFixture = fileURLToPath(new URL("./fixtures/mcp-host-server.ts", import.meta.url))
const owned: { host: McpHost; tracker: ProcessTreeTracker }[] = []
const httpFixtures: McpHttpFixture[] = []

afterEach(async () => {
  await Promise.all(owned.map(item => item.host.dispose()))
  await Promise.all(owned.map(item => item.host.waitForIdle()))
  await Promise.all(owned.map(item => item.tracker.dispose()))
  await Promise.all(httpFixtures.map(fixture => fixture.close()))
  owned.length = 0
  httpFixtures.length = 0
})

test("owned stdio catalogs search, describe, call, project results, and dispose", async () => {
  const { host } = await start("normal")
  const changes: string[] = []
  const unsubscribe = host.subscribe(name => changes.push(name))

  expect(host.snapshot()).toEqual([{ name: "fixture", transport: "stdio", status: "ready", tools: 10 }])
  expect(host.search("search", undefined, 2)).toEqual([
    { server: "fixture", tool: "search", description: "Exact source search" },
    { server: "fixture", tool: "search_code", description: "Search source code" }
  ])
  expect(host.describe("fixture", "raw/tool.name")).toMatchObject({
    server: "fixture",
    name: "raw/tool.name",
    description: "Preserve raw protocol identity"
  })

  const echo = await host.call("fixture", "echo", { value: "accepted" })
  expect(echo).toEqual({
    content: [{ type: "text", text: '{"value":"accepted"}' }],
    structuredContent: { value: "accepted" }
  })
  const progress: string[] = []
  await host.call("fixture", "slow", { delayMs: 5 }, undefined, message => progress.push(message))
  expect(progress).toContain("half complete")

  const rich = await host.call("fixture", "rich", {})
  expect(rich).toEqual({
    content: [
      { type: "text", text: "rich text" },
      { type: "omitted", contentType: "image", mimeType: "image/png" },
      { type: "omitted", contentType: "audio", mimeType: "audio/wav" },
      { type: "omitted", contentType: "resource" },
      { type: "omitted", contentType: "resource_link", mimeType: "text/plain" }
    ],
    structuredContent: { answer: 42 }
  })
  expect(JSON.stringify(rich)).not.toContain("aW1hZ2U")
  expect(JSON.stringify(rich)).not.toContain("secret")
  await expectFailure(host.call("fixture", "fail", {}), "fixture failure")
  const huge = await host.call("fixture", "huge", {})
  expect(Buffer.byteLength(JSON.stringify(huge))).toBeLessThanOrEqual(256 * 1024)
  const hugeText = huge.content[0]?.type === "text" ? huge.content[0].text : ""
  const omitted = hugeText.match(/\[(\d+) bytes omitted\]$/)?.[1]
  expect(hugeText).toContain("bytes omitted")
  expect(Number(omitted)).toBeGreaterThan(0)
  const many = await host.call("fixture", "many", {})
  expect(Buffer.byteLength(JSON.stringify(many))).toBeLessThanOrEqual(256 * 1024)
  expect(many.content.at(-1)).toEqual({ type: "omitted", contentType: "additional_blocks" })

  const tools = createMcpTools(host)
  expect(tools.map(tool => tool.name)).toEqual(["mcp_search", "mcp_describe", "mcp_call", "mcp_status"])
  const status = findTool(tools, "mcp_status")
  const statusResult = await status.codeMode.execute("status", {}, new AbortController().signal)
  expect(statusResult.value).toEqual([{ name: "fixture", transport: "stdio", status: "ready", tools: 10 }])

  unsubscribe()
  await host.dispose()
  await host.waitForIdle()
  expect(host.snapshot()).toEqual([])
  expect(changes).toEqual([])
})

test("subscriber failures cannot corrupt authoritative server transitions", async () => {
  const item = createHost()
  item.host.subscribe(() => {
    throw new Error("observer failed")
  })
  await item.host.start(loadPlan(serverPlan("normal", false)))
  expect(item.host.snapshot()).toEqual([{ name: "fixture", transport: "stdio", status: "ready", tools: 10 }])
})

test("startup admits the complete server set before observers can dispose it", async () => {
  const item = createHost()
  let observed: readonly string[] = []
  item.host.subscribe(() => {
    if (observed.length > 0) return
    observed = item.host
      .snapshot()
      .filter(snapshot => snapshot.status === "starting")
      .map(snapshot => snapshot.name)
    void item.host.dispose()
  })
  await expectFailure(
    item.host.start({
      servers: [
        { ...serverPlan("normal", false), name: "first" },
        { ...serverPlan("normal", false), name: "second" }
      ],
      diagnostics: []
    }),
    "cancelled"
  )
  await item.host.waitForIdle()
  expect(observed).toEqual(["first", "second"])
  expect(item.host.snapshot()).toEqual([])
})

test("required failures reject startup while optional and spawn failures remain isolated", async () => {
  const spawnFailure = createHost()
  await spawnFailure.host.start(
    loadPlan({
      ...serverPlan("normal", false),
      command: Object.freeze([join(tmpdir(), `zi-missing-mcp-${process.pid}`)])
    })
  )
  expect(spawnFailure.host.snapshot()).toEqual([
    expect.objectContaining({ name: "fixture", transport: "stdio", status: "failed" })
  ])
  expect(spawnFailure.host.search("echo")).toEqual([])

  const optional = createHost()
  await optional.host.start(loadPlan(serverPlan("exit", false)))
  expect(optional.host.snapshot()).toEqual([
    expect.objectContaining({ name: "fixture", transport: "stdio", status: "failed" })
  ])

  const required = createHost()
  await expectFailure(required.host.start(loadPlan(serverPlan("exit", true))), "Required MCP server fixture")
  expect(required.host.snapshot()).toEqual([
    expect.objectContaining({ name: "fixture", transport: "stdio", status: "failed" })
  ])

  const diagnostic = createHost()
  await expectFailure(
    diagnostic.host.start({
      servers: [],
      diagnostics: [{ name: "missing", required: true, message: "Executable is missing" }]
    }),
    "Executable is missing"
  )
  expect(JSON.stringify(diagnostic.host.snapshot())).not.toContain("TOKEN")
})

test("a connection closing during initial discovery cannot publish a ready catalog", async () => {
  const { host } = await start("close-after-list")
  await waitForStatus(host, "failed")

  expect(host.search("vanishing")).toEqual([])
  expect(() => host.describe("fixture", "vanishing")).toThrow("unavailable")
})

test("catalog candidates reject duplicate and oversized schemas without partial publication", async () => {
  const rejected = await Promise.all(["duplicate", "oversized"].map(mode => start(mode)))
  for (const { host } of rejected) {
    expect(host.snapshot()).toEqual([
      expect.objectContaining({ name: "fixture", transport: "stdio", status: "failed" })
    ])
    expect(host.search("same")).toEqual([])
    expect(() => host.describe("fixture", "same")).toThrow("unavailable")
  }

  const { host } = await start("task-required")
  expect(host.snapshot()).toEqual([
    { name: "fixture", transport: "stdio", status: "ready", tools: 1, message: "1 task-required MCP tool was omitted" }
  ])
  expect(host.search("deferred")).toEqual([])
  expect(() => host.describe("fixture", "deferred")).toThrow("Unknown MCP tool")
  await expectFailure(host.call("fixture", "deferred", {}), "Unknown MCP tool")
  expect((await host.call("fixture", "ordinary", { accepted: true })).structuredContent).toEqual({ accepted: true })
})

test("pagination publishes complete catalogs and rejects bounded candidates atomically", async () => {
  const paged = await start("paged")
  expect(paged.host.search("page").map(match => match.tool)).toEqual(["page_one", "page_two"])

  const rejectedModes = [
    "list-error-first",
    "list-error-second",
    "repeated-cursor",
    "empty-cursor",
    "oversized-cursor",
    "over-pages",
    "duplicate-pages",
    "too-many-tools",
    "oversized-output",
    "catalog-overflow"
  ]
  const rejected = await Promise.all(rejectedModes.map(mode => start(mode)))
  for (const { host } of rejected) {
    expect(host.snapshot()).toEqual([expect.objectContaining({ name: "fixture", status: "failed" })])
    expect(host.search("page")).toEqual([])
    expect(host.search("partial")).toEqual([])
  }
})

test("search ranking is ASCII-normalized, deterministic, filtered, and limited after ranking", async () => {
  const item = createHost()
  await item.host.start({
    servers: [
      { ...serverPlan("ranking-primary", false), name: "z-primary" },
      { ...serverPlan("ranking-primary", false), name: "a-primary" },
      { ...serverPlan("ranking-server", false), name: "needle" }
    ],
    diagnostics: []
  })

  expect(item.host.search("NeEdLe", undefined, 8).map(match => `${match.server}/${match.tool}`)).toEqual([
    "a-primary/needle",
    "z-primary/needle",
    "a-primary/a_needle",
    "a-primary/run_needle",
    "z-primary/a_needle",
    "z-primary/run_needle",
    "needle/server_hit",
    "a-primary/description_hit"
  ])
  expect(item.host.search("needle", "z-primary", 2).map(match => match.tool)).toEqual(["needle", "a_needle"])
})

test("list changes fetch before swap, coalesce one rerun, and retain the old catalog on failure", async () => {
  const { host } = await start("live-refresh")
  const changes: string[] = []
  host.subscribe(name => changes.push(name))

  await host.call("fixture", "refresh_control", { action: "refresh" })
  expect(host.search("old").map(match => match.tool)).toEqual(["old_tool"])
  expect((await host.call("fixture", "old_tool", { value: "still callable" })).structuredContent).toEqual({
    value: "still callable"
  })
  await host.waitForIdle()
  expect(host.search("new").map(match => match.tool)).toEqual(["new_page_one", "new_page_two"])
  expect(host.search("old")).toEqual([])

  await host.call("fixture", "refresh_control", { action: "refresh" })
  await Bun.sleep(10)
  await host.call("fixture", "refresh_control", { action: "rerun" })
  await host.waitForIdle()
  expect(host.search("final").map(match => match.tool)).toEqual(["final_tool"])
  const stats = await host.call("fixture", "refresh_control", { action: "stats" })
  expect(stats.structuredContent).toEqual({ listRequests: 6 })

  await host.call("fixture", "refresh_control", { action: "fail" })
  await host.waitForIdle()
  expect(host.search("final").map(match => match.tool)).toEqual(["final_tool"])
  expect(host.search("partial")).toEqual([])
  expect(host.snapshot()).toEqual([
    expect.objectContaining({ status: "ready", tools: 2, message: expect.stringContaining("Catalog refresh failed") })
  ])
  expect(changes).toEqual(["fixture", "fixture", "fixture", "fixture"])
})

test("disposal fences a blocked refresh from stale publication", async () => {
  const { host } = await start("live-refresh")
  const changes: string[] = []
  host.subscribe(name => changes.push(name))
  await host.call("fixture", "refresh_control", { action: "stale" })
  await Bun.sleep(10)
  await host.dispose()
  await host.waitForIdle()
  expect(host.snapshot()).toEqual([])
  expect(changes).toEqual([])
})

test("optional failures are isolated and required aggregate admission is deterministic", async () => {
  const isolated = createHost()
  await isolated.host.start({
    servers: [
      { ...serverPlan("normal", false), name: "ready" },
      { ...serverPlan("exit", false), name: "broken" }
    ],
    diagnostics: []
  })
  expect(isolated.host.search("echo", "ready").map(match => match.tool)).toEqual(["echo"])
  expect((await isolated.host.call("ready", "echo", { ok: true })).structuredContent).toEqual({ ok: true })
  expect(isolated.host.snapshot()).toEqual([
    expect.objectContaining({ name: "broken", status: "failed" }),
    expect.objectContaining({ name: "ready", status: "ready" })
  ])

  const requiredFailure = createHost()
  await expectFailure(
    requiredFailure.host.start({
      servers: [
        { ...serverPlan("normal", false), name: "peer" },
        { ...serverPlan("exit", true), name: "required-broken" }
      ],
      diagnostics: []
    }),
    "Required MCP server required-broken failed"
  )
  expect(requiredFailure.host.snapshot().some(snapshot => snapshot.status === "ready")).toBe(false)
  expect(() => requiredFailure.host.search("echo")).toThrow("after MCP host disposal")

  const prioritized = createHost()
  await prioritized.host.start({
    servers: [
      { ...serverPlan("maximum", false), name: "optional-fast" },
      { ...serverPlan("maximum-slow", true), name: "required-slow" },
      { ...serverPlan("maximum", false), name: "optional-last" }
    ],
    diagnostics: []
  })
  expect(prioritized.host.snapshot()).toEqual([
    expect.objectContaining({ name: "optional-fast", status: "ready" }),
    expect.objectContaining({ name: "optional-last", status: "failed" }),
    expect.objectContaining({ name: "required-slow", status: "ready" })
  ])
})

test("disposal during deterministic startup cleanup cannot resurrect the host", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-start-dispose-"))
  const closeMarker = join(root, "closing")
  const item = createHost()
  const starting = item.host.start({
    servers: [
      { ...serverPlan("maximum", true), name: "required" },
      { ...serverPlan("maximum", false), name: "optional-ready" },
      {
        ...serverPlan("maximum-stubborn", false),
        name: "optional-closing",
        environment: { PATH: process.env.PATH ?? "", MCP_CLOSE_MARKER: closeMarker }
      }
    ],
    diagnostics: []
  })

  await waitForPath(closeMarker)
  const disposal = item.host.dispose()

  await expectFailure(starting, "cancelled")
  await disposal
  await item.host.waitForIdle()
  expect(item.host.snapshot()).toEqual([])
  expect(() => item.host.search("maximum")).toThrow("after MCP host disposal")
})

test("aggregate ready catalogs stay within the host byte reservation", async () => {
  const item = createHost()
  const left = { ...serverPlan("bulky", false), name: "left" }
  const middle = { ...serverPlan("bulky", false), name: "middle" }
  const right = { ...serverPlan("bulky", false), name: "right" }
  await item.host.start({ servers: [left, middle, right], diagnostics: [] })
  const snapshots = item.host.snapshot()
  expect(snapshots.filter(snapshot => snapshot.status === "ready")).toHaveLength(2)
  expect(snapshots.filter(snapshot => snapshot.status === "failed")).toHaveLength(1)
})

test("cancellation and deadlines settle calls without replay", async () => {
  const deadlinePlan = serverPlan("normal", false, 30)
  const deadline = createHost()
  await deadline.host.start(loadPlan(deadlinePlan))
  await expectFailure(deadline.host.call("fixture", "slow", { delayMs: 100 }), "deadline exceeded")
  await Bun.sleep(120)
  const count = await deadline.host.call("fixture", "counter", {})
  expect(count.structuredContent).toEqual({ calls: 2 })

  const cancelled = await start("normal")
  const controller = new AbortController()
  const call = cancelled.host.call("fixture", "slow", { delayMs: 100 }, controller.signal)
  controller.abort()
  await expectFailure(call, "cancelled")
})

test("server-controlled projections redact configured values and progress observers cannot corrupt calls", async () => {
  const secret = "slice-four-secret"
  const reflected = createHost()
  await reflected.host.start(
    loadPlan({
      ...serverPlan("reflect-secret", false),
      environment: Object.freeze({ PATH: process.env.PATH ?? "", MCP_REFLECTED_SECRET: secret }),
      redactionValues: Object.freeze([secret])
    })
  )

  expect(JSON.stringify(reflected.host.search("rich"))).not.toContain(secret)
  expect(reflected.host.search(secret)).toEqual([])
  expect(() => reflected.host.describe("fixture", secret)).toThrow("Unknown MCP tool")
  const descriptor = JSON.stringify(reflected.host.describe("fixture", "rich"))
  expect(descriptor).toContain("[redacted]")
  expect(descriptor).not.toContain(secret)

  const progress: string[] = []
  await reflected.host.call("fixture", "slow", { delayMs: 5 }, undefined, message => progress.push(message))
  expect(progress).toEqual(["[redacted]"])
  await reflected.host.call("fixture", "slow", { delayMs: 5 }, undefined, () => {
    throw new Error("observer failed")
  })
  expect(reflected.host.snapshot()[0]?.status).toBe("ready")

  const value = await reflected.host.call("fixture", "rich", {})
  expect(JSON.stringify(value)).toContain("[redacted]")
  expect(JSON.stringify(value)).not.toContain(secret)
  const failure = await failureMessage(reflected.host.call("fixture", "fail", {}))
  expect(failure).toContain("[redacted]")
  expect(failure).not.toContain(secret)

  const header = httpFixture("reflect-header")
  const remote = createHost()
  await remote.host.start(loadPlan(httpPlan("remote", header.url, { "x-fixture-token": secret })))
  expect(remote.host.search(secret)).toEqual([])
  expect(() => remote.host.describe("remote", secret)).toThrow("Unknown MCP tool")
  const remoteDescriptor = JSON.stringify(remote.host.describe("remote", "echo"))
  expect(remoteDescriptor).toContain("[redacted]")
  expect(remoteDescriptor).not.toContain(secret)
  const remoteValue = JSON.stringify(await remote.host.call("remote", "echo", {}))
  expect(remoteValue).toContain("[redacted]")
  expect(remoteValue).not.toContain(secret)
})

test("reload replaces a generation when only redaction provenance changes", async () => {
  const sensitive = "reload-sensitive-value"
  const item = createHost()
  const initial = Object.freeze({
    ...serverPlan("normal", false),
    environment: Object.freeze({ PATH: process.env.PATH ?? "", FIXTURE_VALUE: sensitive })
  })
  await item.host.start(loadPlan(initial))
  expect(JSON.stringify(await item.host.call("fixture", "echo", { value: sensitive }))).toContain(sensitive)

  const redacted = Object.freeze({ ...initial, redactionValues: Object.freeze([sensitive]) })
  expect(await item.host.reload(loadPlan(redacted))).toEqual({ failures: [] })
  const hidden = JSON.stringify(await item.host.call("fixture", "echo", { value: sensitive }))
  expect(hidden).toContain("[redacted]")
  expect(hidden).not.toContain(sensitive)

  const restored = Object.freeze({ ...initial, redactionValues: Object.freeze([]) })
  expect(await item.host.reload(loadPlan(restored))).toEqual({ failures: [] })
  expect(JSON.stringify(await item.host.call("fixture", "echo", { value: sensitive }))).toContain(sensitive)
})

test("progress followed by stdio exit fails one call and removes the catalog", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-progress-exit-"))
  const calls = join(root, "calls")
  const item = createHost()
  await item.host.start(
    loadPlan({
      ...serverPlan("progress-exit", false),
      environment: Object.freeze({ PATH: process.env.PATH ?? "", MCP_CALL_FILE: calls })
    })
  )
  const progress: string[] = []

  await expectFailure(
    item.host.call("fixture", "progress_exit", {}, undefined, message => progress.push(message)),
    "lost"
  )
  await waitForStatus(item.host, "failed")
  expect(progress).toEqual(["before exit"])
  expect(item.host.search("progress_exit")).toEqual([])
  expect(await readFile(calls, "utf8")).toBe("call\n")
  await Bun.sleep(150)
  expect(await readFile(calls, "utf8")).toBe("call\n")
})

test("call admission enforces the active concurrency bound", async () => {
  const { host } = await start("normal", 1_000)
  const calls = Array.from({ length: maxMcpConcurrentCalls }, () => host.call("fixture", "slow", { delayMs: 80 }))
  await expectFailure(host.call("fixture", "slow", { delayMs: 80 }), "concurrency")
  await Promise.all(calls)
})

test("snapshots omit commands, environment values, and other connection secrets", async () => {
  const item = createHost()
  const plan = serverPlan("normal", false)
  await item.host.start(
    loadPlan({ ...plan, environment: { PATH: process.env.PATH ?? "", SECRET_TOKEN: "do-not-publish" } })
  )
  const encoded = JSON.stringify(item.host.snapshot())
  expect(encoded).not.toContain(stdioFixture)
  expect(encoded).not.toContain("do-not-publish")
  expect(encoded).not.toContain("SECRET_TOKEN")

  const reflected = createHost()
  const reflectedPlan = serverPlan("reflect-env-error", false)
  await reflected.host.start(
    loadPlan({
      ...reflectedPlan,
      environment: { PATH: process.env.PATH ?? "", MCP_REFLECTED_SECRET: "server-reflected-secret" },
      redactionValues: Object.freeze(["server-reflected-secret"])
    })
  )
  const reflectedStatus = JSON.stringify(reflected.host.snapshot())
  expect(reflectedStatus).toContain("[redacted]")
  expect(reflectedStatus).not.toContain("server-reflected-secret")
  expect(reflectedStatus).not.toContain("MCP_REFLECTED_SECRET")
})

test("HTTP startup, recovery, and catalog refreshes each admit at most four servers", async () => {
  const startupActivity: McpHttpActivity = { activeLists: 0, maxActiveLists: 0 }
  const startupFixture = httpFixture("slow-list", startupActivity)
  const startup = createHost()
  await startup.host.start(
    multiLoadPlan(...Array.from({ length: 5 }, (_, index) => httpPlan(`startup-${index}`, startupFixture.url)))
  )
  expect(startupActivity.maxActiveLists).toBe(maxMcpConnectionConcurrency)

  const recoveryActivity: McpHttpActivity = { activeLists: 0, maxActiveLists: 0 }
  const recoveryFixture = httpFixture("invalidate-once-slow-recovery", recoveryActivity)
  const recovery = createHost()
  await recovery.host.start(
    multiLoadPlan(...Array.from({ length: 5 }, (_, index) => httpPlan(`recovery-${index}`, recoveryFixture.url)))
  )
  recoveryActivity.activeLists = 0
  recoveryActivity.maxActiveLists = 0

  await Promise.allSettled(Array.from({ length: 5 }, (_, index) => recovery.host.call(`recovery-${index}`, "echo", {})))
  await waitFor(
    () =>
      recovery.host.snapshot().filter(snapshot => snapshot.status === "ready").length === 5 &&
      recoveryFixture.initializeCount >= 10
  )
  expect(recoveryActivity.maxActiveLists).toBe(maxMcpConnectionConcurrency)

  const refreshActivity: McpHttpActivity = { activeLists: 0, maxActiveLists: 0 }
  const refreshFixture = httpFixture("refresh-on-call", refreshActivity)
  const refresh = createHost()
  await refresh.host.start(
    multiLoadPlan(...Array.from({ length: 5 }, (_, index) => httpPlan(`refresh-${index}`, refreshFixture.url)))
  )
  refreshActivity.activeLists = 0
  refreshActivity.maxActiveLists = 0

  await Promise.all(Array.from({ length: 5 }, (_, index) => refresh.host.call(`refresh-${index}`, "echo", {})))
  await refresh.host.waitForIdle()

  expect(refreshFixture.posts.filter(method => method === "tools/list")).toHaveLength(10)
  expect(refreshActivity.maxActiveLists).toBe(maxMcpCatalogRefreshConcurrency)
})

test("streamable HTTP initializes, lists, calls, and keeps resolved headers out of status", async () => {
  const fixture = httpFixture()
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", fixture.url, { "x-fixture-token": "resolved-secret" })))

  expect(item.host.snapshot()).toEqual([{ name: "remote", transport: "streamable-http", status: "ready", tools: 1 }])
  expect(item.host.search("echo")).toEqual([{ server: "remote", tool: "echo", description: "HTTP fixture tool" }])
  expect(await item.host.call("remote", "echo", { value: true })).toEqual({ content: [{ type: "text", text: "echo" }] })
  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(fixture.headers).toContain("resolved-secret")
  expect(JSON.stringify(item.host.snapshot())).not.toContain("resolved-secret")
  expect(JSON.stringify(item.host.snapshot())).not.toContain(fixture.url)
})

test.each([
  ["oversized-body", "response body exceeds"],
  ["oversized-headers", "response headers exceed"],
  ["oversized-sse-line", "SSE line exceeds"],
  ["oversized-sse-event", "SSE event exceeds"]
] as const)("streamable HTTP rejects bounded response mode %s", async (mode, message) => {
  const fixture = httpFixture(mode)
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))
  expect(item.host.snapshot()).toEqual([
    expect.objectContaining({
      name: "remote",
      transport: "streamable-http",
      status: "failed",
      message: expect.stringContaining(message)
    })
  ])
})

test("terminal HTTP call failure is not replayed and a fresh client recovers availability", async () => {
  const fixture = httpFixture("invalidate-once")
  const item = createHost()
  const statuses: string[] = []
  item.host.subscribe(() => statuses.push(item.host.snapshot()[0]?.status ?? "removed"))
  const plan = loadPlan(httpPlan("remote", fixture.url))
  await item.host.start(plan)

  await expectFailure(item.host.call("remote", "echo", {}), "invalid session")
  await waitFor(() => item.host.snapshot()[0]?.status === "backoff")
  expect((await item.host.reload(plan)).failures).toEqual([
    expect.objectContaining({ name: "remote", message: expect.stringContaining("invalid session") })
  ])
  await waitForReady(item.host, () => fixture.initializeCount >= 2)

  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(fixture.initializeCount).toBe(2)
  expect(statuses).toContain("backoff")
  expect(item.host.snapshot()).toEqual([{ name: "remote", transport: "streamable-http", status: "ready", tools: 1 }])
})

test("HTTP timeout aborts one POST without replay or generation replacement", async () => {
  const fixture = httpFixture("slow-call")
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", fixture.url, Object.freeze({}), 50)))

  await expectFailure(item.host.call("remote", "echo", {}), "deadline exceeded")
  await Bun.sleep(300)

  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(fixture.initializeCount).toBe(1)
  expect(item.host.snapshot()[0]?.status).toBe("ready")
})

test("terminal HTTP fetch failure is not replayed and enters bounded recovery", async () => {
  const fixture = httpFixture("drop-call")
  const item = createHost()
  const statuses: string[] = []
  item.host.subscribe(() => statuses.push(item.host.snapshot()[0]?.status ?? "removed"))
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))

  await expectFailure(item.host.call("remote", "echo", {}), "HTTP request failed")
  await waitFor(() => statuses.includes("backoff"))

  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(statuses).toContain("backoff")
})

test("event-ID request streams resume by GET without replaying POST", async () => {
  const fixture = httpFixture("resume-call")
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))

  const result = await item.host.call("remote", "echo", {})

  expect(result).toEqual({ content: [{ type: "text", text: "resumed" }] })
  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(fixture.gets).toContain("resume-1")
})

test("SSE retry exhaustion removes availability and enters fresh-client recovery", async () => {
  const fixture = httpFixture("retry-exhaustion")
  const item = createHost()
  const statuses: string[] = []
  item.host.subscribe(() => statuses.push(item.host.snapshot()[0]?.status ?? "removed"))
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))
  const startedAt = Date.now()

  await expectFailure(item.host.call("remote", "echo", {}), "connection was lost")
  await waitForReady(item.host, () => fixture.initializeCount >= 2)

  expect(Date.now() - startedAt).toBeGreaterThanOrEqual(180)
  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(fixture.gets.filter(eventId => eventId === "retry-1")).toHaveLength(2)
  expect(statuses).toContain("backoff")
})

test("terminal HTTP refresh retires the stale catalog before fresh-client recovery", async () => {
  const fixture = httpFixture("terminal-refresh")
  const item = createHost()
  let staleCatalogInBackoff = false
  let readyAfterTerminalFailure = false
  item.host.subscribe(() => {
    const snapshot = item.host.snapshot()[0]
    if (snapshot?.status === "backoff") staleCatalogInBackoff = item.host.search("echo").length > 0
    if (snapshot?.status === "ready" && snapshot.message?.includes("Catalog refresh failed")) {
      readyAfterTerminalFailure = true
    }
  })
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))

  await item.host.call("remote", "echo", {})
  await waitForReady(item.host, () => fixture.initializeCount >= 2)

  expect(staleCatalogInBackoff).toBe(false)
  expect(readyAfterTerminalFailure).toBe(false)
  expect(fixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(item.host.snapshot()).toEqual([{ name: "remote", transport: "streamable-http", status: "ready", tools: 1 }])
})

test("fresh-client recovery exhausts five attempts and reload re-admits a failed server", async () => {
  const fixture = httpFixture("reconnect-exhaustion")
  const item = createHost()
  const plan = loadPlan(httpPlan("remote", fixture.url))
  await item.host.start(plan)

  await expectFailure(item.host.call("remote", "echo", {}), "invalid session")
  await waitFor(() => item.host.snapshot()[0]?.status === "failed", 5_000)
  expect(fixture.initializeCount).toBe(1 + maxMcpReconnectAttempts)

  const attempts = fixture.initializeCount
  await Bun.sleep(250)
  expect(fixture.initializeCount).toBe(attempts)

  fixture.allowRecovery()
  expect(await item.host.reload(plan)).toEqual({ failures: [] })
  expect(fixture.initializeCount).toBe(attempts + 1)
  expect(item.host.snapshot()[0]?.status).toBe("ready")
})

test("disposal cancels pending HTTP backoff and active calls without late effects", async () => {
  const backoffFixture = httpFixture("invalidate-once")
  const backoff = createHost()
  await backoff.host.start(loadPlan(httpPlan("backoff", backoffFixture.url)))
  await expectFailure(backoff.host.call("backoff", "echo", {}), "invalid session")
  await waitFor(() => backoff.host.snapshot()[0]?.status === "backoff")
  await backoff.host.dispose()
  await backoff.host.waitForIdle()
  await Bun.sleep(250)
  expect(backoffFixture.initializeCount).toBe(1)

  const activeFixture = httpFixture("slow-call")
  const active = createHost()
  await active.host.start(loadPlan(httpPlan("active", activeFixture.url)))
  const call = active.host.call("active", "echo", {})
  await waitFor(() => activeFixture.posts.includes("tools/call"))
  await active.host.dispose()
  await active.host.waitForIdle()
  await expectFailure(call, "disposed")
  await Bun.sleep(300)
  expect(activeFixture.posts.filter(method => method === "tools/call")).toHaveLength(1)
  expect(activeFixture.initializeCount).toBe(1)
})

test("mcp_status output schema accepts backoff snapshots", async () => {
  const fixture = httpFixture("invalidate-once")
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))
  await expectFailure(item.host.call("remote", "echo", {}), "invalid session")
  await waitFor(() => item.host.snapshot()[0]?.status === "backoff")

  const status = findTool(createMcpTools(item.host), "mcp_status")
  const result = await status.codeMode.execute("status", {}, new AbortController().signal)
  if (!IsSchema(status.codeMode.outputSchema)) throw new Error("Invalid mcp_status output schema")
  expect(Compile(status.codeMode.outputSchema).Check(result.value)).toBe(true)
})

test("reload retains identical servers and reconciles additions, changes, disables, and removals", async () => {
  const first = httpFixture()
  const second = httpFixture()
  const replacement = httpFixture()
  const item = createHost()
  const firstPlan = httpPlan("one", first.url)
  await item.host.start(loadPlan(firstPlan))

  expect(await item.host.reload(loadPlan(firstPlan))).toEqual({ failures: [] })
  expect(first.initializeCount).toBe(1)

  const secondPlan = httpPlan("two", second.url)
  expect(await item.host.reload(multiLoadPlan(firstPlan, secondPlan))).toEqual({ failures: [] })
  expect(first.initializeCount).toBe(1)
  expect(second.initializeCount).toBe(1)

  const replacementPlan = httpPlan("one", replacement.url)
  const disabled = Object.freeze({ name: "two", enabled: false as const })
  expect(await item.host.reload(multiLoadPlan(replacementPlan, disabled))).toEqual({ failures: [] })
  expect(first.initializeCount).toBe(1)
  expect(replacement.initializeCount).toBe(1)
  expect(item.host.snapshot()).toEqual([
    { name: "one", transport: "streamable-http", status: "ready", tools: 1 },
    { name: "two", status: "disabled" }
  ])

  expect(await item.host.reload(multiLoadPlan(disabled))).toEqual({ failures: [] })
  expect(item.host.snapshot()).toEqual([{ name: "two", status: "disabled" }])
})

test("reload retains the previous server for malformed candidates and reports replacement failures", async () => {
  const first = httpFixture()
  const invalid = httpFixture("oversized-body")
  const item = createHost()
  const firstPlan = httpPlan("remote", first.url)
  await item.host.start(loadPlan(firstPlan))

  const malformed = await item.host.reload(
    Object.freeze({
      servers: Object.freeze([]),
      diagnostics: Object.freeze([{ name: "remote", required: false, message: "invalid candidate" }])
    })
  )
  expect(malformed).toEqual({ failures: [{ name: "remote", message: "invalid candidate" }] })
  expect(first.initializeCount).toBe(1)
  expect(item.host.snapshot()[0]?.status).toBe("ready")

  const replacement = await item.host.reload(loadPlan(httpPlan("remote", invalid.url)))
  expect(replacement.failures).toEqual([
    expect.objectContaining({ name: "remote", message: expect.stringContaining("response body exceeds") })
  ])
  expect(item.host.snapshot()[0]?.status).toBe("failed")

  const retried = await item.host.reload(loadPlan(httpPlan("remote", invalid.url)))
  expect(retried.failures).toHaveLength(1)
  expect(invalid.initializeCount).toBe(2)
})

test("disposal supersedes a blocked HTTP reload without stale publication", async () => {
  const first = httpFixture()
  const slow = httpFixture("slow-list")
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", first.url)))
  const reload = item.host.reload(loadPlan(httpPlan("remote", slow.url)))
  await waitFor(() => slow.posts.includes("tools/list"))

  await item.host.dispose()
  await reload
  await item.host.waitForIdle()

  expect(item.host.snapshot()).toEqual([])
})

test("HTTP disposal cancels pending SSE recovery and settles the call", async () => {
  const fixture = httpFixture("retry-exhaustion")
  const item = createHost()
  await item.host.start(loadPlan(httpPlan("remote", fixture.url)))
  const call = item.host.call("remote", "echo", {})
  await waitFor(() => fixture.gets.includes("retry-1"))
  const recoveryRequests = fixture.gets.length

  await item.host.dispose()
  await item.host.waitForIdle()
  await expectFailure(call, "disposed")
  await Bun.sleep(250)
  expect(fixture.gets).toHaveLength(recoveryRequests)
  expect(fixture.initializeCount).toBe(1)
  expect(item.host.snapshot()).toEqual([])
})

async function start(mode: string, toolTimeoutMs = 1_000): Promise<{ host: McpHost; tracker: ProcessTreeTracker }> {
  const item = createHost()
  await item.host.start(loadPlan(serverPlan(mode, false, toolTimeoutMs)))
  return item
}

function createHost(): { host: McpHost; tracker: ProcessTreeTracker } {
  const tracker = createProcessTreeTracker()
  const item = { host: new McpHost(tracker), tracker }
  owned.push(item)
  return item
}

function serverPlan(mode: string, required: boolean, toolTimeoutMs = 1_000): McpResolvedStdioServer {
  return Object.freeze({
    name: "fixture",
    enabled: true,
    transport: "stdio",
    required,
    startupTimeoutMs: 1_000,
    toolTimeoutMs,
    command: Object.freeze([process.execPath, stdioFixture, mode]),
    cwd: process.cwd(),
    environment: Object.freeze({ PATH: process.env.PATH ?? "" }),
    redactionValues: Object.freeze([])
  })
}

function httpFixture(
  mode: Parameters<typeof createMcpHttpFixture>[0] = "normal",
  activity?: McpHttpActivity
): McpHttpFixture {
  const fixture = createMcpHttpFixture(mode, activity)
  httpFixtures.push(fixture)
  return fixture
}

function httpPlan(
  name: string,
  url: string,
  headers: Readonly<Record<string, string>> = Object.freeze({}),
  toolTimeoutMs = 2_000
): McpResolvedHttpServer {
  return Object.freeze({
    name,
    enabled: true,
    transport: "streamable-http",
    required: false,
    startupTimeoutMs: 2_000,
    toolTimeoutMs,
    url,
    headers: Object.freeze({ ...headers }),
    redactionValues: fixtureRedactionValues(url, headers)
  })
}

function fixtureRedactionValues(url: string, headers: Readonly<Record<string, string>>): readonly string[] {
  const values = [...Object.values(headers), url, new URL(url).search].filter(value => value.length > 0)
  return Object.freeze([...new Set(values)].toSorted((left, right) => right.length - left.length))
}

function loadPlan(server: McpResolvedServer): McpLoadPlan {
  return multiLoadPlan(server)
}

function multiLoadPlan(...servers: readonly McpResolvedServer[]): McpLoadPlan {
  return Object.freeze({ servers: Object.freeze(servers), diagnostics: Object.freeze([]) })
}

async function waitForReady(host: McpHost, evidence: () => boolean): Promise<void> {
  await waitFor(() => host.snapshot().some(snapshot => snapshot.status === "ready") && evidence())
}

async function waitFor(condition: () => boolean, timeoutMs = 3_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!condition()) {
    if (Date.now() >= deadline) throw new Error("MCP fixture evidence did not arrive")
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of transport settlement
    await Bun.sleep(10)
  }
}

async function waitForStatus(host: McpHost, status: "failed"): Promise<void> {
  const deadline = Date.now() + 2_000
  while (!host.snapshot().some(snapshot => snapshot.status === status)) {
    if (Date.now() >= deadline) throw new Error(`MCP host did not reach ${status} status`)
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of transport settlement
    await Bun.sleep(10)
  }
}

async function waitForPath(path: string): Promise<void> {
  const deadline = Date.now() + 2_000
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`MCP fixture did not observe transport close: ${path}`)
    // oxlint-disable-next-line no-await-in-loop -- bounded poll of fixture evidence
    await Bun.sleep(10)
  }
}

async function failureMessage(operation: Promise<unknown>): Promise<string> {
  const cause = await operation.then(
    () => undefined,
    failure => failure
  )
  if (!(cause instanceof Error)) throw new Error("Expected operation to fail with an Error")
  return cause.message
}

async function expectFailure(operation: Promise<unknown>, message: string): Promise<void> {
  const outcome = await operation.then(
    () => ({ type: "succeeded" as const }),
    cause => ({ type: "failed" as const, cause })
  )
  if (outcome.type === "succeeded") throw new Error(`Expected operation to fail with: ${message}`)
  if (!(outcome.cause instanceof Error)) throw new Error("Expected operation to fail with an Error")
  expect(outcome.cause.message).toContain(message)
}

function findTool(tools: ReturnType<typeof createMcpTools>, name: string) {
  const tool = tools.find(candidate => candidate.name === name)
  if (!tool) throw new Error(`Missing MCP facade tool: ${name}`)
  return tool
}

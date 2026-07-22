import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import { maxSettingsFileBytes, SettingsManager } from "../src/settings-manager.js"

test("settings resolve global, then project, then construction overrides", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({
      defaultProvider: "global",
      defaultModel: "model",
      defaultThinkingLevel: "low",
      steeringMode: "all"
    })
  )
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({ defaultProvider: "project", defaultModel: "model", defaultThinkingLevel: "high" })
  )

  const settings = SettingsManager.create(paths, { defaultThinkingLevel: "medium" })

  expect(settings.get()).toEqual({
    defaultProvider: "project",
    defaultModel: "model",
    defaultThinkingLevel: "medium",
    steeringMode: "all",
    followUpMode: "one-at-a-time",
    retryEnabled: true,
    retryMaxRetries: 3,
    retryBaseDelayMs: 2_000,
    compactionEnabled: true,
    compactionReserveTokens: 16_384,
    compactionKeepRecentTokens: 20_000
  })
})

test("retry settings layer and reject unbounded backoff", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-retry-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ retryEnabled: false, retryMaxRetries: 1, retryBaseDelayMs: 1_000 })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ retryEnabled: true, retryMaxRetries: 2 }))

  const settings = SettingsManager.create(paths)
  expect(settings.get()).toMatchObject({ retryEnabled: true, retryMaxRetries: 2, retryBaseDelayMs: 1_000 })

  await writeFile(paths.projectSettingsFile, JSON.stringify({ retryMaxRetries: 4 }))
  settings.reload()
  expect(settings.get()).toMatchObject({ retryEnabled: false, retryMaxRetries: 1, retryBaseDelayMs: 1_000 })
  expect(settings.drainErrors()[0]?.error.message).toContain("retryMaxRetries")

  // oxlint-disable-next-line typescript/unbound-method -- Reflect models an untyped JavaScript SDK caller.
  expect(() => Reflect.apply(settings.updateGlobal, settings, [{ retryBaseDelayMs: 17_001 }])).toThrow(
    "Invalid retryBaseDelayMs"
  )
})

test("compaction settings layer and validate bounded persisted values", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-compaction-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ compactionEnabled: false, compactionReserveTokens: 10 }))
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({ compactionEnabled: true, compactionKeepRecentTokens: 20 })
  )

  const settings = SettingsManager.create(paths)
  expect(settings.get()).toMatchObject({
    compactionEnabled: true,
    compactionReserveTokens: 10,
    compactionKeepRecentTokens: 20
  })

  await writeFile(paths.projectSettingsFile, JSON.stringify({ compactionReserveTokens: 0 }))
  settings.reload()
  expect(settings.get().compactionReserveTokens).toBe(10)
  expect(settings.drainErrors()[0]?.error.message).toContain("compactionReserveTokens")
  // oxlint-disable-next-line typescript/unbound-method -- Reflect models an untyped JavaScript SDK caller.
  expect(() => Reflect.apply(settings.updateGlobal, settings, [{ compactionKeepRecentTokens: 0 }])).toThrow(
    "Invalid compactionKeepRecentTokens"
  )
})

test("global and project updates preserve fields owned by newer versions", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ defaultProvider: "old", defaultModel: "model", future: { enabled: true } })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "low", futureProject: 1 }))
  const settings = SettingsManager.create(paths)

  settings.updateGlobal({ defaultProvider: "new", defaultModel: "model" })
  settings.updateProject({ defaultThinkingLevel: "high" })

  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({
    defaultProvider: "new",
    defaultModel: "model",
    future: { enabled: true }
  })
  expect(JSON.parse(await readFile(paths.projectSettingsFile, "utf8"))).toEqual({
    defaultThinkingLevel: "high",
    futureProject: 1
  })
  expect(settings.get()).toMatchObject({ defaultProvider: "new", defaultModel: "model", defaultThinkingLevel: "high" })
})

test("a home-directory project does not mirror one settings file across both scopes", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-home-"))
  const paths = new OpenZiPaths(root, join(root, ".openzi"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ defaultProvider: "old", defaultModel: "model", defaultThinkingLevel: "low" })
  )
  const settings = SettingsManager.create(paths)

  settings.updateGlobal({ defaultProvider: "new", defaultModel: "model" })
  settings.updateProject({ defaultThinkingLevel: "high" })

  expect(settings.get()).toMatchObject({ defaultProvider: "new", defaultModel: "model", defaultThinkingLevel: "high" })
  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({
    defaultProvider: "new",
    defaultModel: "model",
    defaultThinkingLevel: "high"
  })
})

test("an invalid project scope reports a diagnostic without hiding valid global settings", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-invalid-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ defaultProvider: "global", defaultModel: "model", defaultThinkingLevel: "low" })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "turbo" }))

  const settings = SettingsManager.create(paths)

  expect(settings.get()).toMatchObject({
    defaultProvider: "global",
    defaultModel: "model",
    defaultThinkingLevel: "low"
  })
  expect(settings.drainErrors()).toMatchObject([
    {
      scope: "project",
      path: paths.projectSettingsFile,
      error: { message: expect.stringContaining("defaultThinkingLevel") }
    }
  ])
  expect(settings.drainErrors()).toEqual([])
})

test("writes refuse to overwrite an invalid settings scope", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-invalid-write-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  const malformed = '{"defaultThinkingLevel":"turbo"}'
  await writeFile(paths.projectSettingsFile, malformed)
  const settings = SettingsManager.create(paths)

  expect(() => settings.updateProject({ defaultThinkingLevel: "high" })).toThrow(
    "Cannot update invalid project settings"
  )
  expect(await readFile(paths.projectSettingsFile, "utf8")).toBe(malformed)
  expect(settings.get().defaultThinkingLevel).toBeUndefined()
})

test("reload recovers an invalid scope after the file is corrected", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-reload-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, '{"defaultThinkingLevel":"turbo"}')
  const settings = SettingsManager.create(paths)

  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "high" }))
  settings.reload()

  expect(settings.get().defaultThinkingLevel).toBe("high")
  expect(settings.getProject()).toEqual({ defaultThinkingLevel: "high" })
  expect(settings.drainErrors()).toEqual([])
})

test("oversized settings are bounded and reported without entering effective state", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-bound-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, " ".repeat(maxSettingsFileBytes + 1))

  const settings = SettingsManager.create(paths)

  expect(settings.get()).toEqual({
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    retryEnabled: true,
    retryMaxRetries: 3,
    retryBaseDelayMs: 2_000,
    compactionEnabled: true,
    compactionReserveTokens: 16_384,
    compactionKeepRecentTokens: 20_000
  })
  expect(settings.drainErrors()[0]?.error.message).toContain(`${maxSettingsFileBytes} bytes`)
})

test("a settings update cannot serialize beyond the file bound", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-write-bound-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  const original = JSON.stringify({ future: "x".repeat(maxSettingsFileBytes - 30) })
  expect(Buffer.byteLength(original)).toBeLessThan(maxSettingsFileBytes)
  await writeFile(paths.globalSettingsFile, original)
  const settings = SettingsManager.create(paths)

  expect(() => settings.updateGlobal({ defaultThinkingLevel: "high" })).toThrow(`${maxSettingsFileBytes} bytes`)
  expect(await readFile(paths.globalSettingsFile, "utf8")).toBe(original)
  expect(settings.get().defaultThinkingLevel).toBeUndefined()
})

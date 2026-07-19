import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import { maxSettingsFileBytes, SettingsManager } from "../src/settings-manager.js"

test("settings resolve global, then project, then runtime overrides", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ model: "global/model", thinkingLevel: "low", steeringMode: "all" })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ model: "project/model", thinkingLevel: "high" }))

  const settings = SettingsManager.create(paths, { thinkingLevel: "medium" })

  expect(settings.get()).toEqual({
    model: "project/model",
    thinkingLevel: "medium",
    steeringMode: "all",
    followUpMode: "one-at-a-time",
    compactionEnabled: true,
    compactionReserveTokens: 16_384,
    compactionKeepRecentTokens: 20_000
  })
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
  await writeFile(paths.globalSettingsFile, JSON.stringify({ model: "old/model", future: { enabled: true } }))
  await writeFile(paths.projectSettingsFile, JSON.stringify({ thinkingLevel: "low", futureProject: 1 }))
  const settings = SettingsManager.create(paths)

  settings.updateGlobal({ model: "new/model" })
  settings.updateProject({ thinkingLevel: "high" })

  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({
    model: "new/model",
    future: { enabled: true }
  })
  expect(JSON.parse(await readFile(paths.projectSettingsFile, "utf8"))).toEqual({
    thinkingLevel: "high",
    futureProject: 1
  })
  expect(settings.get()).toMatchObject({ model: "new/model", thinkingLevel: "high" })
})

test("a home-directory project does not mirror one settings file across both scopes", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-home-"))
  const paths = new OpenZiPaths(root, join(root, ".openzi"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ model: "old/model", thinkingLevel: "low" }))
  const settings = SettingsManager.create(paths)

  settings.updateGlobal({ model: "new/model" })
  settings.updateProject({ thinkingLevel: "high" })

  expect(settings.get()).toMatchObject({ model: "new/model", thinkingLevel: "high" })
  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({
    model: "new/model",
    thinkingLevel: "high"
  })
})

test("an invalid project scope reports a diagnostic without hiding valid global settings", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-invalid-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ model: "global/model", thinkingLevel: "low" }))
  await writeFile(paths.projectSettingsFile, JSON.stringify({ thinkingLevel: "turbo" }))

  const settings = SettingsManager.create(paths)

  expect(settings.get()).toMatchObject({ model: "global/model", thinkingLevel: "low" })
  expect(settings.drainErrors()).toMatchObject([
    { scope: "project", path: paths.projectSettingsFile, error: { message: expect.stringContaining("thinkingLevel") } }
  ])
  expect(settings.drainErrors()).toEqual([])
})

test("writes refuse to overwrite an invalid settings scope", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-invalid-write-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  const malformed = '{"thinkingLevel":"turbo"}'
  await writeFile(paths.projectSettingsFile, malformed)
  const settings = SettingsManager.create(paths)

  expect(() => settings.updateProject({ thinkingLevel: "high" })).toThrow("Cannot update invalid project settings")
  expect(await readFile(paths.projectSettingsFile, "utf8")).toBe(malformed)
  expect(settings.get().thinkingLevel).toBe("medium")
})

test("reload recovers an invalid scope after the file is corrected", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-reload-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, '{"thinkingLevel":"turbo"}')
  const settings = SettingsManager.create(paths)
  settings.drainErrors()

  await writeFile(paths.projectSettingsFile, JSON.stringify({ thinkingLevel: "high" }))
  settings.reload()

  expect(settings.get().thinkingLevel).toBe("high")
  expect(settings.getProject()).toEqual({ thinkingLevel: "high" })
  expect(settings.drainErrors()).toEqual([])
})

test("oversized settings are bounded and reported without entering effective state", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-bound-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, " ".repeat(maxSettingsFileBytes + 1))

  const settings = SettingsManager.create(paths)

  expect(settings.get()).toEqual({
    thinkingLevel: "medium",
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
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

  expect(() => settings.updateGlobal({ thinkingLevel: "high" })).toThrow(`${maxSettingsFileBytes} bytes`)
  expect(await readFile(paths.globalSettingsFile, "utf8")).toBe(original)
  expect(settings.get().thinkingLevel).toBe("medium")
})

import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import { SettingsManager } from "../src/settings-manager.js"

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
    followUpMode: "one-at-a-time"
  })
})

test("global and project updates preserve fields owned by newer versions", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ model: "old/model", future: { enabled: true } }))
  await writeFile(paths.projectSettingsFile, JSON.stringify({ thinkingLevel: "low", futureProject: 1 }))
  const settings = SettingsManager.create(paths)

  settings.update({ model: "new/model" })
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

  settings.update({ model: "new/model" })
  settings.updateProject({ thinkingLevel: "high" })

  expect(settings.get()).toMatchObject({ model: "new/model", thinkingLevel: "high" })
  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({
    model: "new/model",
    thinkingLevel: "high"
  })
})

test("invalid persisted settings are rejected at the file boundary", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-settings-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, JSON.stringify({ thinkingLevel: "turbo" }))

  expect(() => SettingsManager.create(paths)).toThrow(`Invalid thinkingLevel setting: ${paths.projectSettingsFile}`)
})

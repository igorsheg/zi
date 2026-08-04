import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { ZiPaths } from "../src/paths.js"
import {
  maxConfiguredResourcePathBytes,
  maxConfiguredResourcePaths,
  maxExternalEditorCommandLength,
  maxSettingsFileBytes,
  SettingsManager
} from "../src/settings-manager.js"

test("settings resolve global, then project, then construction overrides", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({
      defaultProvider: "global",
      defaultModel: "model",
      defaultThinkingLevel: "low",
      externalEditor: "global-editor",
      steeringMode: "all"
    })
  )
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({
      defaultProvider: "project",
      defaultModel: "model",
      defaultThinkingLevel: "high",
      externalEditor: "project-editor"
    })
  )

  const settings = SettingsManager.create(paths, "trusted", { defaultThinkingLevel: "medium" })

  expect(settings.get()).toEqual({
    defaultProvider: "project",
    defaultModel: "model",
    defaultThinkingLevel: "medium",
    externalEditor: "project-editor",
    steeringMode: "all",
    followUpMode: "one-at-a-time",
    codexFastMode: false,
    subagentWaitTimeoutMs: 30_000,
    retryEnabled: true,
    retryMaxRetries: 3,
    retryBaseDelayMs: 2_000,
    compactionEnabled: true,
    compactionReserveTokens: 16_384,
    compactionKeepRecentTokens: 20_000
  })
  expect(settings.getExternalEditorCommand()).toBe("project-editor")
})

test("resource path settings are scoped, trimmed, immutable, and bounded", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-resources-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ extensions: [" extensions "], skills: ["skills"], prompts: ["prompts"] })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ skills: ["../project-skills"] }))

  const settings = SettingsManager.create(paths, "trusted")

  expect(settings.getGlobal()).toMatchObject({ extensions: ["extensions"], skills: ["skills"], prompts: ["prompts"] })
  expect(settings.getProject()).toMatchObject({ skills: ["../project-skills"] })
  expect(settings.get().skills).toEqual(["../project-skills"])
  expect(Object.isFrozen(settings.getGlobal().extensions)).toBe(true)
  expect(
    () => new SettingsManager({ skills: Array.from({ length: maxConfiguredResourcePaths + 1 }, () => "x") })
  ).toThrow("Invalid skills")
  expect(() => new SettingsManager({ prompts: ["x".repeat(maxConfiguredResourcePathBytes + 1)] })).toThrow(
    "Invalid prompts"
  )
  expect(() => new SettingsManager({ extensions: ["bad\0path"] })).toThrow("Invalid extensions")
})

test("external editor resolution follows configured, VISUAL, EDITOR, then platform fallback", () => {
  const originalVisual = process.env.VISUAL
  const originalEditor = process.env.EDITOR

  try {
    process.env.VISUAL = "vim"
    process.env.EDITOR = "nano"
    const captured = new SettingsManager()
    expect(captured.getExternalEditorCommand()).toBe("vim")
    expect(new SettingsManager({ externalEditor: "code --wait" }).getExternalEditorCommand()).toBe("code --wait")

    process.env.VISUAL = " "
    process.env.EDITOR = "emacs"
    expect(new SettingsManager().getExternalEditorCommand()).toBe("emacs")
    expect(captured.getExternalEditorCommand()).toBe("vim")

    delete process.env.EDITOR
    expect(new SettingsManager().getExternalEditorCommand()).toBe(process.platform === "win32" ? "notepad" : "nano")
    expect(() => new SettingsManager({ externalEditor: " " })).toThrow("Invalid externalEditor")
    expect(() => new SettingsManager({ externalEditor: "x".repeat(maxExternalEditorCommandLength + 1) })).toThrow(
      "Invalid externalEditor"
    )
  } finally {
    if (originalVisual === undefined) delete process.env.VISUAL
    else process.env.VISUAL = originalVisual
    if (originalEditor === undefined) delete process.env.EDITOR
    else process.env.EDITOR = originalEditor
  }
})

test("subagent wait timeout is configurable within the one-hour hard bound", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-subagent-wait-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ subagentWaitTimeoutMs: 180_000 }))

  const settings = SettingsManager.create(paths, "absent")
  expect(settings.get().subagentWaitTimeoutMs).toBe(180_000)

  await writeFile(paths.globalSettingsFile, JSON.stringify({ subagentWaitTimeoutMs: 3_600_001 }))
  settings.reload()
  expect(settings.get().subagentWaitTimeoutMs).toBe(30_000)
  expect(settings.drainErrors()[0]?.error.message).toContain("subagentWaitTimeoutMs")
  expect(() => new SettingsManager({ subagentWaitTimeoutMs: 1.5 })).toThrow("Invalid subagentWaitTimeoutMs")
})

test("retry settings layer and reject unbounded backoff", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-retry-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ retryEnabled: false, retryMaxRetries: 1, retryBaseDelayMs: 1_000 })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ retryEnabled: true, retryMaxRetries: 2 }))

  const settings = SettingsManager.create(paths, "trusted")
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
  const root = await mkdtemp(join(tmpdir(), "zi-settings-compaction-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ compactionEnabled: false, compactionReserveTokens: 10 }))
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({ compactionEnabled: true, compactionKeepRecentTokens: 20 })
  )

  const settings = SettingsManager.create(paths, "trusted")
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

test("Codex Fast Mode defaults off, validates persisted state, and updates global settings", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-codex-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ codexFastMode: true }))

  const settings = SettingsManager.create(paths, "trusted")
  expect(settings.get().codexFastMode).toBe(true)

  settings.updateGlobal({ codexFastMode: false })
  expect(settings.get().codexFastMode).toBe(false)
  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({ codexFastMode: false })

  await writeFile(paths.globalSettingsFile, JSON.stringify({ codexFastMode: "on" }))
  settings.reload()
  expect(settings.get().codexFastMode).toBe(false)
  expect(settings.drainErrors()[0]?.error.message).toContain("codexFastMode")
})

test("global and project updates preserve fields owned by newer versions", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ defaultProvider: "old", defaultModel: "model", future: { enabled: true } })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "low", futureProject: 1 }))
  const settings = SettingsManager.create(paths, "trusted")

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
  const root = await mkdtemp(join(tmpdir(), "zi-settings-home-"))
  const paths = new ZiPaths(root, join(root, ".zi"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ defaultProvider: "old", defaultModel: "model", defaultThinkingLevel: "low" })
  )
  const settings = SettingsManager.create(paths, "untrusted")

  settings.updateGlobal({ defaultProvider: "new", defaultModel: "model" })
  settings.updateProject({ defaultThinkingLevel: "high" })

  expect(settings.get()).toMatchObject({ defaultProvider: "new", defaultModel: "model", defaultThinkingLevel: "high" })
  expect(JSON.parse(await readFile(paths.globalSettingsFile, "utf8"))).toEqual({
    defaultProvider: "new",
    defaultModel: "model",
    defaultThinkingLevel: "high"
  })
})

test("untrusted project settings are never parsed, reloaded, or overwritten", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-untrusted-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, JSON.stringify({ defaultThinkingLevel: "low" }))
  const malformed = '{"defaultThinkingLevel":"turbo"}'
  await writeFile(paths.projectSettingsFile, malformed)

  const settings = SettingsManager.create(paths, "untrusted")
  expect(settings.get().defaultThinkingLevel).toBe("low")
  expect(settings.getProject()).toEqual({})
  expect(settings.drainErrors()).toEqual([])

  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "high" }))
  settings.reload()
  expect(settings.get().defaultThinkingLevel).toBe("low")
  expect(() => settings.updateProject({ defaultThinkingLevel: "medium" })).toThrow(
    "Cannot update project settings before project trust"
  )
  expect(JSON.parse(await readFile(paths.projectSettingsFile, "utf8"))).toEqual({ defaultThinkingLevel: "high" })
})

test("an absent project scope can be created explicitly but never admits a raced file", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-absent-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const settings = SettingsManager.create(paths, "absent")

  settings.updateProject({ defaultThinkingLevel: "medium" })
  expect(settings.getProject()).toEqual({ defaultThinkingLevel: "medium" })
  expect(JSON.parse(await readFile(paths.projectSettingsFile, "utf8"))).toEqual({ defaultThinkingLevel: "medium" })

  const racedPaths = new ZiPaths(join(root, "raced-project"), paths.globalDir)
  const raced = SettingsManager.create(racedPaths, "absent")
  await mkdir(racedPaths.projectDir, { recursive: true })
  await writeFile(racedPaths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "high" }))
  raced.reload()
  expect(raced.getProject()).toEqual({})
  expect(() => raced.updateProject({ defaultThinkingLevel: "low" })).toThrow(
    "Cannot create project settings before project trust because the file now exists"
  )
  expect(JSON.parse(await readFile(racedPaths.projectSettingsFile, "utf8"))).toEqual({ defaultThinkingLevel: "high" })
})

test("an invalid project scope reports a diagnostic without hiding valid global settings", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-invalid-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ defaultProvider: "global", defaultModel: "model", defaultThinkingLevel: "low" })
  )
  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "turbo" }))

  const settings = SettingsManager.create(paths, "trusted")

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
  const root = await mkdtemp(join(tmpdir(), "zi-settings-invalid-write-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  const malformed = '{"defaultThinkingLevel":"turbo"}'
  await writeFile(paths.projectSettingsFile, malformed)
  const settings = SettingsManager.create(paths, "trusted")

  expect(() => settings.updateProject({ defaultThinkingLevel: "high" })).toThrow(
    "Cannot update invalid project settings"
  )
  expect(await readFile(paths.projectSettingsFile, "utf8")).toBe(malformed)
  expect(settings.get().defaultThinkingLevel).toBeUndefined()
})

test("reload recovers an invalid scope after the file is corrected", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-reload-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, '{"defaultThinkingLevel":"turbo"}')
  const settings = SettingsManager.create(paths, "trusted")

  await writeFile(paths.projectSettingsFile, JSON.stringify({ defaultThinkingLevel: "high" }))
  settings.reload()

  expect(settings.get().defaultThinkingLevel).toBe("high")
  expect(settings.getProject()).toEqual({ defaultThinkingLevel: "high" })
  expect(settings.drainErrors()).toEqual([])
})

test("oversized settings are bounded and reported without entering effective state", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-settings-bound-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.globalSettingsFile, " ".repeat(maxSettingsFileBytes + 1))

  const settings = SettingsManager.create(paths, "trusted")

  expect(settings.get()).toEqual({
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    codexFastMode: false,
    subagentWaitTimeoutMs: 30_000,
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
  const root = await mkdtemp(join(tmpdir(), "zi-settings-write-bound-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  const original = JSON.stringify({ future: "x".repeat(maxSettingsFileBytes - 30) })
  expect(Buffer.byteLength(original)).toBeLessThan(maxSettingsFileBytes)
  await writeFile(paths.globalSettingsFile, original)
  const settings = SettingsManager.create(paths, "trusted")

  expect(() => settings.updateGlobal({ defaultThinkingLevel: "high" })).toThrow(`${maxSettingsFileBytes} bytes`)
  expect(await readFile(paths.globalSettingsFile, "utf8")).toBe(original)
  expect(settings.get().defaultThinkingLevel).toBeUndefined()
})

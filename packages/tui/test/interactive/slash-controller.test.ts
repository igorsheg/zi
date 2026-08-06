import { expect, test } from "bun:test"

import type { SlashCommand } from "@with-zi/coding-agent"

import { SlashController } from "../../src/interactive/slash-controller.js"

test("SlashController aggregates a session catalog with deterministic built-in precedence", () => {
  let session = commandSession([
    { name: "review", description: "Review code", argumentHint: "<path>" },
    { name: "skill:pdf", description: "Work with PDFs" },
    { name: "model", description: "Shadow built-in" }
  ])
  const slash = new SlashController(() => session)

  expect(slash.suggestions("/", 1).map(command => command.name)).toEqual([
    "model",
    "login",
    "logout",
    "settings",
    "codex-settings",
    "compact",
    "copy",
    "reload",
    "new",
    "resume",
    "agent",
    "review",
    "skill:pdf"
  ])
  expect(slash.suggestions("/skill:", 7)).toEqual([{ name: "skill:pdf", description: "Work with PDFs" }])

  session = commandSession([{ name: "deploy", description: "Deploy current project" }])
  expect(slash.suggestions("/d", 2)[0]).toEqual({ name: "deploy", description: "Deploy current project" })
  expect(slash.suggestions("/rev", 4)).toEqual([])
})

test("SlashController gives extension commands precedence over resources and returns typed intents", () => {
  const slash = new SlashController(() => ({
    extensionCommandRevision: 1,
    listExtensionCommands: () => [
      { name: "counter", description: "Manage counter", argumentHint: "[show|increment]", extensionId: "counter" },
      { name: "model", description: "Cannot shadow built-in", extensionId: "shadow" }
    ],
    listResourceCommands: () => [
      { name: "counter", description: "Resource collision" },
      { name: "review", description: "Review code" }
    ]
  }))

  expect(slash.suggestions("/", 1).map(command => command.name)).toEqual([
    "model",
    "login",
    "logout",
    "settings",
    "codex-settings",
    "compact",
    "copy",
    "reload",
    "new",
    "resume",
    "agent",
    "counter",
    "review"
  ])
  expect(slash.activate("/cou increment", 4, "counter")).toEqual({
    type: "intent",
    command: { type: "extension_command", name: "counter", arguments: "increment" }
  })
  expect(slash.parse("/counter increment")).toEqual({
    type: "extension_command",
    name: "counter",
    arguments: "increment"
  })
})

test("SlashController invalidates extension commands when their session-owned revision changes", () => {
  let revision = 0
  let commands = [{ name: "counter", description: "Counter", extensionId: "counter" }]
  const slash = new SlashController(
    () => ({
      extensionCommandRevision: revision,
      listExtensionCommands: () => commands,
      listResourceCommands: () => []
    }),
    () => 1
  )

  expect(slash.suggestions("/cou", 4)[0]?.name).toBe("counter")
  commands = [{ name: "deploy", description: "Deploy", extensionId: "deploy" }]
  revision++
  expect(slash.suggestions("/dep", 4)[0]?.name).toBe("deploy")
  expect(slash.parse("/counter")).toBeUndefined()
})

test("SlashController caches one bounded catalog until the session generation changes", () => {
  let generation = 0
  let reads = 0
  let resources: readonly SlashCommand[] = [{ name: "review", description: "Review code" }]
  const slash = new SlashController(
    () => ({
      extensionCommandRevision: 0,
      listExtensionCommands: () => [],
      listResourceCommands() {
        reads++
        return resources
      }
    }),
    () => generation
  )

  expect(slash.suggestions("/rev", 4)[0]?.name).toBe("review")
  expect(
    slash
      .suggestions("/re", 3)
      .map(command => command.name)
      .slice(0, 2)
  ).toEqual(["reload", "resume"])
  expect(reads).toBe(1)

  resources = [{ name: "deploy", description: "Deploy current project" }]
  generation++
  expect(slash.suggestions("/dep", 4)[0]?.name).toBe("deploy")
  expect(reads).toBe(2)
})

test("SlashController ranks exact and prefix command names ahead of fuzzy matches", () => {
  const slash = new SlashController(() =>
    commandSession([
      { name: "mdl-helper", description: "Fuzzy sibling" },
      { name: "modeling", description: "Prefix sibling" }
    ])
  )

  expect(slash.suggestions("/mdl", 4).map(command => command.name)).toContain("model")
  expect(
    slash
      .suggestions("/model", 6)
      .map(command => command.name)
      .slice(0, 2)
  ).toEqual(["model", "modeling"])
  expect(slash.suggestions("/rsme", 5).map(command => command.name)[0]).toBe("resume")
})

test("SlashController completes only the command range and preserves the surrounding draft", () => {
  const slash = new SlashController()

  expect(slash.complete("/mod target", 4, "model")).toEqual({ type: "edit", text: "/model target", cursorOffset: 7 })
  expect(slash.complete("  /modd  target", 6, "model")).toEqual({
    type: "edit",
    text: "  /model  target",
    cursorOffset: 9
  })
  expect(slash.complete("/mod\ntarget", 4, "model")).toEqual({ type: "unavailable" })
})

test("SlashController resolves selection into typed intents or resource edits", () => {
  let session = commandSession([{ name: "review", description: "Review code", argumentHint: "<path>" }])
  const slash = new SlashController(() => session)

  expect(slash.activate("/mdl", 4, "model")).toEqual({ type: "intent", command: { type: "model", search: "" } })
  expect(slash.activate("/mo provider/model", 3, "model")).toEqual({
    type: "intent",
    command: { type: "model", search: "provider/model" }
  })
  expect(slash.activate("/lo provider", 3, "login")).toEqual({
    type: "intent",
    command: { type: "login", provider: "provider" }
  })
  expect(slash.activate("/cop", 4, "copy")).toEqual({ type: "intent", command: { type: "copy" } })
  expect(slash.activate("/age", 4, "agent")).toEqual({ type: "intent", command: { type: "subagents" } })
  expect(slash.activate("/rev", 4, "review")).toEqual({ type: "edit", text: "/review ", cursorOffset: 8 })

  session = commandSession([{ name: "deploy", description: "Deploy current project" }])
  expect(slash.activate("/rev", 4, "review")).toEqual({ type: "unavailable" })
})

test("SlashController parses only supported built-in invocations", () => {
  const slash = new SlashController()

  expect(slash.parse("/review path")).toBeUndefined()
  expect(slash.parse("/model provider/model")).toEqual({ type: "model", search: "provider/model" })
  expect(slash.parse("/login provider")).toEqual({ type: "login", provider: "provider" })
  expect(slash.parse("/codex-settings")).toEqual({ type: "codex_settings" })
  expect(slash.parse("/compact preserve exact paths")).toEqual({
    type: "compact",
    instructions: "preserve exact paths"
  })
  expect(slash.parse("/copy")).toEqual({ type: "copy" })
  expect(slash.parse("/reload")).toEqual({ type: "reload" })
  expect(slash.parse("/new")).toEqual({ type: "new_session" })
  expect(slash.parse("/resume")).toEqual({ type: "resume_session" })
  expect(slash.parse("/agent")).toEqual({ type: "subagents" })
})

test("SlashController invalidates a cached catalog without a session generation change", () => {
  let generation = 0
  let reads = 0
  let resources: readonly SlashCommand[] = [{ name: "review", description: "Review code" }]
  const slash = new SlashController(
    () => ({
      extensionCommandRevision: 0,
      listExtensionCommands: () => [],
      listResourceCommands() {
        reads++
        return resources
      }
    }),
    () => generation
  )

  expect(slash.suggestions("/rev", 4)[0]?.name).toBe("review")
  expect(reads).toBe(1)

  resources = [{ name: "deploy", description: "Deploy current project" }]
  slash.invalidateCatalog()
  expect(slash.suggestions("/dep", 4)[0]?.name).toBe("deploy")
  expect(reads).toBe(2)
})

function commandSession(commands: readonly SlashCommand[]) {
  return { extensionCommandRevision: 0, listExtensionCommands: () => [], listResourceCommands: () => commands }
}

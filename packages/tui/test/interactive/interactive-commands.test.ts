import { expect, test } from "bun:test"

import type { SlashCommand } from "@openzi/coding-agent"

import { createInteractiveCommands } from "../../src/interactive/interactive-commands.js"

test("interactive commands own built-in and current-session resource aggregation", () => {
  let resources: readonly SlashCommand[] = [
    { name: "review", description: "Review code", argumentHint: "<path>" },
    { name: "skill:pdf", description: "Work with PDFs" },
    { name: "model", description: "Shadow built-in" }
  ]
  const commands = createInteractiveCommands(() => ({ listResourceCommands: () => resources }))

  expect(commands.suggestions("/", 1).map(command => command.name)).toEqual([
    "model",
    "login",
    "logout",
    "settings",
    "new",
    "resume",
    "review",
    "skill:pdf"
  ])
  expect(commands.suggestions("/skill:", 7)).toEqual([{ name: "skill:pdf", description: "Work with PDFs" }])
  expect(commands.completion(commands.suggestions("/rev", 4)[0]!)).toBe("/review ")
  expect(commands.parse("/review path")).toBeUndefined()
  expect(commands.parse("/new")).toEqual({ type: "new_session" })
  expect(commands.parse("/resume")).toEqual({ type: "resume_session" })

  resources = [{ name: "deploy", description: "Deploy current project" }]
  expect(commands.suggestions("/d", 2)).toEqual([{ name: "deploy", description: "Deploy current project" }])
  expect(commands.suggestions("/rev", 4)).toEqual([])
})

import { expect, test } from "bun:test"

import { builtinSlashCommands } from "../src/slash-commands.js"

test("coding-agent owns descriptors for supported built-in slash commands", () => {
  expect(builtinSlashCommands).toEqual([
    { name: "model", description: "Select model (opens selector UI)", argumentHint: "<provider/model>" },
    { name: "login", description: "Authenticate a provider", argumentHint: "<provider>" },
    { name: "logout", description: "Remove stored provider credentials" },
    { name: "settings", description: "Open settings menu" },
    { name: "codex-settings", description: "Open OpenAI Codex settings" },
    {
      name: "compact",
      description: "Compact context, optionally preserving a specified focus",
      argumentHint: "[focus]"
    },
    { name: "copy", description: "Copy last assistant message to clipboard" },
    {
      name: "reload",
      description: "Reload settings, extensions, skills, prompts, subagent profiles, and context files"
    },
    { name: "new", description: "Start a new session" },
    { name: "resume", description: "Browse and resume saved sessions" },
    { name: "agent", description: "Browse subagents and open live activity" }
  ])
})

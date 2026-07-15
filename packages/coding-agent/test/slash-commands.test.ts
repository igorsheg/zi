import { expect, test } from "bun:test"

import { builtinSlashCommands } from "../src/slash-commands.js"

test("coding-agent owns descriptors for supported built-in slash commands", () => {
  expect(builtinSlashCommands).toEqual([
    { name: "model", description: "Select model (opens selector UI)", argumentHint: "<provider/model>" }
  ])
})

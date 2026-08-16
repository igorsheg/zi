import { expect, test } from "bun:test"

import { SlashController } from "../../src/interactive/slash-controller.js"

test("durable agent transcript browsing remains outside the terminal command catalog", () => {
  const slash = new SlashController()

  expect(slash.suggestions("/agent", 6).map(command => command.name)).not.toContain("agent")
  expect(slash.parse("/agent")).toBeUndefined()
})

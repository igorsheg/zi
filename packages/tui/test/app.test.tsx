import { expect, test } from "bun:test"

import { testRender } from "@opentui/react/test-utils"
import { act } from "react"

import { App } from "../src/app.js"

test("empty shell protects the prompt area", async () => {
  const setup = await testRender(<App cwd="/work" />, { width: 80, height: 24 })
  try {
    await setup.renderOnce()
    expect(setup.captureCharFrame()).toContain("No model configured")
    expect(setup.captureCharFrame()).toContain("/work")
  } finally {
    act(() => setup.renderer.destroy())
  }
})

import { createTestRenderer, type TestRendererOptions, type TestRendererSetup } from "@opentui/core/testing"
import type { AgentSession } from "@openzi/coding-agent"

import type { InteractiveKeybindingOverrides } from "../../src/interactive/interactive-keybindings.js"
import { InteractiveMode } from "../../src/interactive/interactive-mode.js"

export interface InteractiveTestSetup extends TestRendererSetup {
  readonly mode: InteractiveMode
  destroy(): void
}

export async function createInteractiveTest(
  session: AgentSession,
  options: TestRendererOptions,
  onExit: () => void = () => {},
  keybindingOverrides?: InteractiveKeybindingOverrides
): Promise<InteractiveTestSetup> {
  const setup = await createTestRenderer({ ...options, useThread: false })
  const mode = new InteractiveMode({
    renderer: setup.renderer,
    session,
    onExit,
    ...(keybindingOverrides ? { keybindingOverrides } : {})
  })
  return {
    ...setup,
    mode,
    destroy() {
      mode.dispose()
      if (!setup.renderer.isDestroyed) setup.renderer.destroy()
    }
  }
}

export async function renderSettled(setup: TestRendererSetup): Promise<void> {
  await setup.flush()
  await setup.flush()
}

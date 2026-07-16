import { createTestRenderer, type TestRendererOptions, type TestRendererSetup } from "@opentui/core/testing"
import type { AgentSession, AgentSessionRuntime } from "@openzi/coding-agent"

import type { BrowserOpener } from "../../src/interactive/browser-opener.js"
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
  keybindingOverrides?: InteractiveKeybindingOverrides,
  browserOpener: BrowserOpener = { open: async () => {}, dispose() {} },
  sessionRuntime?: AgentSessionRuntime
): Promise<InteractiveTestSetup> {
  const setup = await createTestRenderer({ ...options, useThread: false })
  const mode = new InteractiveMode({
    renderer: setup.renderer,
    session,
    ...(sessionRuntime ? { sessionRuntime } : {}),
    onExit,
    browserOpener,
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

export function createInteractiveRuntimeTest(
  runtime: AgentSessionRuntime,
  options: TestRendererOptions,
  onExit: () => void = () => {},
  keybindingOverrides?: InteractiveKeybindingOverrides,
  browserOpener: BrowserOpener = { open: async () => {}, dispose() {} }
): Promise<InteractiveTestSetup> {
  return createInteractiveTest(runtime.session, options, onExit, keybindingOverrides, browserOpener, runtime)
}

export async function renderSettled(setup: TestRendererSetup): Promise<void> {
  await setup.flush()
  await setup.flush()
}

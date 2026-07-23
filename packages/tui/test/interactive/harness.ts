import { CodeRenderable } from "@opentui/core"
import { createTestRenderer, type TestRendererOptions, type TestRendererSetup } from "@opentui/core/testing"
import type { AgentSession, AgentSessionRuntime } from "@with-zi/coding-agent"

import type { BrowserOpener } from "../../src/interactive/browser-opener.js"
import type { ClipboardReader, ClipboardWriter } from "../../src/interactive/clipboard.js"
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
  sessionRuntime?: AgentSessionRuntime,
  clipboardReader?: ClipboardReader,
  clipboardWriter?: ClipboardWriter
): Promise<InteractiveTestSetup> {
  const setup = await createTestRenderer({ ...options, useThread: false })
  const mode = new InteractiveMode({
    renderer: setup.renderer,
    session,
    ...(sessionRuntime ? { sessionRuntime } : {}),
    onExit,
    browserOpener,
    ...(clipboardReader ? { clipboardReader } : {}),
    ...(clipboardWriter ? { clipboardWriter } : {}),
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

export async function renderMarkdownSettled(setup: TestRendererSetup): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt++) {
    // Highlight settlement is sequential across renderer frames.
    // oxlint-disable-next-line no-await-in-loop
    await setup.renderOnce()
    const stack = [...setup.renderer.root.getChildren()]
    const pending: CodeRenderable[] = []
    while (stack.length > 0) {
      const child = stack.pop()!
      if (child instanceof CodeRenderable && child.isHighlighting) pending.push(child)
      stack.push(...child.getChildren())
    }
    if (pending.length === 0) {
      // oxlint-disable-next-line no-await-in-loop
      await setup.renderOnce()
      return
    }
    // oxlint-disable-next-line no-await-in-loop
    await Promise.all(pending.map(child => child.highlightingDone))
  }
  throw new Error("Markdown highlighting did not settle")
}

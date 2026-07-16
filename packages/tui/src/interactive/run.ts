import { CliRenderEvents, createCliRenderer, type CliRenderer } from "@opentui/core"
import type { AgentSession } from "@openzi/coding-agent"

import { defaultTheme } from "../theme.js"
import type { InteractiveKeybindingOverrides } from "./interactive-keybindings.js"
import { InteractiveMode } from "./interactive-mode.js"

export interface RunTuiOptions {
  readonly session: AgentSession
  readonly initialMessages?: readonly string[]
  readonly keybindingOverrides?: InteractiveKeybindingOverrides
}

type CloseReason = "interactive" | "renderer" | "startup" | NodeJS.Signals

type RunState =
  | { readonly type: "running" }
  | { readonly type: "closing"; readonly reason: CloseReason; readonly completion: Promise<void> }
  | { readonly type: "closed"; readonly reason: CloseReason; readonly outcome: "succeeded" }
  | { readonly type: "closed"; readonly reason: CloseReason; readonly outcome: "failed"; readonly cause: unknown }

const shutdownTimeoutMs = 5_000

export async function runTui({ session, initialMessages = [], keybindingOverrides }: RunTuiOptions): Promise<void> {
  const renderer = await createCliRenderer({
    targetFps: 60,
    gatherStats: false,
    exitOnCtrlC: false,
    exitSignals: [],
    autoFocus: false,
    screenMode: "alternate-screen",
    externalOutputMode: "passthrough",
    useKittyKeyboard: {},
    useMouse: true,
    openConsoleOnError: false,
    backgroundColor: defaultTheme.surface.app
  })
  let mode: InteractiveMode | undefined
  let state: RunState = { type: "running" }
  let finish!: () => void
  let fail!: (cause: unknown) => void
  const finished = new Promise<void>((resolve, reject) => {
    finish = resolve
    fail = reject
  })

  const requestClose = (reason: CloseReason): Promise<void> => {
    if (state.type === "closing") return state.completion
    if (state.type === "closed") {
      return state.outcome === "succeeded" ? Promise.resolve() : Promise.reject(state.cause)
    }

    let complete!: () => void
    let reject!: (cause: unknown) => void
    const completion = new Promise<void>((resolve, rejectPromise) => {
      complete = resolve
      reject = rejectPromise
    })
    state = { type: "closing", reason, completion }
    void completion.then(
      () => {
        state = { type: "closed", reason, outcome: "succeeded" }
        finish()
        return undefined
      },
      cause => {
        state = { type: "closed", reason, outcome: "failed", cause }
        fail(cause)
        return undefined
      }
    )
    void shutdown(renderer, mode, session).then(complete, reject)
    return completion
  }

  const signals: NodeJS.Signals[] = ["SIGHUP", "SIGINT", "SIGTERM"]
  const signalHandlers = signals.map(signal => {
    const handler = () => void requestClose(signal)
    process.on(signal, handler)
    return { signal, handler }
  })
  renderer.once(CliRenderEvents.DESTROY, () => void requestClose("renderer"))

  try {
    renderer.setTerminalTitle("openzi")
    mode = new InteractiveMode({
      renderer,
      session,
      onExit: () => void requestClose("interactive"),
      ...(keybindingOverrides ? { keybindingOverrides } : {})
    })
    // Initial prompts share the interactive transcript and run after terminal ownership is established.
    // oxlint-disable-next-line no-await-in-loop
    for (const message of initialMessages) await session.prompt(message)
    await finished
  } finally {
    for (const { signal, handler } of signalHandlers) process.off(signal, handler)
    await requestClose(mode ? "renderer" : "startup")
  }
}

async function shutdown(
  renderer: CliRenderer,
  mode: InteractiveMode | undefined,
  session: AgentSession
): Promise<void> {
  let failure: { cause: unknown } | undefined
  let settlement: Promise<void> | undefined
  const capture = (cause: unknown) => {
    failure ??= { cause }
  }

  try {
    mode?.dispose()
  } catch (cause) {
    capture(cause)
  }
  try {
    settlement = session.abortAndDiscardQueuedInputs()
  } catch (cause) {
    capture(cause)
  }
  try {
    renderer.setTerminalTitle("")
  } catch (cause) {
    capture(cause)
  }
  try {
    if (!renderer.isDestroyed) renderer.destroy()
  } catch (cause) {
    capture(cause)
  }
  if (settlement) {
    try {
      await settle(settlement, shutdownTimeoutMs)
    } catch (cause) {
      capture(cause)
    }
  }
  if (failure) throw failure.cause
}

function settle(operation: Promise<void>, timeoutMs: number): Promise<void> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    operation,
    new Promise<void>((_, reject) => {
      timeout = setTimeout(() => reject(new Error("Session shutdown timed out")), timeoutMs)
    })
  ]).finally(() => {
    if (timeout) clearTimeout(timeout)
  })
}

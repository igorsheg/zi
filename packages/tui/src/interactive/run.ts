import { CliRenderEvents, createCliRenderer, DebugOverlayCorner, type CliRenderer } from "@opentui/core"
import type { AgentSession, AgentSessionRuntime } from "@openzi/coding-agent"

import { defaultTheme } from "../theme.js"
import type { TuiDiagnosticFlags } from "./diagnostics.js"
import type { InteractiveKeybindingOverrides } from "./interactive-keybindings.js"
import { InteractiveMode } from "./interactive-mode.js"

export interface RunTuiOptions {
  readonly session?: AgentSession
  readonly sessionRuntime?: AgentSessionRuntime
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

export async function runTui(options: RunTuiOptions): Promise<void> {
  const { initialMessages = [], keybindingOverrides, sessionRuntime } = options
  const session = sessionRuntime?.session ?? options.session
  if (!session) throw new Error("runTui requires a session or session runtime")
  const diagnostics = readDiagnosticFlags(process.env)
  const renderer = await createCliRenderer({
    targetFps: 60,
    gatherStats: diagnostics.showStats,
    maxStatSamples: 300,
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
  if (diagnostics.showStats) {
    renderer.configureDebugOverlay({ enabled: true, corner: DebugOverlayCorner.bottomRight })
  }
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
    void shutdown(renderer, mode, session, sessionRuntime).then(complete, reject)
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
      ...(sessionRuntime ? { sessionRuntime } : {}),
      onExit: () => void requestClose("interactive"),
      diagnostics,
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

function readDiagnosticFlags(env: NodeJS.ProcessEnv): TuiDiagnosticFlags {
  return {
    showTimeToFirstDraw: env.OPENZI_SHOW_TTFD === "1",
    showStats: env.OPENZI_TUI_STATS === "1",
    showMemory: env.OPENZI_TUI_MEMORY === "1"
  }
}

async function shutdown(
  renderer: CliRenderer,
  mode: InteractiveMode | undefined,
  initialSession: AgentSession,
  sessionRuntime: AgentSessionRuntime | undefined
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
  const replacement = sessionRuntime?.cancelReplacement()
  const session = sessionRuntime?.session ?? initialSession
  try {
    const sessionSettlement = session.abortAndDiscardQueuedInputs()
    settlement = replacement
      ? Promise.all([sessionSettlement, replacement.settled]).then(() => undefined)
      : sessionSettlement
  } catch (cause) {
    capture(cause)
    settlement = replacement?.settled
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

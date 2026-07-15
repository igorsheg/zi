import { CliRenderEvents, createCliRenderer } from "@opentui/core"
import type { AgentSession } from "@openzi/coding-agent"

import { defaultTheme } from "../theme.js"
import { InteractiveMode } from "./interactive-mode.js"

export interface RunTuiOptions {
  readonly session: AgentSession
}

const shutdownTimeoutMs = 5_000

export async function runTui({ session }: RunTuiOptions): Promise<void> {
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
  const signals: NodeJS.Signals[] = ["SIGHUP", "SIGINT", "SIGTERM"]
  let closing: Promise<void> | undefined

  const close = () => {
    closing ??= (async () => {
      mode?.dispose()
      mode = undefined
      try {
        await settle(session.abort(), shutdownTimeoutMs)
      } finally {
        renderer.setTerminalTitle("")
        if (!renderer.isDestroyed) renderer.destroy()
      }
    })()
    return closing
  }
  const requestClose = () => void close().catch(() => {})
  const destroyed = new Promise<void>(resolve => renderer.once(CliRenderEvents.DESTROY, resolve))
  for (const signal of signals) process.on(signal, requestClose)

  try {
    renderer.setTerminalTitle("openzi")
    mode = new InteractiveMode({ renderer, session, onExit: requestClose })
    await destroyed
  } finally {
    for (const signal of signals) process.off(signal, requestClose)
    await close()
  }
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

import type { AgentSession } from "@openzi/coding-agent"
import { CliRenderEvents, createCliRenderer, type KeyEvent } from "@opentui/core"
import { createRoot } from "@opentui/react"
import { App } from "./app.js"

export interface RunTuiOptions {
  cwd: string
  session?: AgentSession
}

const shutdownTimeoutMs = 5_000

export async function runTui(options: RunTuiOptions): Promise<void> {
  const renderer = await createCliRenderer({ targetFps: 60, exitOnCtrlC: false, exitSignals: [], autoFocus: false })
  const root = createRoot(renderer)
  const signals: NodeJS.Signals[] = ["SIGHUP", "SIGINT", "SIGTERM"]
  let closing: Promise<void> | undefined

  const close = () => {
    closing ??= (async () => {
      try {
        if (options.session) await settle(options.session.abort(), shutdownTimeoutMs)
      } finally {
        options.session?.dispose()
        root.unmount()
        if (!renderer.isDestroyed) renderer.destroy()
      }
    })()
    void closing.catch((error) => process.stderr.write(`${String(error)}\n`))
  }
  const onKey = (key: KeyEvent) => {
    if (key.ctrl && key.name === "c") close()
  }
  const onSignal = () => close()

  renderer.keyInput.on("keypress", onKey)
  for (const signal of signals) process.on(signal, onSignal)
  renderer.setTerminalTitle("openzi")
  root.render(<App {...options} />)

  await new Promise<void>((resolve) => renderer.once(CliRenderEvents.DESTROY, resolve))
  renderer.keyInput.off("keypress", onKey)
  for (const signal of signals) process.off(signal, onSignal)

  if (closing) {
    await closing.catch(() => {})
  } else if (options.session) {
    await settle(options.session.abort(), shutdownTimeoutMs)
    options.session.dispose()
  }
}

function settle(operation: Promise<void>, timeoutMs: number): Promise<void> {
  let timeout: ReturnType<typeof setTimeout>
  return Promise.race([
    operation,
    new Promise<void>((_, reject) => {
      timeout = setTimeout(() => reject(new Error("Session shutdown timed out")), timeoutMs)
    }),
  ]).finally(() => clearTimeout(timeout))
}

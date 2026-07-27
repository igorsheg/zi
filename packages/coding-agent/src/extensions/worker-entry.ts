import { createWriteStream } from "node:fs"
import { finished } from "node:stream/promises"

import { runExtensionWorkerProcess } from "./worker.js"

export const extensionWorkerArgument = "--zi-internal-extension-worker"

export async function runExtensionWorkerFromStdio(): Promise<void> {
  const output = createWriteStream("", { fd: 3, autoClose: true })
  const outputFinished = finished(output)
  const result = await runExtensionWorkerProcess(process.stdin, output).then(
    () => ({ type: "success" as const }),
    cause => ({ type: "failure" as const, cause })
  )
  output.end()
  const outputResult = await outputFinished.then(
    () => ({ type: "success" as const }),
    cause => ({ type: "failure" as const, cause })
  )
  if (result.type === "failure") throw result.cause
  if (outputResult.type === "failure") throw outputResult.cause
}

if (import.meta.main) {
  try {
    await runExtensionWorkerFromStdio()
  } catch (cause) {
    await Bun.stderr.write(`${cause instanceof Error ? cause.message : String(cause)}\n`)
    process.exitCode = 1
  }
}

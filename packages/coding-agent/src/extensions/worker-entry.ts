import { closeSync, writeSync } from "node:fs"
import { Writable } from "node:stream"
import { finished } from "node:stream/promises"

import { runExtensionWorkerProcess } from "./worker.js"

export const extensionWorkerArgument = "--zi-internal-extension-worker"

export async function runExtensionWorkerFromStdio(): Promise<void> {
  const output = createProtocolOutput(3)
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

function createProtocolOutput(descriptor: number): Writable {
  let closed = false
  const close = (): void => {
    if (closed) return
    closed = true
    closeSync(descriptor)
  }
  return new Writable({
    write(chunk: Buffer, _encoding, callback) {
      try {
        let offset = 0
        while (offset < chunk.byteLength) {
          const written = writeSync(descriptor, chunk, offset, chunk.byteLength - offset)
          if (written === 0) throw new Error("Extension worker protocol output stopped accepting bytes")
          offset += written
        }
        callback()
      } catch (cause) {
        callback(cause instanceof Error ? cause : new Error("Extension worker protocol output failed"))
      }
    },
    final(callback) {
      try {
        close()
        callback()
      } catch (cause) {
        callback(cause instanceof Error ? cause : new Error("Extension worker protocol output failed"))
      }
    },
    destroy(cause, callback) {
      try {
        close()
        callback(cause)
      } catch (failure) {
        callback(cause ?? (failure instanceof Error ? failure : new Error("Extension worker protocol output failed")))
      }
    }
  })
}

if (import.meta.main) {
  try {
    await runExtensionWorkerFromStdio()
  } catch (cause) {
    await Bun.stderr.write(`${cause instanceof Error ? cause.message : String(cause)}\n`)
    process.exitCode = 1
  }
}

#!/usr/bin/env bun

import { runCodeModeWorkerFromStdio } from "./worker.js"

export { runCodeModeWorkerFromStdio }

if (import.meta.main) {
  try {
    await runCodeModeWorkerFromStdio()
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    await Bun.stderr.write(`${message}\n`)
    process.exitCode = 1
  }
}

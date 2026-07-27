#!/usr/bin/env bun

import { defaultCliArgv, runEntrypoint } from "./main.js"

try {
  process.exitCode = await runEntrypoint(defaultCliArgv())
} catch (cause) {
  const message = cause instanceof Error ? cause.message : String(cause)
  await Bun.stderr.write(`${message}\n`)
  process.exitCode = 1
}

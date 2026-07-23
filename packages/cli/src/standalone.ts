#!/usr/bin/env bun

import { defaultCliArgv, main } from "./main.js"

try {
  process.exitCode = await main(defaultCliArgv())
} catch (cause) {
  const message = cause instanceof Error ? cause.message : String(cause)
  await Bun.stderr.write(`${message}\n`)
  process.exitCode = 1
}

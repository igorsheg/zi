#!/usr/bin/env bun

import { createAgentRuntime, NoModelAvailableError } from "@openzi/coding-agent"
import { runTui } from "@openzi/tui"

import { parseArgs } from "./args.js"

try {
  const args = parseArgs(process.argv.slice(2))
  const { session } = await createAgentRuntime({
    cwd: args.cwd,
    persist: !args.noSession,
    ...(args.model === undefined ? {} : { model: args.model }),
    ...(args.sessionFile === undefined ? {} : { sessionFile: args.sessionFile })
  })
  await runTui({ session })
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  process.stderr.write(`${message}\n`)
  process.exitCode = error instanceof NoModelAvailableError ? 2 : 1
}

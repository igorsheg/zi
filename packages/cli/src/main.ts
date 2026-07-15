#!/usr/bin/env bun

import { createAgentRuntime } from "@openzi/coding-agent"

import { parseArgs } from "./args.js"

try {
  const args = parseArgs(process.argv.slice(2))
  const { session } = await createAgentRuntime({
    cwd: args.cwd,
    persist: !args.noSession,
    ...(args.model === undefined ? {} : { model: args.model }),
    ...(args.apiKey === undefined ? {} : { apiKey: args.apiKey }),
    ...(args.sessionFile === undefined ? {} : { sessionFile: args.sessionFile })
  })
  try {
    const { runTui } = await import("@openzi/tui")
    await runTui({ session })
  } finally {
    session.dispose()
  }
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  process.stderr.write(`${message}\n`)
  process.exitCode = 1
}

#!/usr/bin/env bun

import { defaultCliArgv, standaloneRoute } from "./bootstrap.js"
import { helpText, versionText } from "./cli-text.js"

const argv = defaultCliArgv()
const route = standaloneRoute(argv)

try {
  switch (route) {
    case "help":
      await Bun.stdout.write(helpText)
      break
    case "version":
      await Bun.stdout.write(versionText)
      break
    case "extension_worker": {
      const { runExtensionWorkerFromStdio } = await import("@with-zi/coding-agent/internal/extension-worker")
      await runExtensionWorkerFromStdio()
      break
    }
    case "main": {
      const { runEntrypoint } = await import("./main.js")
      process.exitCode = await runEntrypoint(argv)
      break
    }
    default:
      standaloneRouteExhaustive(route)
  }
} catch (cause) {
  const message = cause instanceof Error ? cause.message : String(cause)
  await Bun.stderr.write(`${message}\n`)
  process.exitCode = 1
}

function standaloneRouteExhaustive(value: never): never {
  throw new Error(`Unknown standalone route: ${String(value)}`)
}

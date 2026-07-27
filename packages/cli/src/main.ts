#!/usr/bin/env bun

import { homedir } from "node:os"

import { extensionWorkerArgument, runExtensionWorkerFromStdio } from "@with-zi/coding-agent/internal/extension-worker"

import {
  defaultRuntimeFactory,
  defaultSessionRuntimeFactory,
  maxCliStdinBytes,
  runCli,
  type CliHost,
  type CliSignal
} from "./run.js"

export async function main(argv: readonly string[] = defaultCliArgv()): Promise<number> {
  return runCli(argv, processHost())
}

export async function runEntrypoint(argv: readonly string[] = defaultCliArgv()): Promise<number> {
  if (argv.length === 1 && argv[0] === extensionWorkerArgument) {
    await runExtensionWorkerFromStdio()
    return 0
  }
  return main(argv)
}

export function defaultCliArgv(argv: readonly string[] = process.argv): readonly string[] {
  // Bun standalone argv includes a virtual $bunfs script on Unix; Windows builds may expose only executable argv.
  const second = argv[1]
  if (!second) return []
  if (second.startsWith("-")) return argv.slice(1)
  if (second.includes("$bunfs") || /\.[cm]?[jt]sx?$/.test(second)) return argv.slice(2)
  if (/(^|[\\/])bun(?:\.exe)?$/i.test(argv[0] ?? "")) return argv.slice(2)
  return argv.slice(1)
}

function processHost(): CliHost {
  return {
    cwd: process.cwd(),
    home: homedir(),
    env: Object.freeze({ ...process.env }),
    stdinIsTTY: process.stdin.isTTY,
    stdoutIsTTY: process.stdout.isTTY,
    readStdin: readPipedStdin,
    writeStdout: chunk => writeOutput(Bun.stdout, chunk),
    writeStderr: chunk => writeOutput(Bun.stderr, chunk),
    createRuntime: defaultRuntimeFactory,
    createSessionRuntime: defaultSessionRuntimeFactory,
    async runInteractive(sessionRuntime, initialMessages) {
      const { runTui } = await import("@with-zi/tui")
      await runTui({ sessionRuntime, initialMessages })
    },
    onSignal(listener) {
      const signals: CliSignal[] = ["SIGHUP", "SIGINT", "SIGTERM"]
      const handlers = signals.map(signal => {
        const handler = () => listener(signal)
        process.on(signal, handler)
        return { signal, handler }
      })
      return () => {
        for (const { signal, handler } of handlers) process.off(signal, handler)
      }
    }
  }
}

async function readPipedStdin(): Promise<string | undefined> {
  if (process.stdin.isTTY) return undefined
  const chunks: Buffer[] = []
  let bytes = 0
  for await (const chunk of process.stdin) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    bytes += buffer.byteLength
    if (bytes > maxCliStdinBytes) throw new Error(`Piped stdin cannot exceed ${maxCliStdinBytes} bytes`)
    chunks.push(buffer)
  }
  return Buffer.concat(chunks, bytes).toString("utf8")
}

async function writeOutput(stream: Bun.BunFile, chunk: string): Promise<void> {
  await stream.write(chunk)
}

if (import.meta.main) {
  try {
    process.exitCode = await runEntrypoint(defaultCliArgv())
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    await Bun.stderr.write(`${message}\n`)
    process.exitCode = 1
  }
}

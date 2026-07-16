#!/usr/bin/env bun

import {
  defaultRuntimeFactory,
  defaultSessionRuntimeFactory,
  maxCliStdinBytes,
  runCli,
  type CliHost,
  type CliSignal
} from "./run.js"

export async function main(argv: readonly string[] = process.argv.slice(2)): Promise<number> {
  return runCli(argv, processHost())
}

function processHost(): CliHost {
  return {
    stdinIsTTY: process.stdin.isTTY,
    stdoutIsTTY: process.stdout.isTTY,
    readStdin: readPipedStdin,
    writeStdout: chunk => writeOutput(process.stdout, chunk),
    writeStderr: chunk => writeOutput(process.stderr, chunk),
    createRuntime: defaultRuntimeFactory,
    createSessionRuntime: defaultSessionRuntimeFactory,
    async runInteractive(sessionRuntime, initialMessages) {
      const { runTui } = await import("@openzi/tui")
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

function writeOutput(stream: NodeJS.WriteStream, chunk: string): Promise<void> {
  return new Promise((resolve, reject) => {
    stream.write(chunk, error => {
      if (error) reject(error)
      else resolve()
    })
  })
}

if (import.meta.main) {
  try {
    process.exitCode = await main()
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    process.stderr.write(`${message}\n`)
    process.exitCode = 1
  }
}

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { delimiter, join } from "node:path"
import type { Readable, Writable } from "node:stream"

import { spawnOwnedProcess, type OwnedProcessExit, type ProtocolOwnedProcess } from "../processes/owned-process.js"
import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { ExtensionLoadPlan } from "./discovery.js"
import { extensionApiModuleSource } from "./public-api-module.js"
import { extensionWorkerArgument } from "./worker-mode.js"

export type ExtensionWorkerExit = OwnedProcessExit

export interface ExtensionWorkerProcess {
  readonly input: Writable
  readonly stdout: Readable
  readonly stderr: Readable
  readonly protocol: Readable
  readonly admitted?: Promise<void>
  readonly exited: Promise<ExtensionWorkerExit>
  terminate(force: boolean): void
  dispose(): void | Promise<void>
}

export type SpawnExtensionWorker = (plan: ExtensionLoadPlan) => ExtensionWorkerProcess

export function spawnExtensionWorker(
  plan: ExtensionLoadPlan,
  command: readonly string[],
  processTreeTracker: ProcessTreeTracker,
  removePublicApiDirectory: (path: string) => void = path => rmSync(path, { recursive: true, force: true })
): ExtensionWorkerProcess {
  const publicApi = createPublicApiModule(removePublicApiDirectory)
  const inheritedEnvironment = Object.freeze({ ...process.env })
  let worker: ProtocolOwnedProcess
  try {
    worker = spawnOwnedProcess({
      type: "protocol",
      pipeAdapter: "direct",
      command: [...command, extensionWorkerArgument],
      cwd: plan.cwd,
      env: {
        ...inheritedEnvironment,
        NODE_PATH: inheritedEnvironment.NODE_PATH
          ? `${publicApi.nodeModules}${delimiter}${inheritedEnvironment.NODE_PATH}`
          : publicApi.nodeModules
      },
      processTreeTracker
    })
  } catch (cause) {
    const cleanupError = publicApi.dispose()
    if (cleanupError) {
      throw new Error(`${errorMessage(cause, "Could not spawn extension worker")}; ${cleanupError.message}`, { cause })
    }
    throw cause
  }

  let containmentError: Error | undefined
  void worker.containmentFailure.catch(cause => {
    containmentError = cause
    worker.terminate(true)
  })

  let cleanup: Promise<Error | undefined> | undefined
  const cleanupProcess = (): Promise<Error | undefined> => {
    cleanup ??= (async () => {
      let failure: Error | undefined
      try {
        await worker.terminateTree()
      } catch (cause) {
        failure = asError(cause, "Extension worker process scope cleanup failed")
      }
      const publicApiError = publicApi.dispose()
      return combineErrors(failure, publicApiError)
    })()
    return cleanup
  }

  const exited = worker.exited.then(async exit => {
    const cleanupError = await cleanupProcess()
    const error = combineErrors(combineErrors(exit.error, containmentError), cleanupError)
    return { code: exit.code, signal: exit.signal, ...(error ? { error } : {}) }
  })

  return {
    input: worker.input,
    stdout: worker.stdout,
    stderr: worker.stderr,
    protocol: worker.protocol,
    admitted: worker.admitted,
    exited,
    terminate: force => worker.terminate(force),
    async dispose() {
      await cleanupProcess()
      let disposalError: Error | undefined
      try {
        await worker.dispose()
      } catch (cause) {
        disposalError = asError(cause, "Extension worker process disposal failed")
      }
      await exited
      if (disposalError) throw disposalError
    }
  }
}

function createPublicApiModule(removeDirectory: (path: string) => void): {
  readonly nodeModules: string
  dispose(): Error | undefined
} {
  const root = mkdtempSync(join(tmpdir(), "zi-extension-api-"))
  const nodeModules = join(root, "node_modules")
  const packageDirectory = join(nodeModules, "@with-zi", "extension-api")
  try {
    mkdirSync(packageDirectory, { recursive: true, mode: 0o700 })
    writeFileSync(
      join(packageDirectory, "package.json"),
      `${JSON.stringify({ name: "@with-zi/extension-api", type: "module", exports: "./index.js" })}\n`,
      { mode: 0o600 }
    )
    writeFileSync(join(packageDirectory, "index.js"), extensionApiModuleSource, { mode: 0o600 })
  } catch (cause) {
    try {
      removeDirectory(root)
    } catch (cleanupCause) {
      throw new Error(
        `${errorMessage(cause, "Could not create extension public API module")}; cleanup failed: ${errorMessage(cleanupCause, "unknown cleanup error")}`,
        { cause: cleanupCause }
      )
    }
    throw cause
  }
  let disposed = false
  return {
    nodeModules,
    dispose() {
      if (disposed) return undefined
      disposed = true
      try {
        removeDirectory(root)
        return undefined
      } catch (cause) {
        return asError(cause, "Could not remove extension public API module")
      }
    }
  }
}

function combineErrors(first: Error | undefined, second: Error | undefined): Error | undefined {
  if (!first) return second
  if (!second) return first
  return new Error(`${first.message}; ${second.message}`, { cause: first })
}

function asError(cause: unknown, fallback: string): Error {
  return cause instanceof Error ? cause : new Error(fallback)
}

function errorMessage(cause: unknown, fallback: string): string {
  return cause instanceof Error && cause.message ? cause.message : fallback
}

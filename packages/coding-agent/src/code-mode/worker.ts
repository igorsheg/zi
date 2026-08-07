import { closeSync, writeSync } from "node:fs"
import { createRequire } from "node:module"
import { isAbsolute, join, resolve as resolvePath } from "node:path"
import { pathToFileURL } from "node:url"
import { isMainThread, parentPort, Worker, workerData } from "node:worker_threads"

import { normalizeCode } from "./normalize.js"
import {
  CodeModeProtocolDecoder,
  codeModeProtocolVersion,
  encodeCodeModeFrame,
  maxCodeModeCalls,
  maxCodeModeLogBytes,
  maxCodeModeLogs,
  validateCodeModeJson,
  validateCodeModeState,
  validateHostMessage,
  validateWorkerMessage,
  type CodeModeHostMessage,
  type CodeModeJson,
  type CodeModeState,
  type CodeModeWorkerMessage
} from "./protocol.js"

declare const ziCodeRealmSource: string

const realmMarker = "zi-code-mode-realm-v1"
const realmOldGenerationMb = 128
const realmYoungGenerationMb = 16
const realmStackMb = 8
const maxRealmRetainedBytes = 160 * 1024 * 1024
const maxRealmRssBytes = 256 * 1024 * 1024
const maxImportSpecifierBytes = 4_096

class RealmResetError extends Error {}

interface RealmWorkerData {
  readonly type: typeof realmMarker
  readonly generation: number
  readonly cwd: string
}

type RealmInput = Exclude<CodeModeHostMessage, { type: "initialize" }>

type OuterState =
  | { readonly type: "awaiting_initialize" }
  | { readonly type: "idle"; readonly generation: number; readonly realm: Worker }
  | { readonly type: "running"; readonly generation: number; readonly executionId: number; readonly realm: Worker }
  | { readonly type: "disposed" }

type RealmState =
  | { readonly type: "idle"; readonly generation: number }
  | { readonly type: "running"; readonly execution: CellExecution }
  | { readonly type: "disposed" }

export async function runCodeModeWorkerFromStdio(): Promise<void> {
  const decoder = new CodeModeProtocolDecoder(validateHostMessage)
  let state: OuterState = { type: "awaiting_initialize" }

  const fail = (cause: unknown): void => {
    writeSync(2, `${errorMessage(cause)}\n`)
    if (state.type === "idle" || state.type === "running") void state.realm.terminate()
    state = { type: "disposed" }
    process.exit(1)
  }
  const memoryWatchdog = setInterval(() => {
    if (state.type === "running" && process.memoryUsage().rss > maxRealmRssBytes) {
      fail(new Error(`Code realm memory exceeded ${maxRealmRssBytes} bytes`))
    }
  }, 50)
  memoryWatchdog.unref?.()

  try {
    for await (const chunk of process.stdin) {
      for (const message of decoder.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))) {
        if (message.type === "initialize") {
          if (state.type !== "awaiting_initialize") throw new Error("Code worker accepts one initialize message")
          const realm = startRealm(message.generation)
          state = { type: "idle", generation: message.generation, realm }
          realm.on("message", value => {
            try {
              const response = validateWorkerMessage(value)
              if (state.type !== "idle" && state.type !== "running") return
              if (response.generation !== state.generation) throw new Error("Stale code realm generation")
              if (response.type === "tool_call") {
                if (state.type !== "running" || response.executionId !== state.executionId) {
                  throw new Error("Code realm tool call arrived outside its execution")
                }
              } else if (response.type === "completed" || response.type === "failed") {
                if (state.type !== "running" || response.executionId !== state.executionId) {
                  throw new Error("Code realm result arrived outside its execution")
                }
                state = { type: "idle", generation: state.generation, realm }
              }
              send(response)
            } catch (cause) {
              fail(cause)
            }
          })
          realm.once("error", fail)
          realm.once("exit", code => {
            if (state.type === "disposed") return
            fail(new Error(`Code realm exited unexpectedly (${code})`))
          })
          continue
        }

        if (state.type === "awaiting_initialize") throw new Error("Code worker requires initialize first")
        if ((state as OuterState).type === "disposed") break
        if (message.generation !== state.generation) throw new Error("Stale code host generation")
        if (message.type === "execute") {
          if (state.type !== "idle") throw new Error("Code worker already has an active execution")
          // Node worker messages do not have a browser target origin.
          // eslint-disable-next-line unicorn/require-post-message-target-origin
          state.realm.postMessage(message)
          state = {
            type: "running",
            generation: state.generation,
            executionId: message.executionId,
            realm: state.realm
          }
          continue
        }
        if (state.type !== "running" || message.executionId !== state.executionId) {
          throw new Error("Code worker tool response arrived outside its execution")
        }
        // Node worker messages do not have a browser target origin.
        // eslint-disable-next-line unicorn/require-post-message-target-origin
        state.realm.postMessage(message)
      }
    }
    decoder.end()
  } finally {
    clearInterval(memoryWatchdog)
    if (state.type === "idle" || state.type === "running") await state.realm.terminate()
    state = { type: "disposed" }
    closeSync(3)
  }
}

function startRealm(generation: number): Worker {
  const data: RealmWorkerData = { type: realmMarker, generation, cwd: process.cwd() }
  const source = typeof ziCodeRealmSource === "string" ? ziCodeRealmSource : undefined
  return new Worker(source ?? import.meta.url, {
    ...(source ? { eval: true } : {}),
    workerData: data,
    resourceLimits: {
      maxOldGenerationSizeMb: realmOldGenerationMb,
      maxYoungGenerationSizeMb: realmYoungGenerationMb,
      stackSizeMb: realmStackMb
    }
  })
}

async function runRealm(data: RealmWorkerData): Promise<void> {
  const port = parentPort
  if (!port) throw new Error("Code realm requires a parent port")
  const scratch: Record<string, unknown> = {}
  const project = createProjectApi(data.cwd)
  let state: RealmState = { type: "idle", generation: data.generation }

  port.on("message", value => {
    try {
      const message = validateHostMessage(value)
      if (message.type === "initialize") throw new Error("Code realm cannot be initialized twice")
      if (message.generation !== data.generation) throw new Error("Stale code realm input")
      if (message.type === "execute") {
        if (state.type !== "idle") throw new Error("Code realm already has an active execution")
        const execution = new CellExecution(message, scratch, project, response => port.postMessage(response))
        state = { type: "running", execution }
        void execution
          .run()
          .catch(cause => {
            writeSync(2, `Code realm execution failed outside its outcome: ${errorMessage(cause)}\n`)
            process.exit(1)
          })
          .finally(() => {
            if (state.type === "running" && state.execution === execution) {
              state = { type: "idle", generation: data.generation }
            }
          })
        return
      }
      if (state.type !== "running") throw new Error("Code realm tool response arrived while idle")
      state.execution.accept(message)
    } catch (cause) {
      writeSync(2, `Code realm input failed: ${errorMessage(cause)}\n`)
      throw cause
    }
  })

  port.postMessage({ version: codeModeProtocolVersion, type: "ready", generation: data.generation })
}

class CellExecution {
  readonly #generation: number
  readonly #executionId: number
  readonly #code: string
  readonly #tools: ReadonlySet<string>
  readonly #state: CodeModeState
  readonly #scratch: Record<string, unknown>
  readonly #project: Readonly<{ import(specifier: string): Promise<unknown> }>
  readonly #send: (message: CodeModeWorkerMessage) => void
  readonly #pending = new Map<number, ReturnType<typeof deferred<CodeModeJson>>>()
  readonly #logs: string[] = []
  #nextCallId = 0
  #terminateRequested = false
  #settled = false

  constructor(
    message: Extract<CodeModeHostMessage, { type: "execute" }>,
    scratch: Record<string, unknown>,
    project: Readonly<{ import(specifier: string): Promise<unknown> }>,
    emit: (message: CodeModeWorkerMessage) => void
  ) {
    this.#generation = message.generation
    this.#executionId = message.executionId
    this.#code = message.code
    this.#tools = new Set(message.tools)
    this.#state = message.state
    this.#scratch = scratch
    this.#project = project
    this.#send = emit
  }

  async run(): Promise<void> {
    const zi = this.#createZi()
    const cellConsole = Object.freeze({
      log: (...values: unknown[]) => this.#log(values.map(String).join(" ")),
      warn: (...values: unknown[]) => this.#log(`[warn] ${values.map(String).join(" ")}`),
      error: (...values: unknown[]) => this.#log(`[error] ${values.map(String).join(" ")}`)
    })
    try {
      // Full-authority generated cells intentionally use the host runtime's compiler.
      // eslint-disable-next-line typescript/no-implied-eval
      const instantiate = Function(
        "zi",
        "scratch",
        "state",
        "project",
        "console",
        `return (${normalizeCode(this.#code)})`
      )
      const programValue = instantiate(zi, this.#scratch, this.#state, this.#project, cellConsole)
      if (typeof programValue !== "function") throw new Error("Code must evaluate to a function")
      const value: unknown = await programValue({
        zi,
        scratch: this.#scratch,
        state: this.#state,
        project: this.#project,
        console: cellConsole
      })
      const memory = process.memoryUsage()
      if (memory.rss > maxRealmRssBytes || memory.heapUsed + memory.external > maxRealmRetainedBytes) {
        throw new RealmResetError(`Code realm memory exceeded ${maxRealmRetainedBytes} bytes`)
      }
      if (this.#pending.size > 0) {
        throw new Error(
          `Code returned with ${this.#pending.size} unawaited tool ${this.#pending.size === 1 ? "call" : "calls"}`
        )
      }
      const result = value === undefined ? undefined : jsonValue(value)
      const state = stateValue(this.#state)
      this.#finish({
        version: codeModeProtocolVersion,
        type: "completed",
        generation: this.#generation,
        executionId: this.#executionId,
        ...(result === undefined ? {} : { result }),
        state,
        logs: this.#logs
      })
    } catch (cause) {
      this.#finish({
        version: codeModeProtocolVersion,
        type: "failed",
        generation: this.#generation,
        executionId: this.#executionId,
        error: errorMessage(cause),
        logs: this.#logs,
        ...(cause instanceof RealmResetError ? { reset: true } : {})
      })
    }
  }

  accept(message: Exclude<RealmInput, { type: "execute" }>): void {
    if (this.#settled || message.executionId !== this.#executionId) return
    const pending = this.#pending.get(message.id)
    if (!pending) throw new Error(`Unknown code-mode tool response ID: ${message.id}`)
    this.#pending.delete(message.id)
    if (message.type === "tool_result") {
      if (message.terminate) this.#terminateRequested = true
      pending.resolve(message.value)
    } else {
      pending.reject(new Error(message.error))
    }
  }

  #createZi(): Readonly<Record<string, (input?: unknown) => Promise<CodeModeJson>>> {
    const zi: Record<string, (input?: unknown) => Promise<CodeModeJson>> = Object.create(null)
    for (const name of this.#tools) {
      if (name === "then") continue
      zi[name] = input => this.#callHost(name, input)
    }
    Object.defineProperty(zi, Symbol.toPrimitive, { value: () => "[Zi tools]" })
    Object.defineProperty(zi, Symbol.toStringTag, { value: "Zi tools" })
    return Object.freeze(zi)
  }

  #callHost(name: string, input: unknown): Promise<CodeModeJson> {
    if (this.#settled) return Promise.reject(new Error("Code execution ended"))
    if (this.#terminateRequested) return Promise.reject(new Error("A previous tool requested turn termination"))
    if (this.#nextCallId >= maxCodeModeCalls) {
      return Promise.reject(new Error(`Code cannot make more than ${maxCodeModeCalls} tool calls`))
    }
    let toolArguments: CodeModeJson
    try {
      toolArguments = validateCodeModeJson(input ?? {})
    } catch (cause) {
      return Promise.reject(cause)
    }
    const id = this.#nextCallId++
    const pending = deferred<CodeModeJson>()
    this.#pending.set(id, pending)
    this.#send({
      version: codeModeProtocolVersion,
      type: "tool_call",
      generation: this.#generation,
      executionId: this.#executionId,
      id,
      name,
      arguments: toolArguments
    })
    return pending.promise
  }

  #log(value: string): void {
    if (this.#logs.length >= maxCodeModeLogs) return
    this.#logs.push(Buffer.from(value).subarray(0, maxCodeModeLogBytes).toString())
  }

  #finish(message: Extract<CodeModeWorkerMessage, { type: "completed" | "failed" }>): void {
    if (this.#settled) return
    this.#settled = true
    for (const pending of this.#pending.values()) pending.reject(new Error("Code execution ended"))
    this.#pending.clear()
    this.#send(message)
  }
}

function createProjectApi(cwd: string): Readonly<{ import(specifier: string): Promise<unknown> }> {
  const require = createRequire(join(cwd, "package.json"))
  return Object.freeze({
    async import(specifier: string): Promise<unknown> {
      if (
        typeof specifier !== "string" ||
        specifier.length === 0 ||
        Buffer.byteLength(specifier) > maxImportSpecifierBytes
      ) {
        throw new Error("Project imports require a non-empty bounded specifier")
      }
      if (specifier.startsWith("node:") || specifier.startsWith("bun:")) return import(specifier)
      if (specifier.startsWith("./") || specifier.startsWith("../") || isAbsolute(specifier)) {
        return import(pathToFileURL(resolvePath(cwd, specifier)).href)
      }
      return import(pathToFileURL(require.resolve(specifier)).href)
    }
  })
}

function jsonValue(value: unknown): CodeModeJson {
  const decoded: unknown = JSON.parse(JSON.stringify(value))
  return validateCodeModeJson(decoded)
}

function stateValue(value: unknown): CodeModeState {
  const decoded: unknown = JSON.parse(JSON.stringify(value))
  return validateCodeModeState(decoded)
}

function send(message: CodeModeWorkerMessage): void {
  const frame = encodeCodeModeFrame(message)
  let offset = 0
  while (offset < frame.byteLength) {
    const written = writeSync(3, frame, offset)
    if (written === 0) throw new Error("Code-mode protocol output stopped accepting bytes")
    offset += written
  }
}

function deferred<T>(): { readonly promise: Promise<T>; resolve(value: T): void; reject(cause: unknown): void } {
  let settled = false
  let resolvePromise!: (value: T) => void
  let rejectPromise!: (cause: unknown) => void
  const promise = new Promise<T>((complete, fail) => {
    resolvePromise = complete
    rejectPromise = fail
  })
  void promise.catch(() => {})
  return {
    promise,
    resolve(value) {
      if (settled) return
      settled = true
      resolvePromise(value)
    },
    reject(cause) {
      if (settled) return
      settled = true
      rejectPromise(cause)
    }
  }
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? `${cause.name}: ${cause.message}` : String(cause)
}

function isRealmWorkerData(value: unknown): value is RealmWorkerData {
  return (
    typeof value === "object" &&
    value !== null &&
    Reflect.get(value, "type") === realmMarker &&
    typeof Reflect.get(value, "generation") === "number" &&
    typeof Reflect.get(value, "cwd") === "string"
  )
}

if (!isMainThread && isRealmWorkerData(workerData)) {
  void runRealm(workerData).catch(cause => {
    writeSync(2, `Code realm startup failed: ${errorMessage(cause)}\n`)
    process.exit(1)
  })
}

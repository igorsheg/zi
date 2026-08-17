import {
  Client,
  SdkError,
  SdkErrorCode,
  SdkHttpError,
  type CallToolResult,
  type Tool
} from "@modelcontextprotocol/client"

import { validateCodeModeJson, type CodeModeJson } from "../code-mode/protocol.js"
import type { ProcessTreeTracker } from "../processes/process-tree.js"
import type { SessionJson } from "../session-manager.js"
import {
  compareMcpIdentity,
  type McpLoadPlan,
  type McpResolvedHttpServer,
  type McpResolvedServer,
  type McpResolvedStdioServer,
  type McpTransport
} from "./config.js"
import {
  McpHttpTransportError,
  maxMcpSseRetryMs,
  mcpHttpStreamEvidence,
  OwnedHttpTransport,
  type McpHttpStreamEvidence
} from "./http-transport.js"
import { OwnedStdioTransport } from "./stdio-transport.js"

export const maxMcpToolsPerServer = 256
export const maxMcpTools = 512
export const maxMcpToolSchemaBytes = 32 * 1024
export const maxMcpCatalogPages = 32
export const maxMcpCatalogBytes = 2 * 1024 * 1024
export const maxMcpCatalogCandidateBytes = 2 * 1024 * 1024
export const maxMcpCursorBytes = 4 * 1024
export const maxMcpSearchResults = 8
export const maxMcpConcurrentCalls = 16
export const maxMcpArgumentsBytes = 256 * 1024
export const maxMcpCallValueBytes = 256 * 1024
export const maxMcpConnectionConcurrency = 4
export const maxMcpCatalogRefreshConcurrency = 4
export const maxMcpReconnectAttempts = 5

const maxMcpHostOperationMs = 2 * 60_000
const maxMcpConnectionCloseMs = 2_000
const minMcpReconnectDelayMs = 100
const maxToolNameBytes = 512
const maxDescriptionBytes = 16 * 1024
const maxSearchQueryBytes = 4 * 1024
const maxMatchDescriptionBytes = 512
const maxStatusMessageBytes = 16 * 1024
const maxProgressBytes = 4 * 1024
const maxCallContentBlocks = 1024

export interface McpToolDescriptor {
  readonly server: string
  readonly name: string
  readonly description: string
  readonly inputSchema: SessionJson
  readonly outputSchema?: SessionJson
}

export interface McpToolMatch {
  readonly server: string
  readonly tool: string
  readonly description: string
}

export type McpCallContent =
  | { readonly type: "text"; readonly text: string }
  | { readonly type: "omitted"; readonly contentType: string; readonly mimeType?: string }

export interface McpCallValue {
  readonly content: readonly McpCallContent[]
  readonly structuredContent?: CodeModeJson
}

export type McpServerSnapshot =
  | { readonly name: string; readonly status: "disabled" }
  | { readonly name: string; readonly transport: McpTransport; readonly status: "starting" }
  | {
      readonly name: string
      readonly transport: McpTransport
      readonly status: "ready"
      readonly tools: number
      readonly message?: string
    }
  | {
      readonly name: string
      readonly transport: McpTransport
      readonly status: "backoff"
      readonly attempt: number
      readonly retryAt: number
      readonly message: string
    }
  | { readonly name: string; readonly transport?: McpTransport; readonly status: "failed"; readonly message: string }
  | { readonly name: string; readonly transport: McpTransport; readonly status: "stopping" }

export interface McpReloadResult {
  readonly failures: readonly { readonly name: string; readonly message: string }[]
}

export type McpProgress = (message: string) => void

interface CatalogRefreshOperation {
  readonly id: number
  readonly controller: AbortController
  readonly settled: Promise<void>
  intent: "current" | "rerun"
}

interface CatalogRefreshJob {
  readonly name: string
  readonly generation: number
  readonly operation: CatalogRefreshOperation
  readonly settle: () => void
}

type RefreshState =
  | { readonly type: "idle" }
  | { readonly type: "refreshing"; readonly operation: CatalogRefreshOperation }

type InitialRefreshState = { readonly type: "current" } | { readonly type: "rerun" }

interface CatalogReservation {
  readonly id: number
  readonly priority: number
  readonly controller: AbortController
  bytes: number
  rejection?: Error
}

interface CatalogCandidate {
  readonly catalog: readonly McpToolDescriptor[]
  readonly encodedBytes: number
  readonly reservation: CatalogReservation
  readonly message?: string
}

type McpTransportOwner = OwnedStdioTransport | OwnedHttpTransport

interface InitialServerAdmission {
  readonly plan: McpResolvedStdioServer | McpResolvedHttpServer
  readonly priority: number
  readonly generation: number
  readonly controller: AbortController
  readonly settled: Promise<void>
  readonly settle: () => void
  readonly unlink: () => void
}

interface InitialConnection {
  closed: boolean
  disposed: boolean
  terminalMessage?: string
}

interface ConnectionWaiter {
  readonly signal: AbortSignal
  readonly resolve: (release: (() => void) | undefined) => void
  readonly abort: () => void
}

type InitialServerOutcome =
  | {
      readonly type: "ready"
      readonly admission: InitialServerAdmission
      readonly client: Client
      readonly transport: McpTransportOwner
      readonly candidate: CatalogCandidate
      readonly connection: InitialConnection
    }
  | { readonly type: "failed"; readonly admission: InitialServerAdmission; readonly message: string }

type ServerState =
  | { readonly type: "disabled"; readonly plan: McpResolvedServer }
  | {
      readonly type: "starting"
      readonly generation: number
      readonly plan: McpResolvedStdioServer | McpResolvedHttpServer
      readonly controller: AbortController
      readonly settled: Promise<void>
      readonly refresh: InitialRefreshState
    }
  | {
      readonly type: "ready"
      readonly generation: number
      readonly plan: McpResolvedStdioServer | McpResolvedHttpServer
      readonly client: Client
      readonly transport: McpTransportOwner
      readonly catalog: readonly McpToolDescriptor[]
      readonly catalogBytes: number
      readonly refresh: RefreshState
      readonly connectedAt: number
      readonly outageAttempt: number
      readonly message?: string
    }
  | {
      readonly type: "backoff"
      readonly generation: number
      readonly plan: McpResolvedHttpServer
      readonly attempt: number
      readonly retryAt: number
      readonly timer: ReturnType<typeof setTimeout>
      readonly message: string
    }
  | {
      readonly type: "failed"
      readonly generation: number
      readonly name: string
      readonly transport?: McpTransport
      readonly required: boolean
      readonly plan?: McpResolvedServer
      readonly message: string
    }
  | {
      readonly type: "stopping"
      readonly generation: number
      readonly plan: McpResolvedStdioServer | McpResolvedHttpServer
      readonly settled: Promise<void>
    }
  | { readonly type: "stopped"; readonly name: string }

type HostState =
  | { readonly type: "constructed" }
  | { readonly type: "starting"; readonly controller: AbortController; readonly settled: Promise<void> }
  | { readonly type: "running" }
  | {
      readonly type: "reloading"
      readonly operationId: number
      readonly controller: AbortController
      readonly settled: Promise<McpReloadResult>
    }
  | { readonly type: "stopping"; readonly settled: Promise<void> }
  | { readonly type: "stopped" }

type CallReason =
  | "active"
  | "caller_cancelled"
  | "deadline_exceeded"
  | "generation_lost"
  | "server_replaced"
  | "host_disposed"

interface ActiveCall {
  readonly id: number
  readonly server: string
  readonly generation: number
  readonly controller: AbortController
  readonly settled: Promise<void>
  reason: CallReason
}

export class McpHost {
  readonly #processTree: ProcessTreeTracker
  readonly #servers = new Map<string, ServerState>()
  readonly #listeners = new Set<(server: string) => void>()
  readonly #calls = new Map<number, ActiveCall>()
  readonly #refreshes = new Set<Promise<void>>()
  readonly #refreshQueue: CatalogRefreshJob[] = []
  readonly #connectionQueue: ConnectionWaiter[] = []
  readonly #serverPriorities = new Map<string, number>()
  readonly #candidateReservations = new Map<number, CatalogReservation>()
  #state: HostState = { type: "constructed" }
  #nextGeneration = 0
  #nextCallId = 0
  #nextRefreshOperationId = 0
  #nextCandidateReservationId = 0
  #nextReloadOperationId = 0
  #activeConnections = 0
  #activeRefreshes = 0
  #candidateBytes = 0

  constructor(processTree: ProcessTreeTracker) {
    this.#processTree = processTree
  }

  start(plan: McpLoadPlan): Promise<void> {
    if (this.#state.type !== "constructed") throw new Error("MCP host can only be started once")
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), maxMcpHostOperationMs)
    timeout.unref?.()
    const settled = Promise.resolve()
      .then(() => this.#start(plan, controller))
      .finally(() => clearTimeout(timeout))
    this.#state = { type: "starting", controller, settled }
    return settled
  }

  reload(plan: McpLoadPlan): Promise<McpReloadResult> {
    if (this.#state.type !== "running") throw new Error("MCP host reload requires a running host")
    const operationId = ++this.#nextReloadOperationId
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), maxMcpHostOperationMs)
    timeout.unref?.()
    const settled = Promise.resolve()
      .then(() => this.#reload(plan, operationId, controller))
      .finally(() => clearTimeout(timeout))
    this.#state = { type: "reloading", operationId, controller, settled }
    return settled
  }

  search(query: string, server?: string, limit = maxMcpSearchResults): readonly McpToolMatch[] {
    this.#assertAvailable("search")
    if (typeof query !== "string" || query.trim().length === 0 || Buffer.byteLength(query) > maxSearchQueryBytes) {
      throw new Error("MCP search query must be a non-empty bounded string")
    }
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > maxMcpSearchResults) {
      throw new Error(`MCP search limit must be between 1 and ${maxMcpSearchResults}`)
    }
    const normalized = asciiLower(query.trim())
    const ranked: { readonly score: number; readonly descriptor: McpToolDescriptor }[] = []
    for (const state of this.#servers.values()) {
      if (state.type !== "ready" || (server !== undefined && state.plan.name !== server)) continue
      for (const descriptor of state.catalog) {
        const score = searchScore(normalized, descriptor)
        if (score !== undefined) ranked.push({ score, descriptor })
      }
    }
    ranked.sort(
      (left, right) =>
        left.score - right.score ||
        compareMcpIdentity(left.descriptor.server, right.descriptor.server) ||
        compareMcpIdentity(left.descriptor.name, right.descriptor.name)
    )
    return Object.freeze(
      ranked
        .slice(0, limit)
        .map(({ descriptor }) =>
          Object.freeze({
            server: descriptor.server,
            tool: descriptor.name,
            description: clipUtf8(descriptor.description, maxMatchDescriptionBytes)
          })
        )
    )
  }

  describe(server: string, tool: string): McpToolDescriptor {
    const state = this.#readyServer(server)
    const descriptor = state.catalog.find(candidate => candidate.name === tool)
    if (!descriptor) throw new Error(`Unknown MCP tool: ${server}/${tool}`)
    return descriptor
  }

  async call(
    server: string,
    tool: string,
    arguments_: Readonly<Record<string, unknown>>,
    signal?: AbortSignal,
    onProgress?: McpProgress
  ): Promise<McpCallValue> {
    const state = this.#readyServer(server)
    const descriptor = state.catalog.find(candidate => candidate.name === tool)
    if (!descriptor) throw new Error(`Unknown MCP tool: ${server}/${tool}`)
    if (signal?.aborted) throw new Error("MCP tool call was cancelled")
    const encodedArguments = JSON.stringify(arguments_)
    if (Buffer.byteLength(encodedArguments) > maxMcpArgumentsBytes) {
      throw new Error(`MCP tool arguments cannot exceed ${maxMcpArgumentsBytes} encoded bytes`)
    }
    validateCodeModeJson(arguments_)
    if (Array.isArray(arguments_) || arguments_ === null) throw new Error("MCP tool arguments must be a JSON object")
    if (this.#calls.size >= maxMcpConcurrentCalls) {
      throw new Error(`MCP call concurrency cannot exceed ${maxMcpConcurrentCalls}`)
    }

    const controller = new AbortController()
    let settle!: () => void
    const settled = new Promise<void>(resolve => {
      settle = resolve
    })
    const call: ActiveCall = {
      id: ++this.#nextCallId,
      server,
      generation: state.generation,
      controller,
      settled,
      reason: "active"
    }
    this.#calls.set(call.id, call)
    const cancel = (): void => {
      if (call.reason !== "active") return
      call.reason = "caller_cancelled"
      controller.abort()
    }
    signal?.addEventListener("abort", cancel, { once: true })
    const deadline = setTimeout(() => {
      if (call.reason !== "active") return
      call.reason = "deadline_exceeded"
      controller.abort()
    }, state.plan.toolTimeoutMs)
    deadline.unref?.()

    try {
      const result = await state.client.request(
        { method: "tools/call", params: { name: descriptor.name, arguments: arguments_ } },
        {
          signal: controller.signal,
          timeout: state.plan.toolTimeoutMs,
          maxTotalTimeout: state.plan.toolTimeoutMs,
          resetTimeoutOnProgress: false,
          onprogress: progress => {
            const current = this.#servers.get(server)
            if (call.reason !== "active" || current?.type !== "ready" || current.generation !== call.generation) {
              return
            }
            try {
              onProgress?.(progressText(progress, state.plan))
            } catch {
              // Progress is a projection; observer failure cannot invalidate the call or connection.
              return
            }
          }
        }
      )
      if (call.reason !== "active") throw callError(call.reason)
      const current = this.#servers.get(server)
      if (current?.type !== "ready" || current.generation !== state.generation) {
        call.reason = "generation_lost"
        throw callError(call.reason)
      }
      if (result.isError) throw new Error(serverErrorText(result))
      return projectCallValue(result, state.plan)
    } catch (cause) {
      if (call.reason === "active" && cause instanceof SdkError && cause.code === SdkErrorCode.RequestTimeout) {
        call.reason = "deadline_exceeded"
      }
      if (call.reason !== "active") throw callError(call.reason)
      const failure = new Error(`MCP tool ${server}/${tool} failed: ${serverFailureMessage(cause, state.plan)}`)
      if (state.plan.transport === "streamable-http" && isTerminalHttpFailure(cause)) {
        void this.#retireHttpGeneration(server, state.generation, serverFailureMessage(cause, state.plan))
      }
      throw failure
    } finally {
      clearTimeout(deadline)
      signal?.removeEventListener("abort", cancel)
      this.#calls.delete(call.id)
      settle()
    }
  }

  snapshot(): readonly McpServerSnapshot[] {
    return Object.freeze(
      [...this.#servers.values()]
        .map(serverSnapshot)
        .filter((snapshot): snapshot is McpServerSnapshot => snapshot !== undefined)
        .toSorted((left, right) => compareMcpIdentity(left.name, right.name))
    )
  }

  subscribe(listener: (server: string) => void): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  dispose(): Promise<void> {
    const state = this.#state
    if (state.type === "stopped") {
      this.#listeners.clear()
      return Promise.resolve()
    }
    if (state.type === "stopping") return state.settled
    if (state.type === "starting" || state.type === "reloading") state.controller.abort()
    for (const call of this.#calls.values()) {
      if (call.reason !== "active") continue
      call.reason = "host_disposed"
      call.controller.abort()
    }
    for (const server of this.#servers.values()) {
      if (server.type === "ready" && server.refresh.type === "refreshing") {
        server.refresh.operation.controller.abort()
      }
    }
    const settled = this.#stop()
    this.#state = { type: "stopping", settled }
    return settled
  }

  waitForIdle(): Promise<void> {
    const operations = [...this.#calls.values()].map(call => call.settled)
    operations.push(this.#waitForRefreshes())
    for (const server of this.#servers.values()) {
      if (server.type === "starting" || server.type === "stopping") operations.push(server.settled)
    }
    if (this.#state.type === "starting" || this.#state.type === "reloading" || this.#state.type === "stopping") {
      operations.push(this.#state.settled.then(() => undefined))
    }
    return Promise.allSettled(operations).then(() => undefined)
  }

  async #start(plan: McpLoadPlan, controller: AbortController): Promise<void> {
    const admissions: InitialServerAdmission[] = []
    const outcomes: InitialServerOutcome[] = []
    try {
      for (const diagnostic of plan.diagnostics) {
        this.#servers.set(diagnostic.name, {
          type: "failed",
          generation: 0,
          name: diagnostic.name,
          required: diagnostic.required,
          message: clipUtf8(diagnostic.message, maxStatusMessageBytes)
        })
      }
      if (plan.diagnostics.some(diagnostic => diagnostic.required)) {
        throw new Error(plan.diagnostics.find(diagnostic => diagnostic.required)!.message)
      }
      for (const server of plan.servers) {
        if (!server.enabled) this.#servers.set(server.name, { type: "disabled", plan: server })
      }

      const enabled = plan.servers.filter(
        (server): server is McpResolvedStdioServer | McpResolvedHttpServer => server.enabled
      )
      this.#setServerPriorities(enabled)
      for (const server of enabled) admissions.push(this.#admitServer(server, controller.signal))
      for (const admission of admissions) this.#emit(admission.plan.name)

      outcomes.push(...(await Promise.all(admissions.map(admission => this.#connectServer(admission)))))
      const reruns: { readonly name: string; readonly generation: number }[] = []
      for (const outcome of outcomes.toSorted((left, right) => left.admission.priority - right.admission.priority)) {
        const { admission } = outcome
        try {
          if (!this.#isCurrentAdmission(admission)) {
            // Initial outcomes commit and release in priority order so aggregate admission is deterministic.
            // oxlint-disable-next-line no-await-in-loop
            if (outcome.type === "ready") await this.#closeInitialOutcome(outcome)
            continue
          }
          if (outcome.type === "failed") {
            this.#servers.set(admission.plan.name, {
              type: "failed",
              generation: admission.generation,
              name: admission.plan.name,
              transport: admission.plan.transport,
              required: admission.plan.required,
              plan: admission.plan,
              message: outcome.message
            })
            this.#emit(admission.plan.name)
            continue
          }
          if (admission.controller.signal.aborted || outcome.connection.closed) {
            // oxlint-disable-next-line no-await-in-loop -- release this priority slot before publishing its failure.
            await this.#closeInitialOutcome(outcome)
            if (!this.#isCurrentAdmission(admission)) continue
            this.#servers.set(admission.plan.name, {
              type: "failed",
              generation: admission.generation,
              name: admission.plan.name,
              transport: admission.plan.transport,
              required: admission.plan.required,
              plan: admission.plan,
              message: "MCP server connection closed during startup"
            })
            this.#emit(admission.plan.name)
            continue
          }
          try {
            this.#assertCatalogCapacity(admission.plan.name, outcome.candidate)
          } catch (cause) {
            // oxlint-disable-next-line no-await-in-loop -- release this priority slot before publishing its failure.
            await this.#closeInitialOutcome(outcome)
            if (!this.#isCurrentAdmission(admission)) continue
            this.#servers.set(admission.plan.name, {
              type: "failed",
              generation: admission.generation,
              name: admission.plan.name,
              transport: admission.plan.transport,
              required: admission.plan.required,
              plan: admission.plan,
              message: serverFailureMessage(cause, admission.plan)
            })
            this.#emit(admission.plan.name)
            continue
          }
          const current = this.#servers.get(admission.plan.name)
          if (current?.type !== "starting" || current.generation !== admission.generation) continue
          const refreshRequested = current.refresh.type === "rerun"
          this.#servers.set(admission.plan.name, {
            type: "ready",
            generation: admission.generation,
            plan: admission.plan,
            client: outcome.client,
            transport: outcome.transport,
            catalog: outcome.candidate.catalog,
            catalogBytes: outcome.candidate.encodedBytes,
            refresh: { type: "idle" },
            connectedAt: Date.now(),
            outageAttempt: 0,
            ...(outcome.candidate.message ? { message: outcome.candidate.message } : {})
          })
          this.#releaseCandidate(outcome.candidate.reservation)
          this.#emit(admission.plan.name)
          if (refreshRequested) reruns.push({ name: admission.plan.name, generation: admission.generation })
        } finally {
          admission.unlink()
          admission.settle()
        }
      }

      if (controller.signal.aborted || this.#state.type !== "starting") {
        throw new Error("MCP host startup was cancelled")
      }
      const requiredFailure = [...this.#servers.values()].find(
        (state): state is Extract<ServerState, { readonly type: "failed" }> => state.type === "failed" && state.required
      )
      if (requiredFailure) {
        throw new Error(`Required MCP server ${requiredFailure.name} failed: ${requiredFailure.message}`)
      }
      this.#state = { type: "running" }
      for (const rerun of reruns) this.#requestCatalogRefresh(rerun.name, rerun.generation)
    } catch (cause) {
      for (const admission of admissions) {
        admission.controller.abort()
        admission.unlink()
        admission.settle()
      }
      for (const outcome of outcomes) {
        const current = this.#servers.get(outcome.admission.plan.name)
        if (
          outcome.type === "ready" &&
          current?.type === "starting" &&
          current.generation === outcome.admission.generation
        ) {
          // oxlint-disable-next-line no-await-in-loop -- bounded cleanup preserves one resource owner per outcome.
          await this.#closeInitialOutcome(outcome)
        }
      }
      await this.#closeServers()
      this.#state = { type: "stopped" }
      throw cause
    }
  }

  async #reload(plan: McpLoadPlan, operationId: number, controller: AbortController): Promise<McpReloadResult> {
    const failures: { readonly name: string; readonly message: string }[] = []
    const configuredNames = new Set([
      ...plan.servers.map(server => server.name),
      ...plan.diagnostics.map(diagnostic => diagnostic.name)
    ])

    for (const diagnostic of plan.diagnostics) {
      failures.push({ name: diagnostic.name, message: clipUtf8(diagnostic.message, maxStatusMessageBytes) })
      if (this.#servers.has(diagnostic.name)) continue
      this.#servers.set(diagnostic.name, {
        type: "failed",
        generation: ++this.#nextGeneration,
        name: diagnostic.name,
        required: diagnostic.required,
        message: clipUtf8(diagnostic.message, maxStatusMessageBytes)
      })
      this.#emit(diagnostic.name)
    }

    for (const name of [...this.#servers.keys()].toSorted(compareMcpIdentity)) {
      if (configuredNames.has(name)) continue
      // Reload replacements are serialized so one configured name never owns overlapping process generations.
      // oxlint-disable-next-line no-await-in-loop
      await this.#stopServer(name, "server_replaced", true)
      if (controller.signal.aborted) break
    }

    for (const server of plan.servers) {
      if (controller.signal.aborted) break
      const current = this.#servers.get(server.name)
      const currentPlan = current && resolvedServerPlan(current)
      if (current?.type !== "failed" && currentPlan && sameResolvedServer(currentPlan, server)) continue

      // oxlint-disable-next-line no-await-in-loop
      await this.#stopServer(server.name, "server_replaced", false)
      if (controller.signal.aborted) break
      if (!server.enabled) {
        this.#servers.set(server.name, { type: "disabled", plan: server })
        this.#emit(server.name)
        continue
      }

      // oxlint-disable-next-line no-await-in-loop
      const failure = await this.#startReloadServer(server, controller.signal)
      if (failure) failures.push(failure)
    }

    this.#rebuildServerPriorities()
    const failureNames = new Set(failures.map(failure => failure.name))
    for (const snapshot of this.snapshot()) {
      if ((snapshot.status !== "failed" && snapshot.status !== "backoff") || failureNames.has(snapshot.name)) continue
      failures.push(Object.freeze({ name: snapshot.name, message: snapshot.message }))
      failureNames.add(snapshot.name)
    }
    const result = Object.freeze({ failures: Object.freeze(failures) })
    const current = this.#state
    if (current.type === "reloading" && current.operationId === operationId) this.#state = { type: "running" }
    return result
  }

  async #startReloadServer(
    plan: McpResolvedStdioServer | McpResolvedHttpServer,
    signal: AbortSignal
  ): Promise<{ readonly name: string; readonly message: string } | undefined> {
    const admission = this.#admitServer(plan, signal)
    this.#emit(plan.name)
    const outcome = await this.#connectServer(admission)
    try {
      if (!this.#isCurrentAdmission(admission)) {
        if (outcome.type === "ready") await this.#closeInitialOutcome(outcome)
        return undefined
      }
      if (signal.aborted) {
        if (outcome.type === "ready") await this.#closeInitialOutcome(outcome)
        const message = "MCP server reload exceeded the host deadline"
        this.#servers.set(plan.name, {
          type: "failed",
          generation: admission.generation,
          name: plan.name,
          transport: plan.transport,
          required: plan.required,
          plan,
          message
        })
        this.#emit(plan.name)
        return Object.freeze({ name: plan.name, message })
      }
      if (outcome.type === "failed") {
        this.#servers.set(plan.name, {
          type: "failed",
          generation: admission.generation,
          name: plan.name,
          transport: plan.transport,
          required: plan.required,
          plan,
          message: outcome.message
        })
        this.#emit(plan.name)
        return Object.freeze({ name: plan.name, message: outcome.message })
      }
      try {
        this.#assertCatalogCapacity(plan.name, outcome.candidate)
      } catch (cause) {
        await this.#closeInitialOutcome(outcome)
        const message = serverFailureMessage(cause, plan)
        if (!this.#isCurrentAdmission(admission)) return undefined
        this.#servers.set(plan.name, {
          type: "failed",
          generation: admission.generation,
          name: plan.name,
          transport: plan.transport,
          required: plan.required,
          plan,
          message
        })
        this.#emit(plan.name)
        return Object.freeze({ name: plan.name, message })
      }
      this.#servers.set(plan.name, {
        type: "ready",
        generation: admission.generation,
        plan,
        client: outcome.client,
        transport: outcome.transport,
        catalog: outcome.candidate.catalog,
        catalogBytes: outcome.candidate.encodedBytes,
        refresh: { type: "idle" },
        connectedAt: Date.now(),
        outageAttempt: 0,
        ...(outcome.candidate.message ? { message: outcome.candidate.message } : {})
      })
      this.#releaseCandidate(outcome.candidate.reservation)
      this.#emit(plan.name)
      return undefined
    } finally {
      admission.unlink()
      admission.settle()
    }
  }

  #setServerPriorities(servers: readonly (McpResolvedStdioServer | McpResolvedHttpServer)[]): void {
    this.#serverPriorities.clear()
    const ordered = servers
      .map((server, index) => ({ server, index }))
      .toSorted((left, right) =>
        left.server.required === right.server.required ? left.index - right.index : left.server.required ? -1 : 1
      )
    for (const [priority, entry] of ordered.entries()) this.#serverPriorities.set(entry.server.name, priority)
  }

  #rebuildServerPriorities(): void {
    const servers = [...this.#servers.values()]
      .map(resolvedServerPlan)
      .filter((plan): plan is McpResolvedStdioServer | McpResolvedHttpServer => plan !== undefined && plan.enabled)
      .toSorted((left, right) => compareMcpIdentity(left.name, right.name))
    this.#setServerPriorities(servers)
  }

  #isCurrentAdmission(admission: InitialServerAdmission): boolean {
    const current = this.#servers.get(admission.plan.name)
    return (
      this.#state.type !== "stopping" &&
      this.#state.type !== "stopped" &&
      current?.type === "starting" &&
      current.generation === admission.generation
    )
  }

  #admitServer(plan: McpResolvedStdioServer | McpResolvedHttpServer, hostSignal: AbortSignal): InitialServerAdmission {
    const generation = ++this.#nextGeneration
    const controller = new AbortController()
    const abort = (): void => controller.abort()
    hostSignal.addEventListener("abort", abort, { once: true })
    let settle!: () => void
    const settled = new Promise<void>(resolve => {
      settle = resolve
    })
    const admission = {
      plan,
      priority: this.#serverPriorities.get(plan.name) ?? this.#serverPriorities.size,
      generation,
      controller,
      settled,
      settle,
      unlink: () => hostSignal.removeEventListener("abort", abort)
    }
    this.#servers.set(plan.name, {
      type: "starting",
      generation,
      plan,
      controller,
      settled,
      refresh: { type: "current" }
    })
    return admission
  }

  async #connectServer(admission: InitialServerAdmission): Promise<InitialServerOutcome> {
    const release = await this.#takeConnectionSlot(admission.controller.signal)
    if (!release) return { type: "failed", admission, message: "MCP server startup was cancelled" }
    try {
      return await this.#openServer(admission)
    } finally {
      release()
    }
  }

  #takeConnectionSlot(signal: AbortSignal): Promise<(() => void) | undefined> {
    if (signal.aborted) return Promise.resolve(undefined)
    if (this.#activeConnections < maxMcpConnectionConcurrency) {
      this.#activeConnections++
      return Promise.resolve(() => this.#releaseConnectionSlot())
    }
    return new Promise(resolve => {
      const abort = (): void => {
        const index = this.#connectionQueue.indexOf(waiter)
        if (index === -1) return
        this.#connectionQueue.splice(index, 1)
        resolve(undefined)
      }
      const waiter: ConnectionWaiter = { signal, resolve, abort }
      this.#connectionQueue.push(waiter)
      signal.addEventListener("abort", abort, { once: true })
    })
  }

  #releaseConnectionSlot(): void {
    this.#activeConnections--
    while (this.#connectionQueue.length > 0) {
      const waiter = this.#connectionQueue.shift()!
      waiter.signal.removeEventListener("abort", waiter.abort)
      if (waiter.signal.aborted) {
        waiter.resolve(undefined)
        continue
      }
      this.#activeConnections++
      waiter.resolve(() => this.#releaseConnectionSlot())
      return
    }
  }

  async #openServer(admission: InitialServerAdmission): Promise<InitialServerOutcome> {
    const { plan, generation, controller } = admission
    if (controller.signal.aborted || !this.#canConnect()) {
      return { type: "failed", admission, message: "MCP server startup was cancelled" }
    }
    const transport: McpTransportOwner =
      plan.transport === "stdio" ? new OwnedStdioTransport(plan, this.#processTree) : new OwnedHttpTransport(plan)
    const sdkTransport = transport instanceof OwnedHttpTransport ? transport.transport : transport
    const client = new Client({ name: "zi", version: "0.0.0" })
    const connection: InitialConnection = { closed: false, disposed: false }
    // The close handler must fence publication from the first transport byte, not only after discovery.
    // oxlint-disable-next-line unicorn/prefer-add-event-listener -- the SDK Client exposes only onclose.
    client.onclose = () => {
      connection.closed = true
      this.#connectionClosed(plan.name, generation)
    }
    client.setNotificationHandler("notifications/tools/list_changed", () => {
      this.#requestCatalogRefresh(plan.name, generation)
    })
    if (plan.transport === "streamable-http") {
      // oxlint-disable-next-line unicorn/prefer-add-event-listener -- the SDK Client exposes only onerror.
      client.onerror = error => {
        const evidence = mcpHttpStreamEvidence(error)
        if (evidence.type !== "transient") connection.terminalMessage = evidence.message
        this.#httpStreamError(plan.name, generation, evidence)
      }
    }
    const timeout = setTimeout(() => controller.abort(), plan.startupTimeoutMs)
    timeout.unref?.()
    let candidate: CatalogCandidate | undefined
    try {
      await client.connect(sdkTransport, {
        signal: controller.signal,
        timeout: plan.startupTimeoutMs,
        maxTotalTimeout: plan.startupTimeoutMs,
        resetTimeoutOnProgress: false
      })
      candidate = await this.#fetchCatalog(client, plan, controller, plan.startupTimeoutMs)
      if (controller.signal.aborted || connection.closed) throw new Error("MCP server startup became stale")
      return { type: "ready", admission, client, transport, candidate, connection }
    } catch (cause) {
      if (candidate) this.#releaseCandidate(candidate.reservation)
      delete client.onclose
      delete client.onerror
      client.removeNotificationHandler("notifications/tools/list_changed")
      await this.#closeConnection(client, transport)
      return {
        type: "failed",
        admission,
        message: connection.terminalMessage
          ? serverFailureMessage(connection.terminalMessage, plan)
          : serverFailureMessage(cause, plan)
      }
    } finally {
      clearTimeout(timeout)
    }
  }

  async #closeInitialOutcome(outcome: Extract<InitialServerOutcome, { readonly type: "ready" }>): Promise<void> {
    if (outcome.connection.disposed) return
    outcome.connection.disposed = true
    this.#releaseCandidate(outcome.candidate.reservation)
    delete outcome.client.onclose
    delete outcome.client.onerror
    outcome.client.removeNotificationHandler("notifications/tools/list_changed")
    await this.#closeConnection(outcome.client, outcome.transport)
  }

  async #closeConnection(client: Client, transport: McpTransportOwner): Promise<void> {
    await settleMcpClose(Promise.resolve().then(() => transport.close()))
    await settleMcpClose(Promise.resolve().then(() => client.close()))
  }

  #requestCatalogRefresh(name: string, generation: number): void {
    if (this.#state.type === "stopping" || this.#state.type === "stopped") return
    const state = this.#servers.get(name)
    if (state?.type !== "starting" && state?.type !== "ready") return
    if (state.generation !== generation) return
    if (state.type === "starting") {
      if (state.refresh.type === "current") this.#servers.set(name, { ...state, refresh: { type: "rerun" } })
      return
    }
    if (state.type !== "ready") return
    if (state.refresh.type === "refreshing") {
      state.refresh.operation.intent = "rerun"
      return
    }

    const controller = new AbortController()
    let settle!: () => void
    const settled = new Promise<void>(resolve => {
      settle = resolve
    })
    const operation: CatalogRefreshOperation = {
      id: ++this.#nextRefreshOperationId,
      controller,
      settled,
      intent: "current"
    }
    this.#servers.set(name, { ...state, refresh: { type: "refreshing", operation } })
    this.#refreshes.add(settled)
    this.#refreshQueue.push({ name, generation, operation, settle })
    this.#drainCatalogRefreshes()
  }

  #drainCatalogRefreshes(): void {
    while (this.#activeRefreshes < maxMcpCatalogRefreshConcurrency) {
      const job = this.#refreshQueue.shift()
      if (!job) return
      this.#activeRefreshes++
      void this.#refreshCatalog(job.name, job.generation, job.operation).finally(() => {
        this.#refreshes.delete(job.operation.settled)
        job.settle()
        this.#activeRefreshes--
        this.#drainCatalogRefreshes()
      })
    }
  }

  async #refreshCatalog(name: string, generation: number, operation: CatalogRefreshOperation): Promise<void> {
    const admitted = this.#servers.get(name)
    if (admitted?.type !== "ready" || admitted.generation !== generation) return
    const timeout = setTimeout(() => operation.controller.abort(), admitted.plan.startupTimeoutMs)
    timeout.unref?.()
    let candidate: CatalogCandidate | undefined
    let rerun = false
    try {
      candidate = await this.#fetchCatalog(
        admitted.client,
        admitted.plan,
        operation.controller,
        admitted.plan.startupTimeoutMs
      )
      const current = this.#servers.get(name)
      if (
        current?.type !== "ready" ||
        current.generation !== generation ||
        current.refresh.type !== "refreshing" ||
        current.refresh.operation.id !== operation.id ||
        operation.controller.signal.aborted
      ) {
        return
      }
      this.#assertCatalogCapacity(name, candidate)
      rerun = operation.intent === "rerun"
      const { message: _previousMessage, ...stable } = current
      this.#servers.set(name, {
        ...stable,
        catalog: candidate.catalog,
        catalogBytes: candidate.encodedBytes,
        refresh: { type: "idle" },
        ...(candidate.message ? { message: candidate.message } : {})
      })
      this.#emit(name)
    } catch (cause) {
      const current = this.#servers.get(name)
      if (
        this.#state.type === "stopping" ||
        this.#state.type === "stopped" ||
        current?.type !== "ready" ||
        current.generation !== generation ||
        current.refresh.type !== "refreshing" ||
        current.refresh.operation.id !== operation.id
      ) {
        return
      }
      rerun = operation.intent === "rerun"
      const message = serverFailureMessage(cause, current.plan, "Catalog refresh failed: ")
      if (current.plan.transport === "streamable-http" && isTerminalHttpFailure(cause)) {
        void this.#retireHttpGeneration(name, generation, message)
        return
      }
      this.#servers.set(name, { ...current, refresh: { type: "idle" }, message })
      this.#emit(name)
    } finally {
      if (candidate) this.#releaseCandidate(candidate.reservation)
      clearTimeout(timeout)
    }
    if (rerun) this.#requestCatalogRefresh(name, generation)
  }

  async #fetchCatalog(
    client: Client,
    plan: McpResolvedStdioServer | McpResolvedHttpServer,
    controller: AbortController,
    timeoutMs: number
  ): Promise<CatalogCandidate> {
    const names = new Set<string>()
    const cursors = new Set<string>()
    const catalog: McpToolDescriptor[] = []
    const reservation = this.#reserveCandidate(plan.name, controller)
    let cursor: string | undefined
    let taskRequiredOmitted = 0
    let sensitiveNameOmitted = 0
    try {
      for (let page = 0; page < maxMcpCatalogPages; page++) {
        // Pages are cursor-dependent and must remain serial.
        // oxlint-disable-next-line no-await-in-loop
        const listed = await client.request(
          { method: "tools/list", params: cursor === undefined ? {} : { cursor } },
          { signal: controller.signal, timeout: timeoutMs, maxTotalTimeout: timeoutMs, resetTimeoutOnProgress: false }
        )
        if (reservation.rejection) throw reservation.rejection
        for (const tool of listed.tools) {
          if (names.has(tool.name)) throw new Error(`MCP server published duplicate tool name: ${tool.name}`)
          if (names.size >= maxMcpToolsPerServer) {
            throw new Error(`MCP server cannot publish more than ${maxMcpToolsPerServer} tools`)
          }
          names.add(tool.name)
          if (redactServerText(tool.name, plan) !== tool.name) {
            sensitiveNameOmitted++
            continue
          }
          const descriptor = catalogDescriptor(plan, tool)
          if (!descriptor) {
            taskRequiredOmitted++
            continue
          }
          catalog.push(descriptor)
          const encodedBytes = Buffer.byteLength(JSON.stringify(catalog))
          if (encodedBytes > maxMcpCatalogBytes) {
            throw new Error(`MCP catalog exceeds ${maxMcpCatalogBytes} encoded bytes`)
          }
          this.#resizeCandidate(reservation, encodedBytes)
        }

        const nextCursor = listed.nextCursor
        if (nextCursor === undefined) {
          const encodedBytes = Buffer.byteLength(JSON.stringify(catalog))
          this.#resizeCandidate(reservation, encodedBytes)
          return {
            catalog: Object.freeze(catalog),
            encodedBytes,
            reservation,
            ...catalogOmissionMessage(taskRequiredOmitted, sensitiveNameOmitted)
          }
        }
        if (nextCursor.length === 0 || Buffer.byteLength(nextCursor) > maxMcpCursorBytes) {
          throw new Error(`MCP catalog cursor exceeds ${maxMcpCursorBytes} encoded bytes`)
        }
        if (cursors.has(nextCursor)) throw new Error("MCP server repeated a catalog cursor")
        if (page === maxMcpCatalogPages - 1) {
          throw new Error(`MCP catalog cannot exceed ${maxMcpCatalogPages} pages`)
        }
        cursors.add(nextCursor)
        cursor = nextCursor
      }
      throw new Error(`MCP catalog cannot exceed ${maxMcpCatalogPages} pages`)
    } catch (cause) {
      this.#releaseCandidate(reservation)
      throw cause
    }
  }

  #assertCatalogCapacity(server: string, candidate: CatalogCandidate): void {
    let tools = candidate.catalog.length
    let bytes = candidate.encodedBytes
    for (const state of this.#servers.values()) {
      if (state.type !== "ready" || state.plan.name === server) continue
      tools += state.catalog.length
      bytes += state.catalogBytes
    }
    if (tools > maxMcpTools) throw new Error(`MCP host cannot publish more than ${maxMcpTools} tools`)
    if (bytes > maxMcpCatalogBytes) throw new Error(`MCP host catalog exceeds ${maxMcpCatalogBytes} encoded bytes`)
  }

  #reserveCandidate(server: string, controller: AbortController): CatalogReservation {
    const reservation: CatalogReservation = {
      id: ++this.#nextCandidateReservationId,
      priority: this.#serverPriorities.get(server) ?? this.#serverPriorities.size,
      controller,
      bytes: 0
    }
    this.#candidateReservations.set(reservation.id, reservation)
    return reservation
  }

  #resizeCandidate(reservation: CatalogReservation, nextBytes: number): void {
    if (reservation.rejection) throw reservation.rejection
    this.#candidateBytes += nextBytes - reservation.bytes
    reservation.bytes = nextBytes
    if (this.#candidateBytes <= maxMcpCatalogCandidateBytes) return

    const lowerPriority = [...this.#candidateReservations.values()]
      .filter(candidate => candidate.priority > reservation.priority && candidate.bytes > 0)
      .toSorted((left, right) => right.priority - left.priority || right.id - left.id)
    for (const candidate of lowerPriority) {
      this.#rejectCandidate(candidate)
      if (this.#candidateBytes <= maxMcpCatalogCandidateBytes) return
    }
    this.#rejectCandidate(reservation)
    throw reservation.rejection
  }

  #rejectCandidate(reservation: CatalogReservation): void {
    if (reservation.rejection) return
    reservation.rejection = new Error(`MCP catalog candidates exceed ${maxMcpCatalogCandidateBytes} encoded bytes`)
    this.#candidateBytes -= reservation.bytes
    reservation.bytes = 0
    this.#candidateReservations.delete(reservation.id)
    reservation.controller.abort()
  }

  #releaseCandidate(reservation: CatalogReservation): void {
    if (!this.#candidateReservations.delete(reservation.id)) return
    this.#candidateBytes -= reservation.bytes
    reservation.bytes = 0
  }

  #httpStreamError(name: string, generation: number, evidence: McpHttpStreamEvidence): void {
    const state = this.#servers.get(name)
    if (state?.type === "starting" && state.generation === generation) {
      if (evidence.type !== "transient") state.controller.abort()
      return
    }
    if (state?.type !== "ready" || state.generation !== generation || state.plan.transport !== "streamable-http") {
      return
    }
    const message = serverFailureMessage(evidence.message, state.plan, "SSE recovery: ")
    if (evidence.type !== "transient") {
      void this.#retireHttpGeneration(name, generation, message)
      return
    }
    this.#servers.set(name, { ...state, message })
    this.#emit(name)
  }

  async #retireHttpGeneration(name: string, generation: number, message: string): Promise<void> {
    const state = this.#servers.get(name)
    if (state?.type !== "ready" || state.generation !== generation || state.plan.transport !== "streamable-http") {
      return
    }
    if (state.refresh.type === "refreshing") state.refresh.operation.controller.abort()
    for (const call of this.#calls.values()) {
      if (call.server !== name || call.generation !== generation || call.reason !== "active") continue
      call.reason = "generation_lost"
      call.controller.abort()
    }
    delete state.client.onclose
    delete state.client.onerror
    state.client.removeNotificationHandler("notifications/tools/list_changed")
    const settled = (async (): Promise<void> => {
      if (state.refresh.type === "refreshing") await state.refresh.operation.settled
      await this.#closeConnection(state.client, state.transport)
    })()
    this.#servers.set(name, { type: "stopping", generation, plan: state.plan, settled })
    this.#emit(name)
    await settled
    const current = this.#servers.get(name)
    if (current?.type !== "stopping" || current.generation !== generation) return
    if (this.#state.type === "stopping" || this.#state.type === "stopped") {
      this.#servers.set(name, { type: "stopped", name })
      return
    }
    const stable = Date.now() - state.connectedAt >= maxMcpSseRetryMs
    this.#scheduleHttpBackoff(state.plan, generation, stable ? 1 : state.outageAttempt + 1, message)
  }

  #scheduleHttpBackoff(plan: McpResolvedHttpServer, generation: number, attempt: number, message: string): void {
    if (attempt > maxMcpReconnectAttempts) {
      this.#servers.set(plan.name, {
        type: "failed",
        generation,
        name: plan.name,
        transport: plan.transport,
        required: plan.required,
        plan,
        message
      })
      this.#emit(plan.name)
      return
    }
    const delay = Math.min(maxMcpSseRetryMs, minMcpReconnectDelayMs * 2 ** (attempt - 1))
    const retryAt = Date.now() + delay
    const timer = setTimeout(() => {
      const current = this.#servers.get(plan.name)
      if (current?.type !== "backoff" || current.generation !== generation || current.timer !== timer) return
      void this.#recoverHttp(current)
    }, delay)
    timer.unref?.()
    this.#servers.set(plan.name, { type: "backoff", generation, plan, attempt, retryAt, timer, message })
    this.#emit(plan.name)
  }

  async #recoverHttp(backoff: Extract<ServerState, { readonly type: "backoff" }>): Promise<void> {
    const controller = new AbortController()
    const admission = this.#admitServer(backoff.plan, controller.signal)
    this.#emit(backoff.plan.name)
    const outcome = await this.#connectServer(admission)
    try {
      if (!this.#isCurrentAdmission(admission)) {
        if (outcome.type === "ready") await this.#closeInitialOutcome(outcome)
        return
      }
      if (outcome.type === "failed") {
        this.#scheduleHttpBackoff(backoff.plan, admission.generation, backoff.attempt + 1, outcome.message)
        return
      }
      try {
        this.#assertCatalogCapacity(backoff.plan.name, outcome.candidate)
      } catch (cause) {
        await this.#closeInitialOutcome(outcome)
        if (!this.#isCurrentAdmission(admission)) return
        this.#scheduleHttpBackoff(
          backoff.plan,
          admission.generation,
          backoff.attempt + 1,
          serverFailureMessage(cause, backoff.plan)
        )
        return
      }
      this.#servers.set(backoff.plan.name, {
        type: "ready",
        generation: admission.generation,
        plan: backoff.plan,
        client: outcome.client,
        transport: outcome.transport,
        catalog: outcome.candidate.catalog,
        catalogBytes: outcome.candidate.encodedBytes,
        refresh: { type: "idle" },
        connectedAt: Date.now(),
        outageAttempt: backoff.attempt,
        ...(outcome.candidate.message ? { message: outcome.candidate.message } : {})
      })
      this.#releaseCandidate(outcome.candidate.reservation)
      this.#emit(backoff.plan.name)
    } finally {
      admission.unlink()
      admission.settle()
    }
  }

  async #stopServer(name: string, reason: "server_replaced" | "host_disposed", remove: boolean): Promise<void> {
    const state = this.#servers.get(name)
    if (!state) return
    if (state.type === "backoff") clearTimeout(state.timer)
    if (state.type === "starting") {
      state.controller.abort()
      this.#servers.set(name, {
        type: "stopping",
        generation: state.generation,
        plan: state.plan,
        settled: state.settled
      })
      this.#emit(name)
      await state.settled
    } else if (state.type === "ready") {
      if (state.refresh.type === "refreshing") state.refresh.operation.controller.abort()
      for (const call of this.#calls.values()) {
        if (call.server !== name || call.generation !== state.generation || call.reason !== "active") continue
        call.reason = reason
        call.controller.abort()
      }
      delete state.client.onclose
      delete state.client.onerror
      state.client.removeNotificationHandler("notifications/tools/list_changed")
      const settled = (async (): Promise<void> => {
        if (state.refresh.type === "refreshing") await state.refresh.operation.settled
        await this.#closeConnection(state.client, state.transport)
      })()
      this.#servers.set(name, { type: "stopping", generation: state.generation, plan: state.plan, settled })
      this.#emit(name)
      await settled
    } else if (state.type === "stopping") {
      await state.settled
    }
    if (remove) this.#servers.delete(name)
    else this.#servers.set(name, { type: "stopped", name })
    this.#emit(name)
  }

  #connectionClosed(name: string, generation: number): void {
    const state = this.#servers.get(name)
    if (state?.type === "starting" && state.generation === generation) {
      state.controller.abort()
      return
    }
    if (state?.type !== "ready" || state.generation !== generation) return
    if (state.plan.transport === "streamable-http") {
      void this.#retireHttpGeneration(name, generation, "MCP HTTP connection closed")
      return
    }
    if (state.refresh.type === "refreshing") state.refresh.operation.controller.abort()
    for (const call of this.#calls.values()) {
      if (call.server !== name || call.generation !== generation || call.reason !== "active") continue
      call.reason = "generation_lost"
      call.controller.abort()
    }
    this.#servers.set(name, {
      type: "failed",
      generation,
      name,
      transport: state.plan.transport,
      required: state.plan.required,
      message: "MCP server connection closed"
    })
    this.#emit(name)
  }

  async #stop(): Promise<void> {
    const operation =
      this.#state.type === "starting" || this.#state.type === "reloading"
        ? this.#state.settled.then(() => undefined)
        : Promise.resolve()
    await Promise.allSettled([operation, ...[...this.#calls.values()].map(call => call.settled)])
    await this.#closeServers()
    await this.#waitForRefreshes()
    this.#listeners.clear()
    this.#state = { type: "stopped" }
  }

  async #closeServers(): Promise<void> {
    const closes: Promise<void>[] = []
    for (const [name, state] of this.#servers) {
      if (state.type === "starting") {
        state.controller.abort()
        closes.push(state.settled)
      } else if (state.type === "backoff") {
        clearTimeout(state.timer)
        this.#servers.set(name, { type: "stopped", name })
      } else if (state.type === "stopping") {
        closes.push(state.settled)
      } else if (state.type === "ready") {
        delete state.client.onclose
        delete state.client.onerror
        state.client.removeNotificationHandler("notifications/tools/list_changed")
        const settled = (async (): Promise<void> => {
          if (state.refresh.type === "refreshing") {
            state.refresh.operation.controller.abort()
            await state.refresh.operation.settled
          }
          await this.#closeConnection(state.client, state.transport)
        })()
        this.#servers.set(name, { type: "stopping", generation: state.generation, plan: state.plan, settled })
        closes.push(settled)
      }
    }
    await Promise.allSettled(closes)
    for (const [name, state] of this.#servers) {
      if (
        state.type === "stopping" ||
        state.type === "starting" ||
        state.type === "ready" ||
        state.type === "backoff"
      ) {
        this.#servers.set(name, { type: "stopped", name })
      }
    }
  }

  async #waitForRefreshes(): Promise<void> {
    while (this.#refreshes.size > 0) {
      // A settled refresh may admit its one coalesced rerun.
      // oxlint-disable-next-line no-await-in-loop
      await Promise.allSettled(this.#refreshes)
    }
  }

  #readyServer(name: string): Extract<ServerState, { readonly type: "ready" }> {
    this.#assertAvailable("call")
    const state = this.#servers.get(name)
    if (state?.type !== "ready") throw new Error(`MCP server is unavailable: ${name}`)
    return state
  }

  #canConnect(): boolean {
    return this.#state.type === "starting" || this.#state.type === "running" || this.#state.type === "reloading"
  }

  #assertAvailable(operation: string): void {
    if (this.#state.type === "stopping" || this.#state.type === "stopped") {
      throw new Error(`Cannot ${operation} after MCP host disposal`)
    }
    if (this.#state.type === "constructed") throw new Error(`Cannot ${operation} before MCP host startup`)
  }

  #emit(name: string): void {
    // Subscriptions are projections; observer failures cannot roll back an authoritative transition.
    for (const listener of this.#listeners) {
      try {
        listener(name)
      } catch {
        continue
      }
    }
  }
}

function catalogOmissionMessage(taskRequired: number, sensitiveName: number): { readonly message?: string } {
  if (taskRequired === 0 && sensitiveName === 0) return {}
  if (sensitiveName === 0) {
    return { message: `${taskRequired} task-required MCP tool${taskRequired === 1 ? " was" : "s were"} omitted` }
  }
  const taskText = taskRequired === 0 ? "" : `${taskRequired} task-required and `
  const total = taskRequired + sensitiveName
  return { message: `${taskText}${sensitiveName} sensitive-name MCP tool${total === 1 ? " was" : "s were"} omitted` }
}

function catalogDescriptor(
  plan: McpResolvedStdioServer | McpResolvedHttpServer,
  tool: Tool
): McpToolDescriptor | undefined {
  if (!boundedText(tool.name, maxToolNameBytes)) throw new Error("MCP tool name is invalid")
  if (tool.description !== undefined && Buffer.byteLength(tool.description) > maxDescriptionBytes) {
    throw new Error(`MCP tool description exceeds ${maxDescriptionBytes} bytes`)
  }
  if (tool.execution?.taskSupport === "required") return undefined
  const description = redactServerText(tool.description ?? "", plan)
  if (Buffer.byteLength(description) > maxDescriptionBytes) {
    throw new Error(`MCP tool description exceeds ${maxDescriptionBytes} bytes`)
  }
  const inputSchema = boundedSchema(tool.inputSchema, plan)
  const outputSchema = tool.outputSchema === undefined ? undefined : boundedSchema(tool.outputSchema, plan)
  return Object.freeze({
    server: plan.name,
    name: tool.name,
    description,
    inputSchema,
    ...(outputSchema === undefined ? {} : { outputSchema })
  })
}

function boundedSchema(value: unknown, plan: McpResolvedStdioServer | McpResolvedHttpServer): SessionJson {
  const schema = validateCodeModeJson(value)
  if (Buffer.byteLength(JSON.stringify(schema)) > maxMcpToolSchemaBytes) {
    throw new Error(`MCP tool schema exceeds ${maxMcpToolSchemaBytes} encoded bytes`)
  }
  const redacted = redactServerJson(schema, plan)
  if (Buffer.byteLength(JSON.stringify(redacted)) > maxMcpToolSchemaBytes) {
    throw new Error(`MCP tool schema exceeds ${maxMcpToolSchemaBytes} encoded bytes`)
  }
  return redacted
}

function searchScore(query: string, descriptor: McpToolDescriptor): number | undefined {
  const name = asciiLower(descriptor.name)
  if (name === query) return 0
  if (tokens(name).some(token => token.includes(query))) return 1
  const server = asciiLower(descriptor.server)
  if (server === query || tokens(server).some(token => token.includes(query))) return 2
  const description = asciiLower(descriptor.description)
  if (tokens(description).some(token => token.includes(query)) || description.includes(query)) return 3
  return undefined
}

function tokens(value: string): readonly string[] {
  return value.split(/[^a-z0-9]+/).filter(Boolean)
}

function asciiLower(value: string): string {
  return value.replace(/[A-Z]/g, character => character.toLowerCase())
}

function serverSnapshot(state: ServerState): McpServerSnapshot | undefined {
  switch (state.type) {
    case "disabled":
      return Object.freeze({ name: state.plan.name, status: "disabled" })
    case "starting":
      return Object.freeze({ name: state.plan.name, transport: state.plan.transport, status: "starting" })
    case "ready":
      return Object.freeze({
        name: state.plan.name,
        transport: state.plan.transport,
        status: "ready",
        tools: state.catalog.length,
        ...(state.message ? { message: state.message } : {})
      })
    case "backoff":
      return Object.freeze({
        name: state.plan.name,
        transport: state.plan.transport,
        status: "backoff",
        attempt: state.attempt,
        retryAt: state.retryAt,
        message: clipUtf8(state.message, maxStatusMessageBytes)
      })
    case "failed":
      return Object.freeze({
        name: state.name,
        ...(state.transport ? { transport: state.transport } : {}),
        status: "failed",
        message: clipUtf8(state.message, maxStatusMessageBytes)
      })
    case "stopping":
      return Object.freeze({ name: state.plan.name, transport: state.plan.transport, status: "stopping" })
    case "stopped":
      return undefined
    default:
      return assertNever(state)
  }
}

function progressText(
  progress: { readonly progress: number; readonly total?: number | undefined; readonly message?: string | undefined },
  plan: McpResolvedStdioServer | McpResolvedHttpServer
): string {
  const text =
    progress.message ?? `Progress ${progress.progress}${progress.total === undefined ? "" : `/${progress.total}`}`
  return clipUtf8(redactServerText(text, plan), maxProgressBytes)
}

function projectCallValue(result: CallToolResult, plan: McpResolvedStdioServer | McpResolvedHttpServer): McpCallValue {
  const structuredContent =
    result.structuredContent === undefined
      ? undefined
      : redactServerJson(validateCodeModeJson(result.structuredContent), plan)
  const content: McpCallContent[] = []
  if (callValueBytes(content, structuredContent) > maxMcpCallValueBytes) {
    throw new Error(`MCP structured result exceeds ${maxMcpCallValueBytes} encoded bytes`)
  }

  for (const block of result.content.slice(0, maxCallContentBlocks)) {
    if (block.type === "text") {
      const text = redactServerText(block.text, plan)
      const complete = Object.freeze({ type: "text" as const, text })
      if (callValueBytes([...content, complete], structuredContent) <= maxMcpCallValueBytes) {
        content.push(complete)
        continue
      }
      const clipped = fittingTextBlock(text, content, structuredContent)
      if (clipped) content.push(clipped)
      break
    }

    const placeholder = omittedBlock(block, plan)
    if (callValueBytes([...content, placeholder], structuredContent) <= maxMcpCallValueBytes) {
      content.push(placeholder)
      continue
    }
    const remainder = Object.freeze({ type: "omitted" as const, contentType: "additional_blocks" })
    if (callValueBytes([...content, remainder], structuredContent) <= maxMcpCallValueBytes) content.push(remainder)
    break
  }

  if (result.content.length > maxCallContentBlocks) {
    const remainder = Object.freeze({ type: "omitted" as const, contentType: "additional_blocks" })
    if (callValueBytes([...content, remainder], structuredContent) <= maxMcpCallValueBytes) content.push(remainder)
  }

  return Object.freeze({
    content: Object.freeze(content),
    ...(structuredContent === undefined ? {} : { structuredContent })
  })
}

function fittingTextBlock(
  text: string,
  existing: readonly McpCallContent[],
  structuredContent: CodeModeJson | undefined
): Extract<McpCallContent, { readonly type: "text" }> | undefined {
  const totalBytes = Buffer.byteLength(text)
  let low = 0
  let high = totalBytes
  let best: Extract<McpCallContent, { readonly type: "text" }> | undefined
  while (low <= high) {
    const requested = Math.floor((low + high) / 2)
    const prefix = clipUtf8(text, requested)
    const omitted = totalBytes - Buffer.byteLength(prefix)
    const candidate = Object.freeze({ type: "text" as const, text: `${prefix}\n[${omitted} bytes omitted]` })
    if (callValueBytes([...existing, candidate], structuredContent) <= maxMcpCallValueBytes) {
      best = candidate
      low = requested + 1
    } else {
      high = requested - 1
    }
  }
  return best
}

function callValueBytes(content: readonly McpCallContent[], structuredContent: CodeModeJson | undefined): number {
  return Buffer.byteLength(
    JSON.stringify({ content, ...(structuredContent === undefined ? {} : { structuredContent }) })
  )
}

async function settleMcpClose(operation: Promise<unknown>): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined
  await Promise.race([
    operation.then(
      () => undefined,
      () => undefined
    ),
    new Promise<void>(resolve => {
      timer = setTimeout(resolve, maxMcpConnectionCloseMs)
      timer.unref?.()
    })
  ])
  if (timer) clearTimeout(timer)
}

function omittedBlock(
  block: CallToolResult["content"][number],
  plan: McpResolvedStdioServer | McpResolvedHttpServer
): McpCallContent {
  const mimeType =
    "mimeType" in block && typeof block.mimeType === "string" ? redactServerText(block.mimeType, plan) : undefined
  return Object.freeze({ type: "omitted", contentType: block.type, ...(mimeType ? { mimeType } : {}) })
}

function serverErrorText(result: CallToolResult): string {
  const text = result.content
    .filter(
      (block): block is Extract<CallToolResult["content"][number], { readonly type: "text" }> => block.type === "text"
    )
    .map(block => block.text)
    .join("\n")
  return clipUtf8(text || "Server reported an error", maxStatusMessageBytes)
}

function callError(reason: Exclude<CallReason, "active">): Error {
  const message =
    reason === "caller_cancelled"
      ? "MCP tool call was cancelled"
      : reason === "deadline_exceeded"
        ? "MCP tool call deadline exceeded"
        : reason === "generation_lost"
          ? "MCP server connection was lost during the tool call"
          : reason === "server_replaced"
            ? "MCP server was replaced during the tool call"
            : "MCP host was disposed during the tool call"
  return new Error(message)
}

function serverFailureMessage(
  cause: unknown,
  plan: McpResolvedStdioServer | McpResolvedHttpServer,
  prefix = ""
): string {
  return clipUtf8(
    redactServerText(`${prefix}${cause instanceof Error ? cause.message : String(cause)}`, plan),
    maxStatusMessageBytes
  )
}

function redactServerText(value: string, plan: McpResolvedStdioServer | McpResolvedHttpServer): string {
  return redactText(value, serverSecretValues(plan))
}

function redactServerJson(value: SessionJson, plan: McpResolvedStdioServer | McpResolvedHttpServer): SessionJson {
  return redactJsonValue(value, serverSecretValues(plan))
}

function redactJsonValue(value: SessionJson, secrets: readonly string[]): SessionJson {
  if (typeof value === "string") return redactText(value, secrets)
  if (value === null || typeof value === "boolean" || typeof value === "number") return value
  if (Array.isArray(value)) return Object.freeze(value.map(item => redactJsonValue(item, secrets)))
  return Object.freeze(
    Object.fromEntries(
      Object.entries(value).map(([key, item]) => [redactText(key, secrets), redactJsonValue(item, secrets)])
    )
  )
}

function redactText(value: string, secrets: readonly string[]): string {
  let redacted = value
  for (const secret of secrets) redacted = redacted.replaceAll(secret, "[redacted]")
  return redacted
}

function serverSecretValues(plan: McpResolvedStdioServer | McpResolvedHttpServer): readonly string[] {
  return plan.redactionValues
}

function isTerminalHttpFailure(cause: unknown): boolean {
  if (cause instanceof McpHttpTransportError) return true
  if (cause instanceof SdkHttpError) {
    return (
      cause.status === 404 ||
      cause.status === 408 ||
      cause.status === 409 ||
      cause.status === 410 ||
      cause.status >= 500
    )
  }
  return (
    cause instanceof SdkError &&
    (cause.code === SdkErrorCode.ConnectionClosed ||
      cause.code === SdkErrorCode.SendFailed ||
      cause.code === SdkErrorCode.ClientHttpFailedToOpenStream)
  )
}

function resolvedServerPlan(state: ServerState): McpResolvedServer | undefined {
  switch (state.type) {
    case "disabled":
    case "starting":
    case "ready":
    case "backoff":
    case "stopping":
      return state.plan
    case "failed":
      return state.plan
    case "stopped":
      return undefined
    default:
      return assertNever(state)
  }
}

function sameResolvedServer(left: McpResolvedServer, right: McpResolvedServer): boolean {
  if (left.enabled !== right.enabled || left.name !== right.name) return false
  if (!left.enabled || !right.enabled) return true
  if (
    left.transport !== right.transport ||
    left.required !== right.required ||
    left.startupTimeoutMs !== right.startupTimeoutMs ||
    left.toolTimeoutMs !== right.toolTimeoutMs
  ) {
    return false
  }
  if (left.transport === "stdio" && right.transport === "stdio") {
    return (
      left.cwd === right.cwd &&
      sameStrings(left.command, right.command) &&
      sameRecord(left.environment, right.environment) &&
      sameStrings(left.redactionValues, right.redactionValues)
    )
  }
  if (left.transport === "streamable-http" && right.transport === "streamable-http") {
    return (
      left.url === right.url &&
      sameRecord(left.headers, right.headers) &&
      sameStrings(left.redactionValues, right.redactionValues)
    )
  }
  return false
}

function sameStrings(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function sameRecord(left: Readonly<Record<string, string>>, right: Readonly<Record<string, string>>): boolean {
  const leftKeys = Object.keys(left).toSorted(compareMcpIdentity)
  const rightKeys = Object.keys(right).toSorted(compareMcpIdentity)
  return sameStrings(leftKeys, rightKeys) && leftKeys.every(key => left[key] === right[key])
}

function boundedText(value: string, maximum: number): boolean {
  return value.trim().length > 0 && !value.includes("\0") && Buffer.byteLength(value) <= maximum
}

function clipUtf8(value: string, maximum: number): string {
  if (Buffer.byteLength(value) <= maximum) return value
  return Buffer.from(value)
    .subarray(0, maximum)
    .toString("utf8")
    .replace(/\uFFFD$/u, "")
}

function assertNever(value: never): never {
  throw new Error(`Unknown MCP state: ${String(value)}`)
}

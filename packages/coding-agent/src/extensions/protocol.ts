import { isAbsolute } from "node:path"

import type {
  ExtensionAgentSettledEvent,
  ExtensionAgentSnapshot,
  ExtensionAgentStartEvent,
  ExtensionAgentType,
  ExtensionContext,
  ExtensionCustomEntry,
  ExtensionCustomMessage,
  ExtensionMessageDelivery,
  ExtensionMode,
  ExtensionSession,
  ExtensionShutdownReason,
  ExtensionStartReason,
  ExtensionThinkingLevel
} from "@with-zi/extension-api"

import { isRecord } from "../guards.js"
import type { FramedJsonLimits } from "../processes/framed-json.js"
import {
  maxCustomJsonBytes,
  maxCustomStateEntries,
  validateCustomMessageInput,
  validateCustomType
} from "../session-manager.js"
import {
  maxExtensionPathBytes,
  maxExtensionSources,
  type ExtensionLoadPlan,
  type ExtensionSource
} from "./discovery.js"

export const extensionProtocolVersion = 13
export const maxExtensionProtocolFrameBytes = 4 * 1024 * 1024
export const maxExtensionPendingRequests = 128
export const maxExtensionQueuedWriteBytes = 8 * 1024 * 1024
export const maxExtensionQueuedWrites = 1024
export const extensionFramingLimits: FramedJsonLimits = Object.freeze({
  maxFrameBytes: maxExtensionProtocolFrameBytes,
  maxQueuedFrames: maxExtensionQueuedWrites,
  maxQueuedBytes: maxExtensionQueuedWriteBytes
})
export const extensionFramingLabel = "Extension protocol"
export const maxExtensionDiagnostics = 256
export const maxExtensionDiagnosticMessageBytes = 16 * 1024
export const maxExtensionDiagnosticStackBytes = 64 * 1024
export const maxExtensionLoadDiagnosticMessageBytes = 2 * 1024
export const maxExtensionIdBytes = 256
export const maxExtensionLogBytesPerStream = 256 * 1024
export const extensionStartupTimeoutMs = 30_000
export const extensionLifecycleTimeoutMs = 10_000
export const extensionAgentEventTimeoutMs = 1_000
export const maxExtensionQueuedAgentEvents = 32
export const extensionShutdownTimeoutMs = 3_000
export const extensionCommandTimeoutMs = 30_000
export const extensionCommandCancellationTimeoutMs = 1_000
export const maxExtensionCommands = 128
export const maxExtensionCommandCatalogBytes = 512 * 1024
export const maxExtensionCommandNameBytes = 64
export const maxExtensionCommandDescriptionBytes = 4 * 1024
export const maxExtensionCommandArgumentHintBytes = 1024
export const maxExtensionCommandArgumentsBytes = 256 * 1024
export const maxExtensionCommandResultBytes = 16 * 1024
export const extensionToolTimeoutMs = 30_000
export const maxExtensionToolTimeoutMs = 60 * 60 * 1000
export const extensionToolCancellationTimeoutMs = 1_000
export const maxExtensionTools = 256
export const maxExtensionToolCatalogBytes = 2 * 1024 * 1024
export const maxActiveExtensionTools = 64
export const maxActiveExtensionToolCatalogBytes = 512 * 1024
export const maxExtensionToolNameBytes = 64
export const maxExtensionToolLabelBytes = 256
export const maxExtensionToolDescriptionBytes = 4 * 1024
export const maxExtensionToolSchemaBytes = 16 * 1024
export const maxExtensionToolArgumentsBytes = 256 * 1024
export const maxExtensionToolProgressBytes = 16 * 1024
export const maxExtensionToolResultBytes = 256 * 1024
export const maxExtensionAgentTaskNameBytes = 64
export const maxExtensionAgentModelBytes = 4 * 1024
export const maxExtensionAgentMessageBytes = 8 * 1024 * 1024
export const maxExtensionAgentWaitMs = maxExtensionToolTimeoutMs
export const maxExtensionJsonDepth = 32
export const maxExtensionJsonNodes = 4096
export const maxExtensionJsonKeyBytes = 4 * 1024

export type { ExtensionShutdownReason, ExtensionStartReason } from "@with-zi/extension-api"

export interface ExtensionDiagnostic {
  readonly extensionId?: string
  readonly path?: string
  readonly phase:
    | "discovery"
    | "trust"
    | "spawn"
    | "handshake"
    | "resolve"
    | "import"
    | "factory"
    | "registration"
    | "lifecycle"
    | "event"
    | "command"
    | "tool"
    | "protocol"
    | "shutdown"
  readonly severity: "warning" | "error"
  readonly message: string
  readonly stack?: string
}

export interface ExtensionLoadResult {
  readonly source: ExtensionSource
  readonly status: "loaded" | "failed"
  readonly diagnostic?: ExtensionDiagnostic
}

export type HostMessage =
  | {
      readonly type: "initialize"
      readonly protocolVersion: 13
      readonly generation: number
      readonly plan: ExtensionLoadPlan
      readonly agentsAvailable?: boolean
    }
  | {
      readonly type: "session_start"
      readonly generation: number
      readonly requestId: number
      readonly reason: ExtensionStartReason
      readonly context: ExtensionContext
    }
  | {
      readonly type: "session_shutdown"
      readonly generation: number
      readonly requestId: number
      readonly reason: ExtensionShutdownReason
    }
  | { readonly type: ExtensionAgentStartEvent["type"]; readonly generation: number; readonly sequence: number }
  | { readonly type: ExtensionAgentSettledEvent["type"]; readonly generation: number; readonly sequence: number }
  | {
      readonly type: "command_invoke"
      readonly generation: number
      readonly requestId: number
      readonly name: string
      readonly arguments: string
    }
  | {
      readonly type: "tool_invoke"
      readonly generation: number
      readonly requestId: number
      readonly name: string
      readonly arguments: Readonly<Record<string, JsonValue>>
    }
  | { readonly type: "stop"; readonly generation: number; readonly requestId: number }
  | { readonly type: "cancel"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "custom_entries_result"
      readonly generation: number
      readonly requestId: number
      readonly entries: readonly ExtensionCustomEntry[]
    }
  | {
      readonly type: "custom_entry_result"
      readonly generation: number
      readonly requestId: number
      readonly entry: ExtensionCustomEntry
    }
  | { readonly type: "custom_message_result"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "active_tools_result"
      readonly generation: number
      readonly requestId: number
      readonly names: readonly string[]
    }
  | {
      readonly type: "agent_spawn_result"
      readonly generation: number
      readonly requestId: number
      readonly path: string
    }
  | { readonly type: "agent_send_result"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "agent_followup_result"
      readonly generation: number
      readonly requestId: number
      readonly delivery: "started" | "joined"
    }
  | {
      readonly type: "agent_wait_result"
      readonly generation: number
      readonly requestId: number
      readonly message: string
      readonly timedOut: boolean
      readonly snapshots: readonly ExtensionAgentSnapshot[]
    }
  | {
      readonly type: "agent_interrupt_result"
      readonly generation: number
      readonly requestId: number
      readonly result: "interrupted" | "idle"
    }
  | {
      readonly type: "agent_list_result"
      readonly generation: number
      readonly requestId: number
      readonly snapshots: readonly ExtensionAgentSnapshot[]
    }
  | {
      readonly type: "session_operation_error"
      readonly generation: number
      readonly requestId: number
      readonly message: string
    }

export type WorkerMessage =
  | {
      readonly type: "ready"
      readonly protocolVersion: 13
      readonly generation: number
      readonly extensions: readonly ExtensionLoadResult[]
      readonly commands: readonly ExtensionCommandRegistration[]
      readonly tools: readonly ExtensionToolRegistration[]
    }
  | { readonly type: "settled"; readonly generation: number; readonly requestId: number }
  | { readonly type: "agent_event_settled"; readonly generation: number; readonly sequence: number }
  | {
      readonly type: "command_result"
      readonly generation: number
      readonly requestId: number
      readonly message?: string
    }
  | {
      readonly type: "command_error"
      readonly generation: number
      readonly requestId: number
      readonly message: string
    }
  | { readonly type: "command_cancelled"; readonly generation: number; readonly requestId: number }
  | { readonly type: "tool_result"; readonly generation: number; readonly requestId: number; readonly value: JsonValue }
  | {
      readonly type: "tool_progress"
      readonly generation: number
      readonly requestId: number
      readonly message: string
    }
  | { readonly type: "tool_error"; readonly generation: number; readonly requestId: number; readonly message: string }
  | { readonly type: "tool_cancelled"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "custom_entries_get"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly customType: string
    }
  | {
      readonly type: "custom_entry_append"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly customType: string
      readonly data?: JsonValue
    }
  | {
      readonly type: "custom_message_send"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly message: ExtensionCustomMessage
      readonly delivery: ExtensionMessageDelivery
    }
  | {
      readonly type: "active_tools_get"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
    }
  | {
      readonly type: "active_tools_set"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly names: readonly string[]
    }
  | {
      readonly type: "agent_spawn"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly taskName: string
      readonly message: string
      readonly agentType?: ExtensionAgentType
      readonly forkTurns?: "all" | "none" | number
      readonly model?: string
      readonly thinking?: ExtensionThinkingLevel
    }
  | {
      readonly type: "agent_send"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly target: string
      readonly message: string
    }
  | {
      readonly type: "agent_followup"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly target: string
      readonly message: string
    }
  | {
      readonly type: "agent_wait"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly ownerRequestId?: number
      readonly timeoutMs?: number
    }
  | {
      readonly type: "agent_interrupt"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly target: string
    }
  | {
      readonly type: "agent_list"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly pathPrefix?: string
    }
  | {
      readonly type: "agent_operation_cancel"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly targetRequestId: number
    }
  | { readonly type: "diagnostic"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }
  | { readonly type: "fatal"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }

export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue }

export type ExtensionSessionRequest = Exclude<
  Extract<WorkerMessage, { readonly requestId: number; readonly extensionId: string }>,
  { readonly type: "agent_operation_cancel" }
>
export type ExtensionSessionResponse = Extract<
  HostMessage,
  { readonly requestId: number; readonly type: `${string}_result` | "session_operation_error" }
>

export interface ExtensionCommandRegistration {
  readonly source: ExtensionSource
  readonly name: string
  readonly description: string
  readonly argumentHint?: string
}

export interface ExtensionToolRegistration {
  readonly source: ExtensionSource
  readonly name: string
  readonly label: string
  readonly description: string
  readonly active: boolean
  readonly timeoutMs?: number
  readonly parameters: Readonly<Record<string, JsonValue>>
  readonly outputSchema: Readonly<Record<string, JsonValue>>
}

export class ExtensionProtocolError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "ExtensionProtocolError"
  }
}

export function validateHostMessage(value: unknown): HostMessage {
  const message = protocolRecord(value)
  switch (message.type) {
    case "initialize":
      return Object.freeze({
        type: "initialize",
        protocolVersion: protocolVersion(message.protocolVersion),
        generation: positiveInteger(message.generation, "generation"),
        plan: extensionLoadPlan(message.plan),
        ...(message.agentsAvailable === undefined
          ? {}
          : { agentsAvailable: requiredBoolean(message.agentsAvailable, "agentsAvailable") })
      })
    case "session_start":
      return Object.freeze({
        type: "session_start",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        reason: startReason(message.reason),
        context: extensionContext(message.context)
      })
    case "session_shutdown":
      return Object.freeze({
        type: "session_shutdown",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        reason: shutdownReason(message.reason)
      })
    case "agent_start":
    case "agent_settled":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        sequence: positiveInteger(message.sequence, "agent event sequence")
      })
    case "command_invoke":
      return Object.freeze({
        type: "command_invoke",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        name: commandName(message.name),
        arguments: boundedTextValue(message.arguments, "command arguments", maxExtensionCommandArgumentsBytes)
      })
    case "tool_invoke":
      return Object.freeze({
        type: "tool_invoke",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        name: toolName(message.name),
        arguments: jsonRecord(message.arguments, "tool arguments", maxExtensionToolArgumentsBytes)
      })
    case "stop":
    case "cancel":
    case "custom_message_result":
    case "agent_send_result":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId")
      })
    case "custom_entries_result": {
      const entries = protocolArray(message.entries, "custom entries")
      if (entries.length > maxCustomStateEntries) {
        throw new ExtensionProtocolError(`Custom entries cannot exceed ${maxCustomStateEntries}`)
      }
      return Object.freeze({
        type: "custom_entries_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        entries: Object.freeze(entries.map(extensionCustomEntry))
      })
    }
    case "custom_entry_result":
      return Object.freeze({
        type: "custom_entry_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        entry: extensionCustomEntry(message.entry)
      })
    case "active_tools_result":
      return Object.freeze({
        type: "active_tools_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        names: activeToolNames(message.names)
      })
    case "agent_spawn_result":
      return Object.freeze({
        type: "agent_spawn_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        path: agentPath(message.path)
      })
    case "agent_followup_result":
      return Object.freeze({
        type: "agent_followup_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        delivery: agentDelivery(message.delivery)
      })
    case "agent_wait_result":
      return Object.freeze({
        type: "agent_wait_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "agent wait message", maxExtensionDiagnosticMessageBytes),
        timedOut: requiredBoolean(message.timedOut, "agent wait timedOut"),
        snapshots: extensionAgentSnapshots(message.snapshots)
      })
    case "agent_list_result":
      return Object.freeze({
        type: "agent_list_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        snapshots: extensionAgentSnapshots(message.snapshots)
      })
    case "agent_interrupt_result":
      return Object.freeze({
        type: "agent_interrupt_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        result: agentInterruptResult(message.result)
      })
    case "session_operation_error":
      return Object.freeze({
        type: "session_operation_error",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "session operation error", maxExtensionDiagnosticMessageBytes)
      })
    default:
      throw new ExtensionProtocolError("Unknown host protocol message")
  }
}

export function validateWorkerMessage(value: unknown): WorkerMessage {
  const message = protocolRecord(value)
  switch (message.type) {
    case "ready": {
      const extensions = protocolArray(message.extensions, "extensions")
      if (extensions.length > maxExtensionSources) {
        throw new ExtensionProtocolError(`Extension results cannot exceed ${maxExtensionSources}`)
      }
      const admittedCommands = validateExtensionCommandCatalog(message.commands)
      const admittedTools = validateExtensionToolCatalog(message.tools)
      const admitted = Object.freeze({
        type: "ready" as const,
        protocolVersion: protocolVersion(message.protocolVersion),
        generation: positiveInteger(message.generation, "generation"),
        extensions: Object.freeze(extensions.map(extensionLoadResult)),
        commands: admittedCommands,
        tools: Object.freeze(admittedTools)
      })
      if (Buffer.byteLength(JSON.stringify(admitted)) > maxExtensionProtocolFrameBytes) {
        throw new ExtensionProtocolError(`Extension ready frame cannot exceed ${maxExtensionProtocolFrameBytes} bytes`)
      }
      return admitted
    }
    case "agent_event_settled":
      return Object.freeze({
        type: "agent_event_settled",
        generation: positiveInteger(message.generation, "generation"),
        sequence: positiveInteger(message.sequence, "agent event sequence")
      })
    case "settled":
    case "command_cancelled":
    case "tool_cancelled":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId")
      })
    case "command_result":
      return Object.freeze({
        type: "command_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        ...(message.message === undefined
          ? {}
          : { message: boundedTextValue(message.message, "command result", maxExtensionCommandResultBytes) })
      })
    case "command_error":
      return Object.freeze({
        type: "command_error",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "command error", maxExtensionDiagnosticMessageBytes)
      })
    case "tool_result":
      return Object.freeze({
        type: "tool_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        value: jsonValue(message.value, "tool result", maxExtensionToolResultBytes)
      })
    case "tool_progress":
      return Object.freeze({
        type: "tool_progress",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "tool progress", maxExtensionToolProgressBytes)
      })
    case "tool_error":
      return Object.freeze({
        type: "tool_error",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        message: boundedRequiredText(message.message, "tool error", maxExtensionDiagnosticMessageBytes)
      })
    case "custom_entries_get":
      return Object.freeze({
        type: "custom_entries_get",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        customType: customType(message.customType)
      })
    case "custom_entry_append":
      return Object.freeze({
        type: "custom_entry_append",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        customType: customType(message.customType),
        ...(message.data === undefined
          ? {}
          : { data: jsonValue(message.data, "custom entry data", maxCustomJsonBytes) })
      })
    case "custom_message_send":
      return Object.freeze({
        type: "custom_message_send",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        message: extensionCustomMessage(message.message),
        delivery: extensionMessageDelivery(message.delivery)
      })
    case "active_tools_get":
      return Object.freeze({
        type: "active_tools_get",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes)
      })
    case "active_tools_set":
      return Object.freeze({
        type: "active_tools_set",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        names: activeToolNames(message.names)
      })
    case "agent_list":
      return Object.freeze({
        type: "agent_list",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        ...(message.pathPrefix === undefined ? {} : { pathPrefix: agentPath(message.pathPrefix) })
      })
    case "agent_spawn":
      return Object.freeze({
        type: "agent_spawn",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        taskName: agentTaskName(message.taskName),
        message: boundedRequiredText(message.message, "agent message", maxExtensionAgentMessageBytes),
        ...(message.agentType === undefined ? {} : { agentType: agentType(message.agentType) }),
        ...(message.forkTurns === undefined ? {} : { forkTurns: agentForkTurns(message.forkTurns) }),
        ...(message.model === undefined
          ? {}
          : { model: boundedRequiredText(message.model, "agent model", maxExtensionAgentModelBytes) }),
        ...(message.thinking === undefined ? {} : { thinking: thinkingLevel(message.thinking) })
      })
    case "agent_send":
    case "agent_followup":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        target: agentPath(message.target),
        message: boundedRequiredText(message.message, "agent message", maxExtensionAgentMessageBytes)
      })
    case "agent_wait":
      return Object.freeze({
        type: "agent_wait",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        ...(message.ownerRequestId === undefined
          ? {}
          : { ownerRequestId: positiveInteger(message.ownerRequestId, "owner request id") }),
        ...(message.timeoutMs === undefined ? {} : { timeoutMs: agentWaitTimeout(message.timeoutMs) })
      })
    case "agent_interrupt":
      return Object.freeze({
        type: "agent_interrupt",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        target: agentPath(message.target)
      })
    case "agent_operation_cancel":
      return Object.freeze({
        type: "agent_operation_cancel",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        targetRequestId: positiveInteger(message.targetRequestId, "targetRequestId")
      })
    case "diagnostic":
    case "fatal":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        diagnostic: extensionDiagnostic(message.diagnostic)
      })
    default:
      throw new ExtensionProtocolError("Unknown worker protocol message")
  }
}

export function validateExtensionCommandRegistration(value: unknown): ExtensionCommandRegistration {
  return extensionCommandRegistration(value)
}

export function validateExtensionCommandCatalog(value: unknown): readonly ExtensionCommandRegistration[] {
  const commands = protocolArray(value, "commands")
  if (commands.length > maxExtensionCommands) {
    throw new ExtensionProtocolError(`Extension commands cannot exceed ${maxExtensionCommands}`)
  }
  const admitted = commands.map(extensionCommandRegistration)
  const names = new Set<string>()
  for (const command of admitted) {
    if (names.has(command.name)) {
      throw new ExtensionProtocolError(`Extension command names must be unique: ${command.name}`)
    }
    names.add(command.name)
  }
  if (Buffer.byteLength(JSON.stringify(admitted)) > maxExtensionCommandCatalogBytes) {
    throw new ExtensionProtocolError(`Extension command catalog cannot exceed ${maxExtensionCommandCatalogBytes} bytes`)
  }
  return Object.freeze(admitted)
}

export function validateExtensionToolRegistration(value: unknown): ExtensionToolRegistration {
  return extensionToolRegistration(value)
}

export function validateExtensionToolCatalog(value: unknown): readonly ExtensionToolRegistration[] {
  const tools = protocolArray(value, "tools")
  if (tools.length > maxExtensionTools) {
    throw new ExtensionProtocolError(`Extension tools cannot exceed ${maxExtensionTools}`)
  }
  const admitted = tools.map(extensionToolRegistration)
  const names = new Set<string>()
  for (const tool of admitted) {
    if (names.has(tool.name)) throw new ExtensionProtocolError(`Extension tool names must be unique: ${tool.name}`)
    names.add(tool.name)
  }
  if (Buffer.byteLength(JSON.stringify(admitted)) > maxExtensionToolCatalogBytes) {
    throw new ExtensionProtocolError(`Extension tool catalog cannot exceed ${maxExtensionToolCatalogBytes} bytes`)
  }
  validateActiveExtensionToolCatalog(admitted.filter(tool => tool.active))
  return Object.freeze(admitted)
}

export function validateActiveExtensionToolCatalog(tools: readonly ExtensionToolRegistration[]): void {
  if (tools.length > maxActiveExtensionTools) {
    throw new ExtensionProtocolError(`Active extension tools cannot exceed ${maxActiveExtensionTools}`)
  }
  const providerCatalog = tools.map(tool => ({
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters
  }))
  if (Buffer.byteLength(JSON.stringify(providerCatalog)) > maxActiveExtensionToolCatalogBytes) {
    throw new ExtensionProtocolError(
      `Active extension tool catalog cannot exceed ${maxActiveExtensionToolCatalogBytes} bytes`
    )
  }
}

export function validateExtensionCommandArguments(value: unknown): string {
  return boundedTextValue(value, "command arguments", maxExtensionCommandArgumentsBytes)
}

export function validateExtensionCommandResult(value: unknown): string | undefined {
  if (value === undefined) return undefined
  return boundedTextValue(value, "command result", maxExtensionCommandResultBytes)
}

export function validateExtensionToolArguments(value: unknown): Readonly<Record<string, JsonValue>> {
  return jsonRecord(value, "tool arguments", maxExtensionToolArgumentsBytes)
}

export function validateExtensionToolResult(value: unknown): JsonValue {
  return jsonValue(value, "tool result", maxExtensionToolResultBytes)
}

export function boundedExtensionCommandError(cause: unknown): string {
  return boundedOperationError(cause, "Extension command failed")
}

export function boundedExtensionToolError(cause: unknown): string {
  return boundedOperationError(cause, "Extension tool failed")
}

export function boundedExtensionSessionOperationError(cause: unknown): string {
  return boundedOperationError(cause, "Extension session operation failed")
}

function boundedOperationError(cause: unknown, fallback: string): string {
  try {
    const error = cause instanceof Error ? cause : new Error(String(cause))
    return boundedText(error.message || error.name || fallback, maxExtensionDiagnosticMessageBytes)
  } catch {
    return fallback
  }
}

export function boundedExtensionDiagnostic(diagnostic: ExtensionDiagnostic): ExtensionDiagnostic {
  return extensionDiagnostic({
    ...(diagnostic.extensionId === undefined
      ? {}
      : { extensionId: boundedText(diagnostic.extensionId, maxExtensionIdBytes) }),
    ...(diagnostic.path === undefined ? {} : { path: boundedText(diagnostic.path, maxExtensionPathBytes) }),
    phase: diagnostic.phase,
    severity: diagnostic.severity,
    message: boundedText(diagnostic.message, maxExtensionDiagnosticMessageBytes),
    ...(diagnostic.stack === undefined
      ? {}
      : { stack: boundedText(diagnostic.stack, maxExtensionDiagnosticStackBytes) })
  })
}

export function boundedExtensionLoadDiagnostic(diagnostic: ExtensionDiagnostic): ExtensionDiagnostic {
  return extensionDiagnostic({
    ...(diagnostic.extensionId === undefined
      ? {}
      : { extensionId: boundedText(diagnostic.extensionId, maxExtensionIdBytes) }),
    ...(diagnostic.path === undefined ? {} : { path: boundedText(diagnostic.path, maxExtensionPathBytes) }),
    phase: diagnostic.phase,
    severity: diagnostic.severity,
    message: boundedText(diagnostic.message, maxExtensionLoadDiagnosticMessageBytes)
  })
}

function extensionLoadPlan(value: unknown): ExtensionLoadPlan {
  const plan = protocolRecord(value)
  const cwd = pathText(plan.cwd, "plan cwd")
  if (!isAbsolute(cwd)) throw new ExtensionProtocolError("Extension plan cwd must be absolute")
  const sources = protocolArray(plan.sources, "sources")
  if (sources.length > maxExtensionSources) {
    throw new ExtensionProtocolError(`Extension sources cannot exceed ${maxExtensionSources}`)
  }
  return Object.freeze({ cwd, sources: Object.freeze(sources.map(extensionSource)) })
}

function extensionSource(value: unknown): ExtensionSource {
  const source = protocolRecord(value)
  const declaredPath = pathText(source.declaredPath, "declaredPath")
  const entryPath = pathText(source.entryPath, "entryPath")
  if (!isAbsolute(declaredPath) || !isAbsolute(entryPath)) {
    throw new ExtensionProtocolError("Extension source paths must be absolute")
  }
  const id = boundedRequiredText(source.id, "extension id", maxExtensionIdBytes)
  const scope = source.scope
  if (scope !== "global" && scope !== "project" && scope !== "temporary") {
    throw new ExtensionProtocolError("Unknown extension scope")
  }
  const origin = source.origin
  if (origin !== "directory" && origin !== "settings" && origin !== "package" && origin !== "cli") {
    throw new ExtensionProtocolError("Unknown extension origin")
  }
  return Object.freeze({ id, declaredPath, entryPath, scope, origin })
}

function extensionLoadResult(value: unknown): ExtensionLoadResult {
  const result = protocolRecord(value)
  const source = extensionSource(result.source)
  if (result.status === "loaded") {
    if (result.diagnostic !== undefined) {
      throw new ExtensionProtocolError("Loaded extensions cannot include a failure diagnostic")
    }
    return Object.freeze({ source, status: "loaded" })
  }
  if (result.status === "failed") {
    if (result.diagnostic === undefined) {
      throw new ExtensionProtocolError("Failed extensions require a diagnostic")
    }
    return Object.freeze({ source, status: "failed", diagnostic: extensionDiagnostic(result.diagnostic) })
  }
  throw new ExtensionProtocolError("Unknown extension load status")
}

function extensionAgentSnapshots(value: unknown): readonly ExtensionAgentSnapshot[] {
  const snapshots = protocolArray(value, "agent snapshots")
  if (snapshots.length > 32) throw new ExtensionProtocolError("Agent snapshots cannot exceed 32")
  return Object.freeze(snapshots.map(extensionAgentSnapshot))
}

function extensionAgentSnapshot(value: unknown): ExtensionAgentSnapshot {
  const snapshot = protocolRecord(value)
  const residency = snapshot.residency
  if (residency !== "unloaded" && residency !== "loading" && residency !== "resident") {
    throw new ExtensionProtocolError("Unknown agent residency")
  }
  const turn = snapshot.turn
  if (turn !== "idle" && turn !== "starting" && turn !== "running" && turn !== "interrupting") {
    throw new ExtensionProtocolError("Unknown agent turn state")
  }
  const status = snapshot.status
  if (status !== "not_started" && status !== "completed" && status !== "interrupted" && status !== "failed") {
    throw new ExtensionProtocolError("Unknown agent status")
  }
  return Object.freeze({
    path: agentPath(snapshot.path),
    parentPath: agentPath(snapshot.parentPath),
    taskName: agentTaskName(snapshot.taskName),
    agentType: agentType(snapshot.agentType),
    ...(snapshot.sessionId === undefined
      ? {}
      : { sessionId: boundedRequiredText(snapshot.sessionId, "agent session id", maxExtensionIdBytes) }),
    residency,
    turn,
    turnNumber: nonNegativeInteger(snapshot.turnNumber, "agent turn number"),
    status
  })
}

function extensionCommandRegistration(value: unknown): ExtensionCommandRegistration {
  const command = protocolRecord(value)
  const argumentHint =
    command.argumentHint === undefined
      ? undefined
      : boundedRequiredText(command.argumentHint, "command argument hint", maxExtensionCommandArgumentHintBytes)
  return Object.freeze({
    source: extensionSource(command.source),
    name: commandName(command.name),
    description: boundedRequiredText(command.description, "command description", maxExtensionCommandDescriptionBytes),
    ...(argumentHint === undefined ? {} : { argumentHint })
  })
}

function extensionToolRegistration(value: unknown): ExtensionToolRegistration {
  const tool = protocolRecord(value)
  const name = toolName(tool.name)
  const label = boundedRequiredText(tool.label, "tool label", maxExtensionToolLabelBytes)
  const description = boundedRequiredText(tool.description, "tool description", maxExtensionToolDescriptionBytes)
  const active = tool.active === undefined ? true : requiredBoolean(tool.active, "tool active")
  const timeoutMs = tool.timeoutMs === undefined ? undefined : extensionToolTimeout(tool.timeoutMs)
  const parameters = jsonRecord(tool.parameters, "tool parameters", maxExtensionToolSchemaBytes)
  if (parameters.type !== "object") {
    throw new ExtensionProtocolError("Extension tool parameters must be an object schema")
  }
  const outputSchema = jsonRecord(tool.outputSchema, "tool output schema", maxExtensionToolSchemaBytes)
  validateToolSchema(parameters, "parameters")
  validateToolSchema(outputSchema, "outputSchema")
  return Object.freeze({
    source: extensionSource(tool.source),
    name,
    label,
    description,
    active,
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
    parameters,
    outputSchema
  })
}

function validateToolSchema(value: JsonValue, path: string): void {
  if (!isRecord(value)) throw new ExtensionProtocolError(`Extension tool schema ${path} must be an object`)
  if (Object.hasOwn(value, "const")) return
  const type = value.type
  if (type === "string" || type === "number" || type === "integer" || type === "boolean") return
  if (type === "array") {
    if (!("items" in value)) throw new ExtensionProtocolError(`Extension tool array schema ${path} requires items`)
    validateToolSchema(value.items, `${path}.items`)
    return
  }
  if (type === "object") {
    const properties = value.properties
    if (!isRecord(properties)) {
      throw new ExtensionProtocolError(`Extension tool object schema ${path} requires properties`)
    }
    for (const [name, property] of Object.entries(properties)) {
      validateToolSchema(property, `${path}.properties.${name}`)
    }
    if (value.required !== undefined) {
      if (
        !Array.isArray(value.required) ||
        value.required.some(name => typeof name !== "string" || !(name in properties))
      ) {
        throw new ExtensionProtocolError(`Extension tool object schema ${path} has invalid required properties`)
      }
    }
    return
  }
  throw new ExtensionProtocolError(`Extension tool schema ${path} has an unsupported type`)
}

function extensionCustomEntry(value: unknown): ExtensionCustomEntry {
  const entry = protocolRecord(value)
  const customTypeValue = customType(entry.customType)
  const timestamp = boundedRequiredText(entry.timestamp, "custom entry timestamp", 128)
  if (!Number.isFinite(Date.parse(timestamp))) {
    throw new ExtensionProtocolError("Extension custom entry timestamps must be valid dates")
  }
  return Object.freeze({
    id: boundedRequiredText(entry.id, "custom entry id", maxExtensionIdBytes),
    timestamp,
    customType: customTypeValue,
    ...(entry.data === undefined ? {} : { data: jsonValue(entry.data, "custom entry data", maxCustomJsonBytes) })
  })
}

function extensionCustomMessage(value: unknown): ExtensionCustomMessage {
  const admitted = jsonValue(value, "custom message", maxExtensionProtocolFrameBytes)
  try {
    validateCustomMessageInput(admitted)
  } catch (cause) {
    throw new ExtensionProtocolError("Invalid extension custom message", { cause })
  }
  return Object.freeze({
    customType: admitted.customType,
    content: admitted.content,
    display: admitted.display,
    ...(admitted.details === undefined ? {} : { details: admitted.details })
  })
}

function extensionMessageDelivery(value: unknown): ExtensionMessageDelivery {
  if (
    value !== "append" &&
    value !== "trigger_turn" &&
    value !== "steer" &&
    value !== "follow_up" &&
    value !== "next_turn"
  ) {
    throw new ExtensionProtocolError("Unknown extension custom message delivery")
  }
  return value
}

function customType(value: unknown): string {
  try {
    validateCustomType(value)
    return value
  } catch (cause) {
    throw new ExtensionProtocolError("Invalid extension custom type", { cause })
  }
}

function agentTaskName(value: unknown): string {
  const name = boundedRequiredText(value, "agent task name", maxExtensionAgentTaskNameBytes)
  if (!/^[a-z][a-z0-9_-]*$/.test(name)) {
    throw new ExtensionProtocolError("Agent task names must start with a lowercase letter and use a-z, 0-9, _, or -")
  }
  return name
}

function agentPath(value: unknown): string {
  const path = boundedRequiredText(value, "agent path", maxExtensionPathBytes)
  if (!/^\/root(?:\/[a-z][a-z0-9_-]*)*$/.test(path)) throw new ExtensionProtocolError("Invalid agent path")
  return path
}

function agentType(value: unknown): ExtensionAgentType {
  if (value !== "default" && value !== "explorer" && value !== "worker") {
    throw new ExtensionProtocolError("Unknown agent type")
  }
  return value
}

function agentForkTurns(value: unknown): "all" | "none" | number {
  if (value === "all" || value === "none") return value
  return positiveInteger(value, "agent fork turns")
}

function thinkingLevel(value: unknown): ExtensionThinkingLevel {
  if (
    value !== "off" &&
    value !== "minimal" &&
    value !== "low" &&
    value !== "medium" &&
    value !== "high" &&
    value !== "xhigh" &&
    value !== "max"
  ) {
    throw new ExtensionProtocolError("Unknown agent thinking level")
  }
  return value
}

function extensionToolTimeout(value: unknown): number {
  const timeoutMs = positiveInteger(value, "tool timeoutMs")
  if (timeoutMs > maxExtensionToolTimeoutMs) {
    throw new ExtensionProtocolError(`Extension tool timeout cannot exceed ${maxExtensionToolTimeoutMs}ms`)
  }
  return timeoutMs
}

function agentWaitTimeout(value: unknown): number {
  const timeoutMs = nonNegativeInteger(value, "timeoutMs")
  if (timeoutMs > maxExtensionAgentWaitMs) {
    throw new ExtensionProtocolError(`Agent wait timeout cannot exceed ${maxExtensionAgentWaitMs}ms`)
  }
  return timeoutMs
}

function agentDelivery(value: unknown): "started" | "joined" {
  if (value !== "started" && value !== "joined") throw new ExtensionProtocolError("Unknown agent follow-up delivery")
  return value
}

function agentInterruptResult(value: unknown): "interrupted" | "idle" {
  if (value !== "interrupted" && value !== "idle") throw new ExtensionProtocolError("Unknown agent interrupt result")
  return value
}

function commandName(value: unknown): string {
  const name = boundedRequiredText(value, "command name", maxExtensionCommandNameBytes)
  if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(name)) {
    throw new ExtensionProtocolError(
      "Extension command names must start with a lowercase letter and use lowercase letters, numbers, or single hyphens"
    )
  }
  return name
}

function toolName(value: unknown): string {
  const name = boundedRequiredText(value, "tool name", maxExtensionToolNameBytes)
  if (!/^[a-z][a-z0-9_]*$/.test(name)) {
    throw new ExtensionProtocolError("Extension tool names must start with a lowercase letter and use a-z, 0-9, or _")
  }
  return name
}

function activeToolNames(value: unknown): readonly string[] {
  const names = protocolArray(value, "active tool names")
  if (names.length > maxActiveExtensionTools) {
    throw new ExtensionProtocolError(`Active tool names cannot exceed ${maxActiveExtensionTools}`)
  }
  const admitted = names.map(toolName)
  if (new Set(admitted).size !== admitted.length) {
    throw new ExtensionProtocolError("Active tool names must be unique")
  }
  return Object.freeze(admitted)
}

function jsonRecord(value: unknown, field: string, maxBytes: number): Readonly<Record<string, JsonValue>> {
  const admitted = jsonValue(value, field, maxBytes)
  if (!isRecord(admitted)) throw new ExtensionProtocolError(`Extension protocol ${field} must be an object`)
  return admitted
}

function jsonValue(value: unknown, field: string, maxBytes: number): JsonValue {
  let serialized: string | undefined
  try {
    serialized = JSON.stringify(value)
  } catch (cause) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must be JSON`, { cause })
  }
  if (serialized === undefined || Buffer.byteLength(serialized) > maxBytes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed ${maxBytes} bytes`)
  }
  const state = { nodes: 0 }
  return copyJsonValue(value, field, 0, state)
}

function copyJsonValue(value: unknown, field: string, depth: number, state: { nodes: number }): JsonValue {
  state.nodes++
  if (state.nodes > maxExtensionJsonNodes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed ${maxExtensionJsonNodes} JSON nodes`)
  }
  if (depth > maxExtensionJsonDepth) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed depth ${maxExtensionJsonDepth}`)
  }
  if (value === null || typeof value === "string" || typeof value === "boolean") return value
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new ExtensionProtocolError(`Extension protocol ${field} numbers must be finite`)
    return value
  }
  if (Array.isArray(value)) {
    return Object.freeze(value.map(item => copyJsonValue(item, field, depth + 1, state)))
  }
  if (isRecord(value)) {
    const entries = Object.entries(value).map(([key, item]) => {
      if (Buffer.byteLength(key) > maxExtensionJsonKeyBytes) {
        throw new ExtensionProtocolError(
          `Extension protocol ${field} object keys cannot exceed ${maxExtensionJsonKeyBytes} bytes`
        )
      }
      return [key, copyJsonValue(item, field, depth + 1, state)] as const
    })
    return Object.freeze(Object.fromEntries(entries))
  }
  throw new ExtensionProtocolError(`Extension protocol ${field} contains a non-JSON value`)
}

function extensionDiagnostic(value: unknown): ExtensionDiagnostic {
  const diagnostic = protocolRecord(value)
  const phase = diagnostic.phase
  if (
    phase !== "discovery" &&
    phase !== "trust" &&
    phase !== "spawn" &&
    phase !== "handshake" &&
    phase !== "resolve" &&
    phase !== "import" &&
    phase !== "factory" &&
    phase !== "registration" &&
    phase !== "lifecycle" &&
    phase !== "event" &&
    phase !== "command" &&
    phase !== "tool" &&
    phase !== "protocol" &&
    phase !== "shutdown"
  ) {
    throw new ExtensionProtocolError("Unknown extension diagnostic phase")
  }
  const severity = diagnostic.severity
  if (severity !== "warning" && severity !== "error") {
    throw new ExtensionProtocolError("Unknown extension diagnostic severity")
  }
  return Object.freeze({
    ...(diagnostic.extensionId === undefined
      ? {}
      : { extensionId: boundedRequiredText(diagnostic.extensionId, "extensionId", maxExtensionIdBytes) }),
    ...(diagnostic.path === undefined
      ? {}
      : { path: boundedRequiredText(diagnostic.path, "diagnostic path", maxExtensionPathBytes) }),
    phase,
    severity,
    message: boundedRequiredText(diagnostic.message, "diagnostic message", maxExtensionDiagnosticMessageBytes),
    ...(diagnostic.stack === undefined
      ? {}
      : { stack: boundedRequiredText(diagnostic.stack, "diagnostic stack", maxExtensionDiagnosticStackBytes) })
  })
}

function protocolRecord(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) throw new ExtensionProtocolError("Extension protocol messages must be objects")
  return value
}

function protocolArray(value: unknown, field: string): readonly unknown[] {
  if (!Array.isArray(value)) throw new ExtensionProtocolError(`Extension protocol ${field} must be an array`)
  return value
}

function protocolVersion(value: unknown): 13 {
  if (value !== extensionProtocolVersion) throw new ExtensionProtocolError("Unsupported extension protocol version")
  return extensionProtocolVersion
}

function requiredBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") throw new ExtensionProtocolError(`Extension protocol ${field} must be a boolean`)
  return value
}

function nonNegativeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must be a non-negative safe integer`)
  }
  return value
}

function positiveInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must be a positive safe integer`)
  }
  return value
}

function pathText(value: unknown, field: string): string {
  return boundedRequiredText(value, field, maxExtensionPathBytes)
}

function boundedTextValue(value: unknown, field: string, maxBytes: number): string {
  if (typeof value !== "string" || Buffer.byteLength(value) > maxBytes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} cannot exceed ${maxBytes} bytes`)
  }
  return value
}

function boundedRequiredText(value: unknown, field: string, maxBytes: number): string {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value) > maxBytes) {
    throw new ExtensionProtocolError(`Extension protocol ${field} must contain 1 to ${maxBytes} bytes`)
  }
  return value
}

function boundedText(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value) <= maxBytes) return value
  const buffer = Buffer.from(value)
  let end = maxBytes
  while (end > 0 && (buffer[end]! & 0xc0) === 0x80) end--
  return buffer.toString("utf8", 0, end)
}

function extensionContext(value: unknown): ExtensionContext {
  const context = protocolRecord(value)
  const cwd = pathText(context.cwd, "extension context cwd")
  if (!isAbsolute(cwd)) throw new ExtensionProtocolError("Extension context cwd must be absolute")
  return Object.freeze({ mode: extensionMode(context.mode), cwd, session: extensionSession(context.session) })
}

function extensionMode(value: unknown): ExtensionMode {
  if (value !== "interactive" && value !== "text" && value !== "json" && value !== "rpc" && value !== "embedded") {
    throw new ExtensionProtocolError("Unknown extension mode")
  }
  return value
}

function extensionSession(value: unknown): ExtensionSession {
  const session = protocolRecord(value)
  const id = boundedRequiredText(session.id, "extension session id", maxExtensionIdBytes)
  if (session.type === "memory") return Object.freeze({ type: "memory", id })
  if (session.type !== "journal") throw new ExtensionProtocolError("Unknown extension session type")
  const file = pathText(session.file, "extension session file")
  if (!isAbsolute(file)) throw new ExtensionProtocolError("Extension session file must be absolute")
  return Object.freeze({ type: "journal", id, file })
}

function startReason(value: unknown): ExtensionStartReason {
  if (value !== "startup" && value !== "reload" && value !== "new" && value !== "resume" && value !== "fork") {
    throw new ExtensionProtocolError("Unknown extension start reason")
  }
  return value
}

function shutdownReason(value: unknown): ExtensionShutdownReason {
  if (value !== "quit" && value !== "reload" && value !== "new" && value !== "resume" && value !== "fork") {
    throw new ExtensionProtocolError("Unknown extension shutdown reason")
  }
  return value
}

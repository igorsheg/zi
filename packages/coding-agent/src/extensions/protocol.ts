import { isAbsolute } from "node:path"

import type {
  ExtensionAgentSettledEvent,
  ExtensionAgentStartEvent,
  ExtensionContext,
  ExtensionCustomEntry,
  ExtensionCustomMessage,
  ExtensionMessageDelivery,
  ExtensionMode,
  ExtensionSession,
  ExtensionShutdownReason,
  ExtensionStartReason,
  ExtensionThinkingLevel,
  ExtensionSubagentInterruptSettlement,
  ExtensionSubagentProfile,
  ExtensionSubagentSnapshot
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

export const extensionProtocolVersion = 11
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
export const maxExtensionSubagentProfiles = 64
export const maxExtensionSubagentNameBytes = 64
export const maxExtensionSubagentDescriptionBytes = 4 * 1024
export const maxExtensionSubagentModelBytes = 4 * 1024
export const maxExtensionSubagentInstructionsBytes = 8 * 1024
export const maxExtensionSubagentTextBytes = 8 * 1024 * 1024 - maxExtensionSubagentInstructionsBytes - 16
export const maxExtensionSubagentCompletionBytes = 64 * 1024
export const maxExtensionSubagentTaskBytes = 256
export const maxExtensionSubagentWaitMs = maxExtensionToolTimeoutMs
export const maxExtensionSubagentCatalogBytes = 2 * 1024 * 1024
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
      readonly protocolVersion: 11
      readonly generation: number
      readonly plan: ExtensionLoadPlan
      readonly subagentsAvailable?: boolean
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
      readonly type: "agent_roles_result"
      readonly generation: number
      readonly requestId: number
      readonly profiles: readonly ExtensionSubagentProfile[]
    }
  | {
      readonly type: "agent_spawn_result"
      readonly generation: number
      readonly requestId: number
      readonly name: string
    }
  | { readonly type: "agent_send_result"; readonly generation: number; readonly requestId: number }
  | {
      readonly type: "agent_followup_result"
      readonly generation: number
      readonly requestId: number
      readonly delivery: "started_turn" | "follow_up"
    }
  | {
      readonly type: "agent_wait_result"
      readonly generation: number
      readonly requestId: number
      readonly snapshots: readonly ExtensionSubagentSnapshot[]
    }
  | {
      readonly type: "agent_interrupt_result"
      readonly generation: number
      readonly requestId: number
      readonly settlement: ExtensionSubagentInterruptSettlement
    }
  | {
      readonly type: "agent_close_result"
      readonly generation: number
      readonly requestId: number
      readonly snapshot: ExtensionSubagentSnapshot
    }
  | {
      readonly type: "agent_list_result"
      readonly generation: number
      readonly requestId: number
      readonly snapshots: readonly ExtensionSubagentSnapshot[]
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
      readonly protocolVersion: 11
      readonly generation: number
      readonly extensions: readonly ExtensionLoadResult[]
      readonly commands: readonly ExtensionCommandRegistration[]
      readonly tools: readonly ExtensionToolRegistration[]
      readonly subagents?: readonly ExtensionSubagentRegistration[]
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
      readonly type: "agent_roles_get"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
    }
  | {
      readonly type: "agent_spawn"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly profile: string
      readonly name: string
      readonly prompt: string
    }
  | {
      readonly type: "agent_send"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly name: string
      readonly text: string
    }
  | {
      readonly type: "agent_followup"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly name: string
      readonly text: string
    }
  | {
      readonly type: "agent_wait"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly ownerRequestId?: number
      readonly names: readonly string[]
      readonly timeoutMs?: number
    }
  | {
      readonly type: "agent_interrupt"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly name: string
    }
  | {
      readonly type: "agent_close"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
      readonly name: string
    }
  | {
      readonly type: "agent_list"
      readonly generation: number
      readonly requestId: number
      readonly extensionId: string
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

export interface ExtensionSubagentRegistration extends ExtensionSubagentProfile {
  readonly source: ExtensionSource
}

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
        ...(message.subagentsAvailable === undefined
          ? {}
          : { subagentsAvailable: requiredBoolean(message.subagentsAvailable, "subagentsAvailable") })
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
    case "agent_roles_result":
      return Object.freeze({
        type: "agent_roles_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        profiles: extensionSubagentProfiles(message.profiles)
      })
    case "agent_spawn_result":
      return Object.freeze({
        type: "agent_spawn_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        name: subagentName(message.name)
      })
    case "agent_followup_result":
      return Object.freeze({
        type: "agent_followup_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        delivery: subagentDelivery(message.delivery)
      })
    case "agent_wait_result":
    case "agent_list_result":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        snapshots: extensionSubagentSnapshots(message.snapshots)
      })
    case "agent_interrupt_result":
      return Object.freeze({
        type: "agent_interrupt_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        settlement: extensionSubagentInterruptSettlement(message.settlement)
      })
    case "agent_close_result":
      return Object.freeze({
        type: "agent_close_result",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        snapshot: extensionSubagentSnapshot(message.snapshot)
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
      const admittedSubagents =
        message.subagents === undefined ? undefined : validateExtensionSubagentCatalog(message.subagents)
      const admitted = Object.freeze({
        type: "ready" as const,
        protocolVersion: protocolVersion(message.protocolVersion),
        generation: positiveInteger(message.generation, "generation"),
        extensions: Object.freeze(extensions.map(extensionLoadResult)),
        commands: admittedCommands,
        tools: Object.freeze(admittedTools),
        ...(admittedSubagents ? { subagents: admittedSubagents } : {})
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
    case "agent_roles_get":
    case "agent_list":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes)
      })
    case "agent_spawn":
      return Object.freeze({
        type: "agent_spawn",
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        profile: subagentName(message.profile),
        name: subagentName(message.name),
        prompt: boundedRequiredText(message.prompt, "subagent prompt", maxExtensionSubagentTextBytes)
      })
    case "agent_send":
    case "agent_followup":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        name: subagentName(message.name),
        text: boundedRequiredText(message.text, "subagent text", maxExtensionSubagentTextBytes)
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
        names: subagentNames(message.names),
        ...(message.timeoutMs === undefined ? {} : { timeoutMs: subagentWaitTimeout(message.timeoutMs) })
      })
    case "agent_interrupt":
    case "agent_close":
      return Object.freeze({
        type: message.type,
        generation: positiveInteger(message.generation, "generation"),
        requestId: positiveInteger(message.requestId, "requestId"),
        extensionId: boundedRequiredText(message.extensionId, "extension id", maxExtensionIdBytes),
        name: subagentName(message.name)
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

export function validateExtensionSubagentCatalog(value: unknown): readonly ExtensionSubagentRegistration[] {
  const profiles = protocolArray(value, "subagent profiles")
  if (profiles.length > maxExtensionSubagentProfiles) {
    throw new ExtensionProtocolError(`Extension subagent profiles cannot exceed ${maxExtensionSubagentProfiles}`)
  }
  const admitted = profiles.map(extensionSubagentRegistration)
  if (Buffer.byteLength(JSON.stringify(admitted)) > maxExtensionSubagentCatalogBytes) {
    throw new ExtensionProtocolError(
      `Extension subagent profile catalog cannot exceed ${maxExtensionSubagentCatalogBytes} bytes`
    )
  }
  const names = new Set<string>()
  for (const profile of admitted) {
    if (names.has(profile.name)) {
      throw new ExtensionProtocolError(`Extension subagent profile names must be unique: ${profile.name}`)
    }
    names.add(profile.name)
  }
  return Object.freeze(admitted)
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

function extensionSubagentRegistration(value: unknown): ExtensionSubagentRegistration {
  const profile = extensionSubagentProfile(value)
  return Object.freeze({ source: extensionSource(protocolRecord(value).source), ...profile })
}

function extensionSubagentProfiles(value: unknown): readonly ExtensionSubagentProfile[] {
  const profiles = protocolArray(value, "subagent profiles")
  if (profiles.length > maxExtensionSubagentProfiles) {
    throw new ExtensionProtocolError(`Subagent profiles cannot exceed ${maxExtensionSubagentProfiles}`)
  }
  const admitted = profiles.map(extensionSubagentProfile)
  if (Buffer.byteLength(JSON.stringify(admitted)) > maxExtensionSubagentCatalogBytes) {
    throw new ExtensionProtocolError(`Subagent profile catalog cannot exceed ${maxExtensionSubagentCatalogBytes} bytes`)
  }
  return Object.freeze(admitted)
}

function extensionSubagentProfile(value: unknown): ExtensionSubagentProfile {
  const profile = protocolRecord(value)
  const admitted = Object.freeze({
    name: subagentName(profile.name),
    description: subagentProfileText(
      profile.description,
      "subagent profile description",
      maxExtensionSubagentDescriptionBytes
    ),
    instructions: subagentProfileText(
      profile.instructions,
      "subagent profile instructions",
      maxExtensionSubagentInstructionsBytes
    ),
    ...(profile.model === undefined
      ? {}
      : { model: subagentProfileText(profile.model, "subagent profile model", maxExtensionSubagentModelBytes) }),
    ...(profile.thinking === undefined ? {} : { thinking: thinkingLevel(profile.thinking) })
  })
  return admitted
}

function extensionSubagentSnapshots(value: unknown): readonly ExtensionSubagentSnapshot[] {
  const snapshots = protocolArray(value, "subagent snapshots")
  if (snapshots.length > 32) throw new ExtensionProtocolError("Subagent snapshots cannot exceed 32")
  return Object.freeze(snapshots.map(extensionSubagentSnapshot))
}

function extensionSubagentSnapshot(value: unknown): ExtensionSubagentSnapshot {
  const snapshot = protocolRecord(value)
  const lifecycle = snapshot.lifecycle
  if (
    lifecycle !== "idle" &&
    lifecycle !== "queued" &&
    lifecycle !== "running" &&
    lifecycle !== "interrupting" &&
    lifecycle !== "closing" &&
    lifecycle !== "exited"
  ) {
    throw new ExtensionProtocolError("Unknown subagent lifecycle")
  }
  return Object.freeze({
    name: subagentName(snapshot.name),
    lifecycle,
    ...(snapshot.workCycle === undefined
      ? {}
      : { workCycle: nonNegativeInteger(snapshot.workCycle, "subagent workCycle") }),
    ...(snapshot.capturedWorkCycle === undefined
      ? {}
      : { capturedWorkCycle: nonNegativeInteger(snapshot.capturedWorkCycle, "subagent capturedWorkCycle") }),
    ...(snapshot.task === undefined
      ? {}
      : { task: boundedRequiredText(snapshot.task, "subagent task", maxExtensionSubagentTaskBytes) }),
    ...(snapshot.elapsedMs === undefined
      ? {}
      : { elapsedMs: nonNegativeInteger(snapshot.elapsedMs, "subagent elapsedMs") }),
    resultReady: requiredBoolean(snapshot.resultReady, "subagent resultReady"),
    ...(snapshot.completion === undefined ? {} : { completion: extensionSubagentCompletion(snapshot.completion) })
  })
}

function extensionSubagentCompletion(value: unknown): NonNullable<ExtensionSubagentSnapshot["completion"]> {
  const completion = protocolRecord(value)
  if (completion.status !== "completed" && completion.status !== "failed" && completion.status !== "cancelled") {
    throw new ExtensionProtocolError("Unknown subagent completion status")
  }
  return Object.freeze({
    workCycle: positiveInteger(completion.workCycle, "subagent completion workCycle"),
    status: completion.status,
    text: boundedTextValue(completion.text, "subagent completion text", maxExtensionSubagentCompletionBytes),
    originalBytes: nonNegativeInteger(completion.originalBytes, "subagent originalBytes"),
    omittedBytes: nonNegativeInteger(completion.omittedBytes, "subagent omittedBytes"),
    truncated: requiredBoolean(completion.truncated, "subagent truncated"),
    durationMs: nonNegativeInteger(completion.durationMs, "subagent durationMs"),
    ...(completion.reason === undefined
      ? {}
      : {
          reason: boundedTextValue(completion.reason, "subagent completion reason", maxExtensionDiagnosticMessageBytes)
        }),
    ...(completion.error === undefined
      ? {}
      : { error: boundedTextValue(completion.error, "subagent completion error", maxExtensionDiagnosticMessageBytes) })
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

function subagentName(value: unknown): string {
  const name = boundedRequiredText(value, "subagent name", maxExtensionSubagentNameBytes)
  if (!/^[a-z][a-z0-9_-]*$/.test(name)) {
    throw new ExtensionProtocolError("Subagent names must start with a lowercase letter and use a-z, 0-9, _, or -")
  }
  return name
}

function subagentProfileText(value: unknown, field: string, maxBytes: number): string {
  const text = boundedRequiredText(value, field, maxBytes)
  if (text.trim().length === 0) throw new ExtensionProtocolError(`Extension protocol ${field} cannot be blank`)
  return text
}

function subagentNames(value: unknown): readonly string[] {
  const names = protocolArray(value, "subagent names")
  if (names.length > 16) throw new ExtensionProtocolError("Subagent names cannot contain more than 16 items")
  const admitted = names.map(subagentName)
  if (new Set(admitted).size !== admitted.length) throw new ExtensionProtocolError("Subagent names must be unique")
  return Object.freeze(admitted)
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
    throw new ExtensionProtocolError("Unknown subagent thinking level")
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

function subagentWaitTimeout(value: unknown): number {
  const timeoutMs = nonNegativeInteger(value, "timeoutMs")
  if (timeoutMs > maxExtensionSubagentWaitMs) {
    throw new ExtensionProtocolError(`Subagent wait timeout cannot exceed ${maxExtensionSubagentWaitMs}ms`)
  }
  return timeoutMs
}

function subagentDelivery(value: unknown): "started_turn" | "follow_up" {
  if (value !== "started_turn" && value !== "follow_up") throw new ExtensionProtocolError("Unknown subagent delivery")
  return value
}

function extensionSubagentInterruptSettlement(value: unknown): ExtensionSubagentInterruptSettlement {
  const settlement = protocolRecord(value)
  if (settlement.result !== "interrupted" && settlement.result !== "already_idle") {
    throw new ExtensionProtocolError("Unknown subagent interrupt result")
  }
  return Object.freeze({ result: settlement.result, snapshot: extensionSubagentSnapshot(settlement.snapshot) })
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

function protocolVersion(value: unknown): 11 {
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

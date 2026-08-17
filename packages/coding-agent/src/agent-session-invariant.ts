import type { InvariantContext, InvariantRegistry } from "@with-zi/invariants"

import type { AgentSessionEvent } from "./agent-session.js"

const owner = "@with-zi/coding-agent/agent-session"

type AgentLifecycle = { readonly type: "idle" } | { readonly type: "running" }

type Message = Extract<AgentSessionEvent, { type: "message_start" }>["message"]
type MessageIdentity = { readonly role: Message["role"]; readonly timestamp: number }

export class AgentSessionInvariant {
  readonly #dispose: () => void
  #accept: (event: AgentSessionEvent) => void = () => {}
  #interruptMessage: () => void = () => {}
  #projectMessage: (source: Message, projected: Message) => void = () => {}

  constructor(registry: InvariantRegistry) {
    this.#dispose = registry.register(owner, context => {
      const trace = new AgentSessionTrace(context)
      this.#accept = event => trace.accept(event)
      this.#interruptMessage = () => trace.interruptMessage()
      this.#projectMessage = (source, projected) => trace.projectMessage(source, projected)
      return () => {
        this.#accept = () => {}
        this.#interruptMessage = () => {}
        this.#projectMessage = () => {}
      }
    })
  }

  accept(event: AgentSessionEvent): void {
    this.#accept(event)
  }

  interruptMessage(): void {
    this.#interruptMessage()
  }

  projectMessage(source: Message, projected: Message): void {
    this.#projectMessage(source, projected)
  }

  dispose(): void {
    this.#dispose()
  }
}

class AgentSessionTrace {
  readonly #context: InvariantContext
  #message: MessageIdentity | undefined
  readonly #tools = new Map<string, string>()
  readonly #compactions = new Map<number, string>()
  #agent: AgentLifecycle = { type: "idle" }
  #turnOpen = false
  #retryAttempt: number | undefined

  constructor(context: InvariantContext) {
    this.#context = context
  }

  interruptMessage(): void {
    this.#message = undefined
  }

  projectMessage(source: Message, projected: Message): void {
    this.#requireMessage(source, "end")
    this.#message = messageIdentity(projected)
  }

  accept(event: AgentSessionEvent): void {
    switch (event.type) {
      case "agent_start":
        this.#context.assert(this.#agent.type === "idle", "agent_start while an attempt is active")
        this.#agent = { type: "running" }
        return
      case "agent_end":
        this.#context.assert(this.#agent.type === "running", "agent_end without agent_start")
        this.#turnOpen = false
        this.#message = undefined
        this.#tools.clear()
        this.#agent = { type: "idle" }
        return
      case "turn_start":
        this.#requireAgent("turn_start")
        this.#context.assert(!this.#turnOpen, "turn_start while a turn is already open")
        this.#turnOpen = true
        return
      case "turn_end":
        this.#requireAgent("turn_end")
        this.#context.assert(this.#turnOpen, "turn_end without turn_start")
        this.#context.assert(this.#message === undefined, "turn_end while a message is streaming", {
          activeMessage: this.#message
        })
        this.#context.assert(this.#tools.size === 0, "turn_end while tools are executing", {
          activeTools: [...this.#tools.keys()]
        })
        this.#turnOpen = false
        return
      case "message_start":
        this.#requireAgent("message_start")
        this.#context.assert(this.#message === undefined, "message_start while another message is open", {
          activeMessage: this.#message
        })
        this.#message = messageIdentity(event.message)
        return
      case "message_update":
        this.#requireAgent("message_update")
        this.#context.assert(this.#message !== undefined, "message_update without an open message")
        this.#requireMessage(event.message, "update")
        this.#context.assert(event.message.role === "assistant", "message_update for a non-assistant message")
        return
      case "message_end":
        if (event.message.role === "custom" && !this.#messageMatches(event.message)) return
        this.#context.assert(this.#message !== undefined, "message_end without message_start")
        this.#requireMessage(event.message, "end")
        this.#message = undefined
        return
      case "tool_execution_start":
        this.#requireAgent("tool_execution_start")
        this.#context.assert(!this.#tools.has(event.toolCallId), `duplicate tool start ${event.toolCallId}`)
        this.#tools.set(event.toolCallId, event.toolName)
        return
      case "tool_execution_update":
        this.#requireTool(event.toolCallId, event.toolName, "update")
        return
      case "tool_execution_end":
        this.#requireTool(event.toolCallId, event.toolName, "end")
        this.#tools.delete(event.toolCallId)
        return
      case "auto_retry_start":
        if (this.#retryAttempt !== undefined) {
          this.#context.assert(
            event.attempt === this.#retryAttempt + 1,
            `retry attempt ${event.attempt} followed ${this.#retryAttempt}`
          )
        }
        this.#retryAttempt = event.attempt
        return
      case "auto_retry_end":
        this.#context.assert(this.#retryAttempt !== undefined, "auto_retry_end without auto_retry_start")
        this.#context.assert(
          event.attempt === this.#retryAttempt,
          `auto_retry_end names attempt ${event.attempt}, expected ${this.#retryAttempt}`
        )
        this.#retryAttempt = undefined
        return
      case "compaction_start":
        this.#context.assert(
          !this.#compactions.has(event.operationId),
          `duplicate compaction start ${event.operationId}`
        )
        this.#compactions.set(event.operationId, event.reason)
        return
      case "compaction_end": {
        const reason = this.#compactions.get(event.operationId)
        this.#context.assert(reason !== undefined, `compaction end ${event.operationId} without start`)
        this.#context.assert(
          reason === event.reason,
          `compaction ${event.operationId} ended as ${event.reason}, expected ${reason}`
        )
        this.#compactions.delete(event.operationId)
        return
      }
      case "agent_settled":
        this.#context.assert(this.#retryAttempt === undefined, "agent_settled while retry policy is active")
        this.#context.assert(this.#compactions.size === 0, "agent_settled while compaction is active", {
          operationIds: [...this.#compactions.keys()]
        })
        this.#agent = { type: "idle" }
        this.#turnOpen = false
        this.#message = undefined
        this.#tools.clear()
        return
      case "queue_update":
        this.#validateQueue(event.steering, event.followUp)
        return
      case "summarization_retry_scheduled":
      case "summarization_retry_attempt_start":
      case "summarization_retry_finished":
      case "compaction_enabled_changed":
      case "retry_enabled_changed":
      case "codex_fast_mode_changed":
      case "entry_appended":
      case "model_changed":
      case "thinking_level_changed":
      case "steering_mode_changed":
      case "follow_up_mode_changed":
      case "shell_task_changed":
      case "mcp_server_changed":
      case "work_plan_changed":
      case "agent_changed":
      case "authentication_changed":
        return
      default:
        return assertNever(event)
    }
  }

  #requireAgent(event: string): void {
    this.#context.assert(this.#agent.type === "running", `${event} outside an agent attempt`)
  }

  #messageMatches(message: Message): boolean {
    return this.#message?.role === message.role && this.#message.timestamp === message.timestamp
  }

  #requireMessage(message: Message, event: "update" | "end"): void {
    const active = this.#message
    this.#context.assert(active !== undefined, `message_${event} without message_start`)
    this.#context.assert(
      active.role === message.role && active.timestamp === message.timestamp,
      `message_${event} does not match the open message`,
      { active, received: messageIdentity(message) }
    )
  }

  #requireTool(toolCallId: string, toolName: string, event: "update" | "end"): void {
    this.#requireAgent(`tool_execution_${event}`)
    const activeName = this.#tools.get(toolCallId)
    this.#context.assert(activeName !== undefined, `tool ${event} ${toolCallId} without start`)
    this.#context.assert(
      activeName === toolName,
      `tool ${event} ${toolCallId} names ${toolName}, expected ${activeName}`
    )
  }

  #validateQueue(
    steering: Extract<AgentSessionEvent, { type: "queue_update" }>["steering"],
    followUp: Extract<AgentSessionEvent, { type: "queue_update" }>["followUp"]
  ): void {
    const ids = new Set<number>()
    for (const entry of steering) {
      this.#context.assert(entry.delivery === "steer", `steering queue contains ${entry.delivery} input ${entry.id}`)
      this.#context.assert(!ids.has(entry.id), `queue contains duplicate input ${entry.id}`)
      ids.add(entry.id)
    }
    for (const entry of followUp) {
      this.#context.assert(
        entry.delivery === "followUp",
        `follow-up queue contains ${entry.delivery} input ${entry.id}`
      )
      this.#context.assert(!ids.has(entry.id), `queue contains duplicate input ${entry.id}`)
      ids.add(entry.id)
    }
  }
}

function messageIdentity(message: Message): MessageIdentity {
  return { role: message.role, timestamp: message.timestamp }
}

function assertNever(event: never): never {
  throw new Error(`Unhandled AgentSession event: ${JSON.stringify(event)}`)
}

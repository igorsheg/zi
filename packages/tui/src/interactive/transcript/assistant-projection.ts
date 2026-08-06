import type { AgentMessage } from "@with-zi/coding-agent"

import type { ActiveTool } from "../interactive-store.js"

export type AssistantMessage = Extract<AgentMessage, { readonly role: "assistant" }>

export type AssistantProjectionPart =
  | { readonly kind: "thinking"; readonly content: string }
  | { readonly kind: "answer"; readonly content: string }
  | { readonly kind: "tool"; readonly tool: ActiveTool }
  | { readonly kind: "omitted-tools"; readonly count: number }

export interface AssistantToolInclusion {
  includes(id: string): boolean
}

const maxAssistantToolCalls = 64

export function visibleAssistantParts(
  message: AssistantMessage,
  toolInclusion?: AssistantToolInclusion
): AssistantProjectionPart[] {
  const parts: AssistantProjectionPart[] = []
  let directToolCount = 0
  let omittedIndex: number | undefined
  for (const part of message.content) {
    if (part.type === "thinking") {
      if (part.thinking.trim() || parts.at(-1)?.kind === "thinking") {
        appendAssistantText(parts, "thinking", part.thinking)
      }
      continue
    }
    if (part.type === "text" && (part.text.trim() || parts.at(-1)?.kind === "answer")) {
      appendAssistantText(parts, "answer", part.text)
    } else if (part.type === "toolCall" && part.id) {
      const included = toolInclusion ? toolInclusion.includes(part.id) : directToolCount < maxAssistantToolCalls
      directToolCount++
      if (included) {
        parts.push({ kind: "tool", tool: toolFromMessage(message, part) })
      } else if (omittedIndex === undefined) {
        omittedIndex = parts.length
        parts.push({ kind: "omitted-tools", count: 1 })
      } else {
        const omitted = parts[omittedIndex]
        if (omitted?.kind === "omitted-tools") parts[omittedIndex] = { ...omitted, count: omitted.count + 1 }
      }
    }
  }
  const visible: AssistantProjectionPart[] = []
  for (const part of parts) {
    if (part.kind === "thinking") {
      const content = part.content.trimEnd()
      if (content.trim()) visible.push({ kind: "thinking", content })
    } else if (part.kind === "answer") {
      const content = part.content.trim()
      if (content) visible.push({ kind: "answer", content })
    } else {
      visible.push(part)
    }
  }
  return visible
}

function appendAssistantText(parts: AssistantProjectionPart[], kind: "thinking" | "answer", content: string): void {
  const previous = parts.at(-1)
  if (previous?.kind === kind) {
    parts[parts.length - 1] = { kind, content: previous.content + content }
  } else {
    parts.push({ kind, content })
  }
}

function toolFromMessage(
  message: AssistantMessage,
  part: Extract<AssistantMessage["content"][number], { type: "toolCall" }>
): ActiveTool {
  if (message.stopReason === "aborted") {
    return {
      id: part.id,
      name: part.name,
      args: part.arguments,
      status: "aborted",
      result: { content: [{ type: "text", text: "Operation aborted" }] }
    }
  }
  if (message.stopReason === "error") {
    return {
      id: part.id,
      name: part.name,
      args: part.arguments,
      status: "failed",
      result: { content: [{ type: "text", text: message.errorMessage || "Error" }] }
    }
  }
  return { id: part.id, name: part.name, args: part.arguments, status: "preparing" }
}

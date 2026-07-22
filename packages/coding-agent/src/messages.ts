import type { AgentMessage as PiAgentMessage } from "@earendil-works/pi-agent-core"
import type { Message } from "@earendil-works/pi-ai"

export const compactionSummaryPrefix = `The conversation history before this point was compacted into the following checkpoint. Continue from the checkpoint and exact recent messages that follow:\n\n<summary>\n`
export const compactionSummarySuffix = `\n</summary>`

export interface CompactionSummaryMessage {
  readonly role: "compactionSummary"
  readonly summary: string
  readonly tokensBefore: number
  readonly estimatedTokensAfter: number
  readonly timestamp: number
}

export type AgentMessage = Exclude<PiAgentMessage, { role: "compactionSummary" }> | CompactionSummaryMessage

export function isZiAgentMessage(message: PiAgentMessage): message is AgentMessage {
  return (
    message.role !== "compactionSummary" ||
    ("estimatedTokensAfter" in message &&
      typeof message.estimatedTokensAfter === "number" &&
      Number.isFinite(message.estimatedTokensAfter) &&
      message.estimatedTokensAfter >= 0)
  )
}

export interface CompactionSummaryDetails {
  readonly readFiles: readonly string[]
  readonly modifiedFiles: readonly string[]
  readonly omittedReadFiles: number
  readonly omittedModifiedFiles: number
}

export function formatCompactionSummary(summary: string, details: CompactionSummaryDetails): string {
  const sections = [summary]
  appendFileSection(sections, "read-files", details.readFiles, details.omittedReadFiles)
  appendFileSection(sections, "modified-files", details.modifiedFiles, details.omittedModifiedFiles)
  return sections.join("\n\n")
}

export function convertToLlm(messages: PiAgentMessage[]): Message[] {
  return messages.flatMap(message => {
    switch (message.role) {
      case "compactionSummary":
        return [
          {
            role: "user" as const,
            content: [
              { type: "text" as const, text: compactionSummaryPrefix + message.summary + compactionSummarySuffix }
            ],
            timestamp: message.timestamp
          }
        ]
      case "user":
      case "assistant":
      case "toolResult":
        return [message]
      case "bashExecution":
        return message.excludeFromContext
          ? []
          : [
              {
                role: "user" as const,
                content: [{ type: "text" as const, text: bashExecutionText(message) }],
                timestamp: message.timestamp
              }
            ]
      case "custom":
        return [
          {
            role: "user" as const,
            content:
              typeof message.content === "string"
                ? [{ type: "text" as const, text: message.content }]
                : message.content,
            timestamp: message.timestamp
          }
        ]
      case "branchSummary":
        return [
          {
            role: "user" as const,
            content: [{ type: "text" as const, text: `Branch summary:\n${message.summary}` }],
            timestamp: message.timestamp
          }
        ]
      default:
        return assertNever(message)
    }
  })
}

function appendFileSection(sections: string[], name: string, paths: readonly string[], omitted: number): void {
  if (paths.length === 0 && omitted === 0) return
  const omission = omitted > 0 ? `\n… ${omitted} more` : ""
  sections.push(`<${name}>\n${paths.join("\n")}${omission}\n</${name}>`)
}

function bashExecutionText(message: Extract<PiAgentMessage, { role: "bashExecution" }>): string {
  const output = message.output ? `\n\`\`\`\n${message.output}\n\`\`\`` : "\n(no output)"
  const outcome = message.cancelled
    ? "\n\n(command cancelled)"
    : message.exitCode !== undefined && message.exitCode !== 0
      ? `\n\nCommand exited with code ${message.exitCode}`
      : ""
  return `Ran \`${message.command}\`${output}${outcome}`
}

function assertNever(value: never): never {
  throw new Error(`Unexpected agent message: ${String(value)}`)
}

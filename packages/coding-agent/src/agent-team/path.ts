export const maxAgentDepth = 8
export const maxAgentTaskNameBytes = 64
export const maxAgentPathBytes = 512

export type AgentPath = string & { readonly __agentPath: unique symbol }

export type AgentPathErrorReason = "invalid_path" | "invalid_task_name" | "path_depth" | "path_bytes"

export class AgentPathError extends Error {
  constructor(
    readonly reason: AgentPathErrorReason,
    message: string
  ) {
    super(message)
    this.name = "AgentPathError"
  }
}

// The brand enters only through this root literal or parseAgentPath after complete validation.
// oxlint-disable-next-line typescript/no-unsafe-type-assertion
export const rootAgentPath = "/root" as AgentPath

export function parseAgentPath(input: string): AgentPath {
  if (!input.startsWith("/root")) {
    throw new AgentPathError("invalid_path", "Agent paths must start with /root")
  }
  if (input === rootAgentPath) return rootAgentPath
  if (!input.startsWith("/root/") || input.endsWith("/")) {
    throw new AgentPathError("invalid_path", "Invalid canonical agent path")
  }

  const segments = input.slice(1).split("/")
  if (segments.length > maxAgentDepth) {
    throw new AgentPathError("path_depth", `Agent path exceeds depth ${maxAgentDepth}`)
  }
  for (const segment of segments.slice(1)) validateTaskName(segment)
  if (Buffer.byteLength(input) > maxAgentPathBytes) {
    throw new AgentPathError("path_bytes", `Agent path exceeds ${maxAgentPathBytes} bytes`)
  }
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion
  return input as AgentPath
}

export function childAgentPath(parent: AgentPath, taskName: string): AgentPath {
  validateTaskName(taskName)
  return parseAgentPath(`${parent}/${taskName}`)
}

export function resolveAgentPath(sender: AgentPath, input: string): AgentPath {
  if (input.length === 0) throw new AgentPathError("invalid_path", "Agent reference must not be empty")
  return input.startsWith("/") ? parseAgentPath(input) : parseAgentPath(`${sender}/${input}`)
}

export function parentAgentPath(path: AgentPath): AgentPath | undefined {
  if (path === rootAgentPath) return undefined
  return parseAgentPath(path.slice(0, path.lastIndexOf("/")))
}

export function isAgentPathWithin(path: AgentPath, prefix: AgentPath): boolean {
  return path === prefix || path.startsWith(`${prefix}/`)
}

function validateTaskName(taskName: string): void {
  if (taskName.length === 0) {
    throw new AgentPathError("invalid_task_name", "Agent task name must not be empty")
  }
  if (Buffer.byteLength(taskName) > maxAgentTaskNameBytes) {
    throw new AgentPathError("path_bytes", `Agent task name exceeds ${maxAgentTaskNameBytes} bytes`)
  }
  if (taskName === "root" || taskName === "." || taskName === "..") {
    throw new AgentPathError("invalid_task_name", `Agent task name ${JSON.stringify(taskName)} is reserved`)
  }
  if (!/^[a-z][a-z0-9_-]*$/u.test(taskName)) {
    throw new AgentPathError(
      "invalid_task_name",
      "Agent task names must start with a lowercase letter and use lowercase letters, digits, underscores, or hyphens"
    )
  }
}

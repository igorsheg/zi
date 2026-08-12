import type { SubagentSnapshot } from "@with-zi/coding-agent"

export function isActiveSubagentLifecycle(lifecycle: SubagentSnapshot["lifecycle"]): boolean {
  switch (lifecycle) {
    case "starting":
    case "spawn_admitting":
    case "running":
    case "interrupting":
    case "closing":
      return true
    case "idle":
    case "exited":
      return false
    default:
      return assertNever(lifecycle)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected subagent lifecycle: ${String(value)}`)
}

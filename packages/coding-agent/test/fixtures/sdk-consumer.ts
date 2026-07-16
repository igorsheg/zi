import {
  createAgentRuntime,
  createAgentSession,
  type AgentRuntime,
  type AgentSessionServices,
  type CreateAgentRuntimeOptions,
  type CreateAgentSessionOptions
} from "@openzi/coding-agent"
import { createModels } from "@openzi/coding-agent/testing"

export async function useHighLevelRuntime(options: CreateAgentRuntimeOptions): Promise<readonly string[]> {
  const runtime: AgentRuntime = await createAgentRuntime(options)
  const events: string[] = []
  const unsubscribe = runtime.session.subscribe(event => events.push(event.type))
  try {
    if (runtime.session.modelState.type === "selected") await runtime.session.prompt("SDK prompt")
    await runtime.session.waitForIdle()
    await runtime.session.abort()
    return events
  } finally {
    unsubscribe()
    runtime.session.dispose()
  }
}

export function useCallerOwnedServices(options: CreateAgentSessionOptions, services: AgentSessionServices) {
  return createAgentSession({ ...options, services })
}

export const createTestOnlyModels = createModels

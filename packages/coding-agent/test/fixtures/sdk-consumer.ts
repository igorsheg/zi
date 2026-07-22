import {
  createAgentRuntime,
  createAgentSession,
  createAgentSessionRuntime,
  type AgentRuntime,
  type AgentSessionServices,
  type CreateAgentRuntimeOptions,
  type CreateAgentSessionOptions
} from "@with-zi/coding-agent"
import { createModels } from "@with-zi/coding-agent/testing"

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

export async function useReplaceableRuntime(options: CreateAgentRuntimeOptions): Promise<string> {
  const runtime = await createAgentSessionRuntime(options)
  try {
    const previous = runtime.session.sessionManager.sessionId
    await runtime.newSession()
    if (runtime.session.sessionManager.sessionId === previous) throw new Error("Session was not replaced")
    return runtime.session.sessionManager.sessionId
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }
}

export function useCallerOwnedServices(options: CreateAgentSessionOptions, services: AgentSessionServices) {
  return createAgentSession({ ...options, services })
}

export const createTestOnlyModels = createModels

import type { Models } from "@earendil-works/pi-ai"

import { createAgentSessionRuntime } from "./agent-session-runtime.js"
import { createAgentRuntime, type CreateAgentRuntimeOptions } from "./runtime.js"

export type CreateTestAgentRuntimeOptions = Omit<CreateAgentRuntimeOptions, "modelFactory"> & {
  readonly models: Models
}

export function createTestAgentRuntime(options: CreateTestAgentRuntimeOptions) {
  const { models, ...runtimeOptions } = options
  return createAgentRuntime({ ...runtimeOptions, modelFactory: () => models })
}

export function createTestAgentSessionRuntime(options: CreateTestAgentRuntimeOptions) {
  const { models, ...runtimeOptions } = options
  const configured = { ...runtimeOptions, modelFactory: () => models }
  return createAgentSessionRuntime(configured)
}

export {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall,
  type FauxResponseStep
} from "@earendil-works/pi-ai"

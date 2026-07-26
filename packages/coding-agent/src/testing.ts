import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Models } from "@earendil-works/pi-ai"

import { createAgentSessionRuntime } from "./agent-session-runtime.js"
import { createAgentRuntime, type CreateAgentRuntimeOptions } from "./runtime.js"

export type CreateTestAgentRuntimeOptions = Omit<CreateAgentRuntimeOptions, "modelFactory"> & {
  readonly models: Models
}

let testAgentRoot: string | undefined
let nextTestAgent = 0

export function createTestAgentRuntime(options: CreateTestAgentRuntimeOptions) {
  const { models, ...runtimeOptions } = options
  return createAgentRuntime({
    ...runtimeOptions,
    agentDir: runtimeOptions.agentDir ?? nextTestAgentDir(),
    modelFactory: () => models
  })
}

export function createTestAgentSessionRuntime(options: CreateTestAgentRuntimeOptions) {
  const { models, ...runtimeOptions } = options
  const configured = {
    ...runtimeOptions,
    agentDir: runtimeOptions.agentDir ?? nextTestAgentDir(),
    modelFactory: () => models
  }
  return createAgentSessionRuntime(configured)
}

function nextTestAgentDir(): string {
  testAgentRoot ??= mkdtempSync(join(tmpdir(), "zi-coding-agent-tests-"))
  return join(testAgentRoot, String(++nextTestAgent))
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

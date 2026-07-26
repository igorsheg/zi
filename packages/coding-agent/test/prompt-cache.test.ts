import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Type, type CacheRetention, type Context, type ThinkingContent, type Transport } from "@earendil-works/pi-ai"

import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep
} from "../src/testing.js"

interface CacheRequest {
  readonly context: Context
  readonly sessionId: string | undefined
  readonly cacheRetention: CacheRetention | undefined
  readonly transport: Transport | undefined
}

const probeParameters = Type.Object({ turn: Type.Number() })

// Pi v0.80.6 core/sdk.ts and sdk-codex-cache-probe-tool-loop.ts: one logical
// session keeps its routing identity and append-only request prefix through tool continuations.
test("ordinary and tool-loop requests preserve one cache-affinity prefix", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-prompt-cache-prefix-"))
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const requests: CacheRequest[] = []
  faux.setResponses([
    captureRequest(
      requests,
      fauxAssistantMessage(fauxToolCall("probe", { turn: 1 }, { id: "probe-1" }), { stopReason: "toolUse" })
    ),
    captureRequest(requests, fauxAssistantMessage("turn one complete")),
    captureRequest(
      requests,
      fauxAssistantMessage(fauxToolCall("probe", { turn: 2 }, { id: "probe-2" }), { stopReason: "toolUse" })
    ),
    captureRequest(requests, fauxAssistantMessage("turn two complete"))
  ])

  const { session } = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    models,
    session: { type: "new", persist: false }
  })
  session.setActiveTools([
    {
      name: "probe",
      label: "probe",
      description: "Return a deterministic cache probe result",
      parameters: probeParameters,
      async execute() {
        return { content: [{ type: "text" as const, text: "probe complete" }], details: undefined }
      }
    }
  ])

  try {
    await session.prompt("run turn one")
    await session.prompt("run turn two")

    expect(requests).toHaveLength(4)
    expect(requests.every(request => request.sessionId === session.sessionId)).toBe(true)
    expect(requests.every(request => request.cacheRetention !== "none")).toBe(true)
    expect(requests.every(request => request.transport === "auto")).toBe(true)
    expect(requests.map(request => request.context.systemPrompt)).toEqual(
      Array.from({ length: requests.length }, () => requests[0]!.context.systemPrompt)
    )
    expect(requests.map(request => toolSchemas(request.context))).toEqual(
      Array.from({ length: requests.length }, () => toolSchemas(requests[0]!.context))
    )

    for (let index = 1; index < requests.length; index++) {
      const previous = requests[index - 1]!.context.messages
      expect(requests[index]!.context.messages.slice(0, previous.length)).toEqual(previous)
    }

    const assistants = session.messages.filter(message => message.role === "assistant")
    expect(assistants[0]?.usage.cacheWrite).toBeGreaterThan(0)
    expect(assistants.slice(1).every(message => message.usage.cacheRead > 0)).toBe(true)
  } finally {
    session.dispose()
  }
})

// A resumed journal must recover the same provider routing key and opaque assistant
// metadata; otherwise an unchanged transcript can serialize to a different provider prefix.
test("resume preserves cache affinity and provider replay metadata", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-prompt-cache-resume-"))
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const requests: CacheRequest[] = []
  const signedThinking: ThinkingContent = {
    type: "thinking",
    thinking: "stable reasoning",
    thinkingSignature: "opaque-signature"
  }
  faux.setResponses([
    captureRequest(
      requests,
      fauxAssistantMessage([signedThinking, { type: "text", text: "first answer" }], { responseId: "response-1" })
    ),
    captureRequest(requests, fauxAssistantMessage("second answer"))
  ])

  const first = await createAgentRuntime({
    cwd: root,
    model: "faux/faux-1",
    sessionDir: join(root, "sessions"),
    models
  })
  const prior = await (async () => {
    try {
      await first.session.prompt("first prompt")
      const file = first.session.sessionManager.file
      if (!file) throw new Error("First turn did not create its session journal")
      return { file, sessionId: first.session.sessionId }
    } finally {
      first.session.dispose()
    }
  })()

  const resumed = await createAgentRuntime({
    cwd: "/ignored-on-resume",
    session: { type: "resume", file: prior.file },
    models
  })
  try {
    expect(resumed.session.sessionId).toBe(prior.sessionId)
    await resumed.session.prompt("second prompt")

    expect(requests).toHaveLength(2)
    expect(requests.map(request => request.sessionId)).toEqual([prior.sessionId, prior.sessionId])
    expect(requests[1]!.context.systemPrompt).toBe(requests[0]!.context.systemPrompt)
    expect(toolSchemas(requests[1]!.context)).toEqual(toolSchemas(requests[0]!.context))
    expect(requests[1]!.context.messages.slice(0, requests[0]!.context.messages.length)).toEqual(
      requests[0]!.context.messages
    )

    const replayedAssistant = requests[1]!.context.messages.find(message => message.role === "assistant")
    expect(replayedAssistant).toMatchObject({ responseId: "response-1" })
    expect(replayedAssistant?.content[0]).toMatchObject({ thinkingSignature: "opaque-signature" })
    const latestAssistant = resumed.session.messages.findLast(message => message.role === "assistant")
    expect(latestAssistant?.usage.cacheRead).toBeGreaterThan(0)
  } finally {
    resumed.session.dispose()
  }
})

function toolSchemas(context: Context) {
  return context.tools?.map(tool => ({ name: tool.name, description: tool.description, parameters: tool.parameters }))
}

function captureRequest(requests: CacheRequest[], response: ReturnType<typeof fauxAssistantMessage>): FauxResponseStep {
  return (context, options) => {
    requests.push({
      context,
      sessionId: options?.sessionId,
      cacheRetention: options?.cacheRetention,
      transport: options?.transport
    })
    return response
  }
}

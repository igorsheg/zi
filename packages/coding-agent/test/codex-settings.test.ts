import { expect, test } from "bun:test"

import type { Api, Model } from "@earendil-works/pi-ai"
import { fauxProvider } from "@earendil-works/pi-ai"

import { applyCodexRequestSettings } from "../src/codex-settings.js"
import { createModels, createTestAgentRuntime, fauxAssistantMessage } from "../src/testing.js"

const faux = fauxProvider()
const baseModel = faux.provider.getModels()[0]!
const codexModel = { ...baseModel, provider: "openai-codex" } as Model<Api>

test("Codex Fast Mode composes payload hooks before enforcing low verbosity and priority", async () => {
  const payload = { text: { verbosity: "medium" }, service_tier: "default", input: [] }
  let upstreamPayload: unknown
  const result = await applyCodexRequestSettings(payload, codexModel, true, current => {
    upstreamPayload = current
    return { text: { verbosity: "high", format: "plain" }, service_tier: "default", input: [] }
  })

  expect(upstreamPayload).toBe(payload)
  expect(result).toEqual({ text: { verbosity: "low", format: "plain" }, service_tier: "priority", input: [] })
  expect(payload).toEqual({ text: { verbosity: "medium" }, service_tier: "default", input: [] })
})

test("disabling Codex Fast Mode removes both request fields without discarding other text options", async () => {
  expect(
    await applyCodexRequestSettings(
      { text: { verbosity: "low", format: "plain" }, service_tier: "priority", input: [] },
      codexModel,
      false
    )
  ).toEqual({ text: { format: "plain" }, input: [] })

  expect(
    await applyCodexRequestSettings(
      { text: { verbosity: "low" }, service_tier: "priority", input: [] },
      codexModel,
      false
    )
  ).toEqual({ input: [] })
})

test("Codex request settings leave other providers to the upstream payload hook", async () => {
  const payload = { text: { verbosity: "medium" }, service_tier: "default" }
  const replacement = { replaced: true }

  expect(await applyCodexRequestSettings(payload, baseModel, true, () => replacement)).toBe(replacement)
})

test("AgentSession applies the current persisted Fast Mode to each Codex turn", async () => {
  const models = createModels()
  const provider = fauxProvider({ provider: "openai-codex", models: [{ id: "gpt-codex", reasoning: true }] })
  provider.setResponses([fauxAssistantMessage("default"), fauxAssistantMessage("fast")])
  models.setProvider(provider.provider)

  const payloads: Promise<unknown>[] = []
  const streamSimple = models.streamSimple.bind(models)
  models.streamSimple = (model, context, options) => {
    payloads.push(
      Promise.resolve(options?.onPayload?.({ text: { verbosity: "low" }, service_tier: "priority", input: [] }, model))
    )
    const { onPayload: _onPayload, ...delegateOptions } = options ?? {}
    return streamSimple(model, context, delegateOptions)
  }

  const { session } = await createTestAgentRuntime({
    cwd: "/work",
    model: "openai-codex/gpt-codex",
    models,
    session: { type: "new", persist: false }
  })
  try {
    await session.prompt("default request")
    session.setCodexFastMode(true)
    await session.prompt("fast request")

    expect(await Promise.all(payloads)).toEqual([
      { input: [] },
      { text: { verbosity: "low" }, service_tier: "priority", input: [] }
    ])
  } finally {
    session.dispose()
  }
})

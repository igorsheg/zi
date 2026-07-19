import type { Api, KnownProvider, Model } from "@earendil-works/pi-ai"

import type { ModelRegistry } from "./model-registry.js"
import type { SessionModel } from "./session-manager.js"

/** Default model IDs and provider order from Pi at the pinned reference revision. */
export const defaultModelPerProvider: Record<KnownProvider, string> = {
  "amazon-bedrock": "us.anthropic.claude-opus-4-6-v1",
  "ant-ling": "Ring-2.6-1T",
  anthropic: "claude-opus-4-8",
  openai: "gpt-5.5",
  "azure-openai-responses": "gpt-5.4",
  "openai-codex": "gpt-5.5",
  nvidia: "nvidia/nemotron-3-super-120b-a12b",
  deepseek: "deepseek-v4-pro",
  google: "gemini-3.1-pro-preview",
  "google-vertex": "gemini-3.1-pro-preview",
  "github-copilot": "gpt-5.4",
  openrouter: "moonshotai/kimi-k2.6",
  "vercel-ai-gateway": "zai/glm-5.1",
  xai: "grok-4.20-0309-reasoning",
  groq: "openai/gpt-oss-120b",
  cerebras: "zai-glm-4.7",
  zai: "glm-5.1",
  "zai-coding-cn": "glm-5.1",
  mistral: "devstral-medium-latest",
  minimax: "MiniMax-M2.7",
  "minimax-cn": "MiniMax-M2.7",
  moonshotai: "kimi-k2.6",
  "moonshotai-cn": "kimi-k2.6",
  huggingface: "moonshotai/Kimi-K2.6",
  fireworks: "accounts/fireworks/models/kimi-k2p6",
  together: "moonshotai/Kimi-K2.6",
  opencode: "kimi-k2.6",
  "opencode-go": "kimi-k2.6",
  "kimi-coding": "kimi-for-coding",
  "cloudflare-workers-ai": "@cf/moonshotai/kimi-k2.6",
  "cloudflare-ai-gateway": "workers-ai/@cf/moonshotai/kimi-k2.6",
  xiaomi: "mimo-v2.5-pro",
  "xiaomi-token-plan-cn": "mimo-v2.5-pro",
  "xiaomi-token-plan-ams": "mimo-v2.5-pro",
  "xiaomi-token-plan-sgp": "mimo-v2.5-pro"
}

export function resolveRequestedModel(registry: ModelRegistry, reference: string): Model<Api> {
  const model = registry.find(reference)
  if (!model) throw new Error(`Unknown model: ${reference}. Use provider/model-id.`)
  return model
}

export async function restoreModelFromSession(
  registry: ModelRegistry,
  saved: SessionModel
): Promise<Model<Api> | undefined> {
  const model = registry.get(saved.provider, saved.modelId)
  return model && (await registry.isConfigured(model)) ? model : undefined
}

export async function findInitialModel(
  registry: ModelRegistry,
  defaultProvider?: string,
  defaultModelId?: string,
  assumeDefaultConfigured = false
): Promise<Model<Api> | undefined> {
  if (defaultProvider && defaultModelId) {
    const model = registry.get(defaultProvider, defaultModelId)
    if (model && (assumeDefaultConfigured || (await registry.isConfigured(model)))) return model
  }

  for (const [provider, modelId] of Object.entries(defaultModelPerProvider)) {
    const model = registry.get(provider, modelId)
    if (model && (await registry.isConfigured(model))) return model // oxlint-disable-line no-await-in-loop
  }

  const checkedProviders = new Set<string>()
  for (const model of registry.list()) {
    if (checkedProviders.has(model.provider)) continue
    checkedProviders.add(model.provider)
    if (await registry.isConfigured(model)) return model // oxlint-disable-line no-await-in-loop
  }

  return undefined
}

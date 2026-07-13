import type { Api, Model } from "@earendil-works/pi-ai"
import type { ModelRegistry } from "./model-registry.js"

const preferred = [
  ["anthropic", "claude-opus-4-8"],
  ["openai", "gpt-5.5"],
  ["google", "gemini-3.1-pro-preview"],
  ["openrouter", "moonshotai/kimi-k2.6"],
] as const

export class NoModelAvailableError extends Error {}

export async function resolveInitialModel(registry: ModelRegistry, reference?: string): Promise<Model<Api>> {
  if (reference) {
    const model = registry.find(reference)
    if (!model) throw new Error(`Unknown model: ${reference}. Use provider/model-id.`)
    if (!(await registry.isConfigured(model))) throw new Error(`No authentication configured for ${model.provider}`)
    return model
  }

  for (const [provider, id] of preferred) {
    const model = registry.get(provider, id)
    if (model && (await registry.isConfigured(model))) return model
  }
  const checkedProviders = new Set<string>()
  for (const model of registry.list()) {
    if (checkedProviders.has(model.provider)) continue
    checkedProviders.add(model.provider)
    if (await registry.isConfigured(model)) return model
  }

  throw new NoModelAvailableError(
    "No configured model found. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENROUTER_API_KEY, then pass --model provider/model-id if needed.",
  )
}

import type { Api, Model, SimpleStreamOptions } from "@earendil-works/pi-ai"

import { isRecord } from "./guards.js"

export async function applyCodexRequestSettings(
  payload: unknown,
  model: Model<Api>,
  fastMode: boolean,
  upstream?: SimpleStreamOptions["onPayload"]
): Promise<unknown> {
  const replacement = await upstream?.(payload, model)
  const current = replacement ?? payload
  if (model.provider !== "openai-codex" || !isRecord(current)) return current

  const next = { ...current }
  if (fastMode) {
    next.text = { ...(isRecord(next.text) ? next.text : {}), verbosity: "low" }
    next.service_tier = "priority"
    return next
  }

  delete next.service_tier
  if (isRecord(next.text)) {
    const text = { ...next.text }
    delete text.verbosity
    if (Object.keys(text).length > 0) next.text = text
    else delete next.text
  }
  return next
}

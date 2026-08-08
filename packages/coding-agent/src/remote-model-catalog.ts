import type { Api, Model, ModelsStoreEntry, Provider, RefreshModelsContext } from "@earendil-works/pi-ai"

import { admitCatalogModel, maxCatalogModelsPerProvider, maxCatalogProviderIdLength } from "./model-catalog-store.js"

const defaultCatalogBaseUrl = "https://pi.dev"
export const remoteCatalogRefreshIntervalMs = 4 * 60 * 60 * 1000
export const maxRemoteCatalogBytes = 8 * 1024 * 1024
export const maxRemoteCatalogChunks = 8192

export interface RemoteModelCatalogOptions {
  readonly userAgent: string
  readonly localGeneratedAt?: number
  readonly catalogBaseUrl?: string
}

/**
 * Pi provenance: pi-coding-agent remote-catalog-provider.ts at 73414d08.
 * This provider owns the persisted pi.dev overlay while its wrapped built-in remains the static fallback.
 */
export function withRemoteModelCatalog(provider: Provider, options: RemoteModelCatalogOptions): Provider {
  if (!provider.id || provider.id.length > maxCatalogProviderIdLength) {
    throw new Error(`Invalid built-in provider ID: ${provider.id}`)
  }
  let overlay: readonly Model<Api>[] = Object.freeze([])
  let refresh: Promise<void> | undefined

  return {
    ...provider,
    getModels: () => mergeModels(provider.getModels(), overlay),
    refreshModels: context => {
      refresh ??= refreshOverlay(provider.id, context, options, models => {
        overlay = models
      }).finally(() => {
        refresh = undefined
      })
      return refresh
    }
  }
}

async function refreshOverlay(
  providerId: string,
  context: RefreshModelsContext,
  options: RemoteModelCatalogOptions,
  publish: (models: readonly Model<Api>[]) => void
): Promise<void> {
  const stored = await context.store.read()
  const restored = remoteModels(stored, options.localGeneratedAt).filter(model => model.provider === providerId)
  publish(Object.freeze([...restored]))

  if (!context.allowNetwork || context.signal?.aborted) return
  if (
    !context.force &&
    stored?.checkedAt !== undefined &&
    stored.lastModified !== undefined &&
    Date.now() - stored.checkedAt < remoteCatalogRefreshIntervalMs
  ) {
    return
  }

  const validator = stored?.models.length ? stored.etag : undefined
  const url = new URL(
    `/api/models/providers/${encodeURIComponent(providerId)}`,
    options.catalogBaseUrl ?? defaultCatalogBaseUrl
  )
  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      "user-agent": options.userAgent,
      ...(validator ? { "if-none-match": validator } : {})
    },
    ...(context.signal ? { signal: context.signal } : {})
  })
  if (context.signal?.aborted) return

  const checkedAt = Date.now()
  if (response.status === 304 && stored) {
    await context.store.write(Object.freeze({ ...stored, checkedAt }))
    return
  }
  if (response.status === 404 || response.status === 501) {
    await context.store.write(
      Object.freeze({ models: stored?.models ?? Object.freeze([]), checkedAt, lastModified: stored?.lastModified ?? 0 })
    )
    return
  }
  if (!response.ok) {
    throw new Error(`Model catalog request failed for ${providerId}: ${response.status}`)
  }

  const refreshed = parseRemoteCatalog(providerId, await readBoundedResponse(response))
  const parsedLastModified = Date.parse(response.headers.get("last-modified") ?? "")
  const etag = response.headers.get("etag")
  const entry: ModelsStoreEntry = Object.freeze({
    models: refreshed,
    checkedAt,
    lastModified: Number.isNaN(parsedLastModified) ? 0 : parsedLastModified,
    ...(etag ? { etag } : {})
  })
  if (context.signal?.aborted) return
  await context.store.write(entry)
  if (context.signal?.aborted) return
  publish(remoteModels(entry, options.localGeneratedAt))
}

function remoteModels(
  entry: ModelsStoreEntry | undefined,
  localGeneratedAt: number | undefined
): readonly Model<Api>[] {
  if (!entry) return Object.freeze([])
  if (localGeneratedAt !== undefined && (entry.lastModified === undefined || entry.lastModified <= localGeneratedAt)) {
    return Object.freeze([])
  }
  return entry.models
}

function mergeModels(baseline: readonly Model<Api>[], overlay: readonly Model<Api>[]): readonly Model<Api>[] {
  const merged = [...baseline]
  for (const model of overlay) {
    const index = merged.findIndex(entry => entry.id === model.id)
    if (index >= 0) merged[index] = model
    else merged.push(model)
  }
  return merged
}

function parseRemoteCatalog(providerId: string, content: string): readonly Model<Api>[] {
  let value: unknown
  try {
    value = JSON.parse(content)
  } catch (cause) {
    throw new Error(`Invalid model catalog JSON for ${providerId}`, { cause })
  }
  const entries = catalogEntries(value)
  if (!entries || entries.length > maxCatalogModelsPerProvider) {
    throw new Error(`Invalid model catalog for ${providerId}`)
  }
  return Object.freeze(entries.map(entry => admitCatalogModel(entry, providerId)))
}

function catalogEntries(value: unknown): readonly unknown[] | undefined {
  if (Array.isArray(value)) return value
  if (!isRecord(value)) return undefined
  if ("models" in value) return Array.isArray(value.models) ? value.models : undefined
  return Object.values(value)
}

async function readBoundedResponse(response: Response): Promise<string> {
  const length = Number(response.headers.get("content-length"))
  if (Number.isFinite(length) && length > maxRemoteCatalogBytes) {
    await response.body?.cancel()
    throw new Error(`Remote model catalogs cannot exceed ${maxRemoteCatalogBytes} bytes`)
  }
  if (!response.body) return ""

  const reader = response.body.getReader()
  const content = new Uint8Array(maxRemoteCatalogBytes)
  let bytes = 0
  let chunks = 0
  try {
    while (true) {
      // oxlint-disable-next-line no-await-in-loop
      const next = await reader.read()
      if (next.done) break
      chunks++
      if (chunks > maxRemoteCatalogChunks || bytes + next.value.byteLength > maxRemoteCatalogBytes) {
        // oxlint-disable-next-line no-await-in-loop
        await reader.cancel()
        throw new Error(`Remote model catalogs cannot exceed ${maxRemoteCatalogBytes} bytes`)
      }
      content.set(next.value, bytes)
      bytes += next.value.byteLength
    }
  } finally {
    reader.releaseLock()
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(content.subarray(0, bytes))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

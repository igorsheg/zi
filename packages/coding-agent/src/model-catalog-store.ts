import {
  chmodSync,
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeFileSync
} from "node:fs"
import { basename, dirname, join } from "node:path"

import type { Api, Model, ModelsStore, ModelsStoreEntry } from "@earendil-works/pi-ai"
import lockfile from "proper-lockfile"

import { isFiniteNumber, isNonNegativeFinite, isRecord } from "./guards.js"
import type { ZiPaths } from "./paths.js"

export const maxModelsStoreBytes = 32 * 1024 * 1024
export const maxCatalogProviders = 64
export const maxCatalogModelsPerProvider = 4096
export const maxCatalogProviderIdLength = 128
export const maxCatalogModelIdLength = 512
export const maxCatalogStringBytes = 16 * 1024

/** Locked, bounded storage for provider overlays. Malformed data is ignored so built-ins remain usable. */
export class FileModelCatalogStore implements ModelsStore {
  readonly #path: string

  constructor(paths: ZiPaths) {
    this.#path = paths.modelsStoreFile
  }

  async read(providerId: string): Promise<ModelsStoreEntry | undefined> {
    assertProviderId(providerId)
    return this.#withLock(() => {
      const entry = parseStoredModels(readModelsFile(this.#path))[providerId]
      return entry ? structuredClone(entry) : undefined
    })
  }

  async write(providerId: string, entry: ModelsStoreEntry): Promise<void> {
    assertProviderId(providerId)
    const admitted = admitStoreEntry(providerId, entry)
    await this.#withLock(() => {
      const data = parseStoredModels(readModelsFile(this.#path))
      if (!(providerId in data) && Object.keys(data).length >= maxCatalogProviders) {
        throw new Error(`Model catalog stores cannot contain more than ${maxCatalogProviders} providers`)
      }
      data[providerId] = admitted
      this.#write(data)
    })
  }

  async delete(providerId: string): Promise<void> {
    assertProviderId(providerId)
    await this.#withLock(() => {
      const data = parseStoredModels(readModelsFile(this.#path))
      if (!(providerId in data)) return
      delete data[providerId]
      this.#write(data)
    })
  }

  async #withLock<T>(operation: () => T | Promise<T>): Promise<T> {
    this.#ensureFile()
    const release = await lockfile.lock(this.#path, {
      realpath: false,
      retries: { retries: 10, factor: 2, minTimeout: 20, maxTimeout: 500, randomize: true },
      stale: 30_000
    })
    try {
      return await operation()
    } finally {
      await release()
    }
  }

  #ensureFile(): void {
    mkdirSync(dirname(this.#path), { recursive: true, mode: 0o700 })
    if (existsSync(this.#path)) return
    try {
      writeFileSync(this.#path, "{}\n", { encoding: "utf8", flag: "wx", mode: 0o600 })
    } catch (error) {
      if (!hasCode(error, "EEXIST")) throw error
    }
  }

  #write(data: StoredModels): void {
    const serialized = `${JSON.stringify(data, null, 2)}\n`
    if (Buffer.byteLength(serialized) > maxModelsStoreBytes) {
      throw new Error(`Model catalog stores cannot exceed ${maxModelsStoreBytes} bytes: ${this.#path}`)
    }
    const temporary = join(dirname(this.#path), `.${basename(this.#path)}.${process.pid}.tmp`)
    try {
      writeFileSync(temporary, serialized, { encoding: "utf8", mode: 0o600 })
      renameSync(temporary, this.#path)
      chmodSync(this.#path, 0o600)
    } finally {
      if (existsSync(temporary)) unlinkSync(temporary)
    }
  }
}

type StoredModels = Record<string, ModelsStoreEntry>

function parseStoredModels(content: string): StoredModels {
  let value: unknown
  try {
    value = JSON.parse(content)
  } catch {
    return {}
  }
  if (!isRecord(value)) return {}
  const entries = Object.entries(value)
  if (entries.length > maxCatalogProviders) return {}

  const admitted: StoredModels = {}
  for (const [providerId, entry] of entries) {
    try {
      assertProviderId(providerId)
      admitted[providerId] = admitStoreEntry(providerId, entry)
    } catch {
      // A provider's optional cache cannot invalidate unrelated catalogs.
    }
  }
  return admitted
}

function admitStoreEntry(providerId: string, value: unknown): ModelsStoreEntry {
  if (!isRecord(value) || !Array.isArray(value.models) || value.models.length > maxCatalogModelsPerProvider) {
    throw new Error(`Invalid stored model catalog for ${providerId}`)
  }
  const models = Object.freeze(value.models.map(model => admitCatalogModel(model, providerId, true)))
  const lastModified = optionalTimestamp(value.lastModified, "lastModified", providerId)
  const checkedAt = optionalTimestamp(value.checkedAt, "checkedAt", providerId)
  const etag = optionalBoundedString(value.etag, "etag", providerId)
  return Object.freeze({
    models,
    ...(lastModified === undefined ? {} : { lastModified }),
    ...(checkedAt === undefined ? {} : { checkedAt }),
    ...(etag === undefined ? {} : { etag })
  })
}

/** Validate an open-world catalog value and return an immutable model owned by one provider. */
export function admitCatalogModel(value: unknown, providerId: string, requireProvider = false): Model<Api> {
  if (!isRecord(value)) throw new Error(`Invalid model in catalog for ${providerId}`)
  if (requireProvider && value.provider !== providerId) {
    throw new Error(`Stored model provider does not match ${providerId}`)
  }
  const candidate = { ...value, provider: providerId }
  if (!isCatalogModel(candidate)) throw new Error(`Invalid model in catalog for ${providerId}`)
  validateJsonValue(candidate, new WeakSet(), 0)

  const model = structuredClone(candidate)
  Object.freeze(model.input)
  if (model.cost.tiers) {
    for (const tier of model.cost.tiers) Object.freeze(tier)
    Object.freeze(model.cost.tiers)
  }
  Object.freeze(model.cost)
  if (model.headers) Object.freeze(model.headers)
  if (model.thinkingLevelMap) Object.freeze(model.thinkingLevelMap)
  return Object.freeze(model)
}

function readModelsFile(path: string): string {
  const file = openSync(path, "r")
  try {
    const size = fstatSync(file).size
    if (size > maxModelsStoreBytes) {
      throw new Error(`Model catalog stores cannot exceed ${maxModelsStoreBytes} bytes: ${path}`)
    }
    const buffer = Buffer.allocUnsafe(size + 1)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      const read = readSync(file, buffer, bytesRead, buffer.length - bytesRead, null)
      if (read === 0) break
      bytesRead += read
    }
    if (bytesRead > maxModelsStoreBytes) {
      throw new Error(`Model catalog stores cannot exceed ${maxModelsStoreBytes} bytes: ${path}`)
    }
    return buffer.toString("utf8", 0, bytesRead)
  } finally {
    closeSync(file)
  }
}

function isCatalogModel(value: Record<string, unknown>): value is Record<string, unknown> & Model<Api> {
  return (
    isBoundedString(value.id, maxCatalogModelIdLength) &&
    isBoundedString(value.name) &&
    isBoundedString(value.api) &&
    isBoundedString(value.provider, maxCatalogProviderIdLength) &&
    isBoundedString(value.baseUrl) &&
    typeof value.reasoning === "boolean" &&
    Array.isArray(value.input) &&
    value.input.length <= 2 &&
    value.input.every(input => input === "text" || input === "image") &&
    isCost(value.cost) &&
    isPositiveFinite(value.contextWindow) &&
    isPositiveFinite(value.maxTokens) &&
    (value.headers === undefined || isHeaders(value.headers)) &&
    (value.thinkingLevelMap === undefined || isThinkingLevelMap(value.thinkingLevelMap))
  )
}

function isCost(value: unknown): value is Model<Api>["cost"] {
  if (!isRecord(value)) return false
  if (![value.input, value.output, value.cacheRead, value.cacheWrite].every(isFiniteNumber)) return false
  if (value.tiers === undefined) return true
  return (
    Array.isArray(value.tiers) &&
    value.tiers.length <= 64 &&
    value.tiers.every(
      tier =>
        isRecord(tier) &&
        [tier.input, tier.output, tier.cacheRead, tier.cacheWrite].every(isFiniteNumber) &&
        isNonNegativeFinite(tier.inputTokensAbove)
    )
  )
}

function isHeaders(value: unknown): value is Record<string, string> {
  if (!isRecord(value)) return false
  const entries = Object.entries(value)
  return (
    entries.length <= 256 &&
    entries.every(
      ([name, header]) =>
        name.length > 0 &&
        Buffer.byteLength(name) <= 1024 &&
        typeof header === "string" &&
        Buffer.byteLength(header) <= maxCatalogStringBytes
    )
  )
}

function validateJsonValue(value: unknown, seen: WeakSet<object>, depth: number): void {
  if (depth > 64) throw new Error("Model catalog values cannot exceed 64 levels")
  if (typeof value === "string") {
    if (Buffer.byteLength(value) > maxCatalogStringBytes) throw new Error("Model catalog strings are too large")
    return
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Model catalog numbers must be finite")
    return
  }
  if (value === null || typeof value === "boolean") return
  if (typeof value !== "object") throw new Error("Model catalogs must contain JSON values")
  if (seen.has(value)) throw new Error("Model catalogs cannot contain cycles")
  seen.add(value)
  const entries = Array.isArray(value) ? value.entries() : Object.entries(value)
  let count = 0
  for (const [key, item] of entries) {
    count++
    if (count > 4096) throw new Error("Model catalog containers are too large")
    if (typeof key === "string" && Buffer.byteLength(key) > 1024) throw new Error("Model catalog keys are too large")
    validateJsonValue(item, seen, depth + 1)
  }
  seen.delete(value)
}

function optionalTimestamp(value: unknown, name: string, providerId: string): number | undefined {
  if (value === undefined) return undefined
  if (!isNonNegativeFinite(value)) throw new Error(`Invalid ${name} for stored model catalog ${providerId}`)
  return value
}

function optionalBoundedString(value: unknown, name: string, providerId: string): string | undefined {
  if (value === undefined) return undefined
  if (typeof value !== "string" || Buffer.byteLength(value) > maxCatalogStringBytes) {
    throw new Error(`Invalid ${name} for stored model catalog ${providerId}`)
  }
  return value
}

function assertProviderId(providerId: string): void {
  if (
    !providerId ||
    providerId.length > maxCatalogProviderIdLength ||
    Buffer.byteLength(providerId) > maxCatalogStringBytes
  ) {
    throw new Error(`Provider IDs must contain 1-${maxCatalogProviderIdLength} characters`)
  }
}

function isBoundedString(value: unknown, maxCharacters?: number): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    (maxCharacters === undefined || value.length <= maxCharacters) &&
    Buffer.byteLength(value) <= maxCatalogStringBytes
  )
}

function isThinkingLevelMap(value: unknown): boolean {
  if (!isRecord(value)) return false
  const levels = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"])
  return Object.entries(value).every(
    ([level, mapped]) =>
      levels.has(level) && (mapped === null || (typeof mapped === "string" && isBoundedString(mapped)))
  )
}

function isPositiveFinite(value: unknown): value is number {
  return isFiniteNumber(value) && value > 0
}

function hasCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code
}

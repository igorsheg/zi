import {
  chmodSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeFileSync
} from "node:fs"
import { basename, dirname, join } from "node:path"

import type { Credential, CredentialStore } from "@earendil-works/pi-ai"
import lockfile from "proper-lockfile"

import { isRecord, isStringRecord } from "./guards.js"
import type { ZiPaths } from "./paths.js"

export const maxAuthFileBytes = 1024 * 1024
export const maxStoredCredentials = 256
export const maxProviderIdLength = 128

export interface StoredCredential {
  readonly providerId: string
  readonly type: Credential["type"]
}

/** Global auth.json storage with cross-process read-modify-write serialization. */
export class FileCredentialStore implements CredentialStore {
  readonly #path: string

  constructor(paths: ZiPaths) {
    this.#path = paths.authFile
  }

  async list(): Promise<readonly StoredCredential[]> {
    return this.#withLock(() =>
      Object.entries(this.#read())
        .map(([providerId, value]) => {
          if (!isCredential(value)) throw new Error(`Invalid credential for ${providerId}: ${this.#path}`)
          return Object.freeze({ providerId, type: value.type })
        })
        .toSorted((left, right) => left.providerId.localeCompare(right.providerId))
    )
  }

  async read(providerId: string): Promise<Credential | undefined> {
    assertProviderId(providerId)
    return this.#withLock(() => readCredential(this.#read(), providerId, this.#path))
  }

  async modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>
  ): Promise<Credential | undefined> {
    assertProviderId(providerId)
    return this.#withLock(async () => {
      const data = this.#read()
      const current = readCredential(data, providerId, this.#path)
      const next = await fn(current)
      if (next === undefined) return current
      if (!isCredential(next)) throw new Error(`Invalid credential for ${providerId}`)
      data[providerId] = next
      this.#write(data)
      return next
    })
  }

  async delete(providerId: string): Promise<void> {
    assertProviderId(providerId)
    await this.#withLock(() => {
      const data = this.#read()
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

  #read(): Record<string, unknown> {
    let value: unknown
    try {
      value = JSON.parse(readAuthFile(this.#path))
    } catch (error) {
      const detail = error instanceof Error ? `: ${error.message}` : ""
      throw new Error(`Could not read credentials ${this.#path}${detail}`, { cause: error })
    }
    if (!isRecord(value)) throw new Error(`Invalid credentials object: ${this.#path}`)
    validateAuthData(value, this.#path)
    return value
  }

  #write(data: Record<string, unknown>): void {
    const temporary = join(dirname(this.#path), `.${basename(this.#path)}.${process.pid}.tmp`)
    try {
      const serialized = `${JSON.stringify(data, null, 2)}\n`
      if (Buffer.byteLength(serialized) > maxAuthFileBytes) {
        throw new Error(`Auth files cannot exceed ${maxAuthFileBytes} bytes: ${this.#path}`)
      }
      writeFileSync(temporary, serialized, { encoding: "utf8", mode: 0o600 })
      renameSync(temporary, this.#path)
      chmodSync(this.#path, 0o600)
    } finally {
      if (existsSync(temporary)) unlinkSync(temporary)
    }
  }
}

function readAuthFile(path: string): string {
  const file = openSync(path, "r")
  try {
    const buffer = Buffer.allocUnsafe(maxAuthFileBytes + 1)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      const read = readSync(file, buffer, bytesRead, buffer.length - bytesRead, null)
      if (read === 0) break
      bytesRead += read
    }
    if (bytesRead > maxAuthFileBytes) {
      throw new Error(`Auth files cannot exceed ${maxAuthFileBytes} bytes: ${path}`)
    }
    return buffer.toString("utf8", 0, bytesRead)
  } finally {
    closeSync(file)
  }
}

function validateAuthData(data: Record<string, unknown>, path: string): void {
  const entries = Object.entries(data)
  if (entries.length > maxStoredCredentials) {
    throw new Error(`Auth files cannot contain more than ${maxStoredCredentials} providers: ${path}`)
  }
  for (const [providerId, credential] of entries) {
    assertProviderId(providerId)
    if (!isCredential(credential)) throw new Error(`Invalid credential for ${providerId}: ${path}`)
  }
}

function assertProviderId(providerId: string): void {
  if (!providerId || providerId.length > maxProviderIdLength) {
    throw new Error(`Provider IDs must contain 1-${maxProviderIdLength} characters`)
  }
}

function readCredential(data: Record<string, unknown>, providerId: string, path: string): Credential | undefined {
  const value = data[providerId]
  if (value === undefined) return undefined
  if (!isCredential(value)) throw new Error(`Invalid credential for ${providerId}: ${path}`)
  return value
}

function isCredential(value: unknown): value is Credential {
  if (!isRecord(value)) return false
  if (value.type === "api_key") {
    return (
      (value.key === undefined || typeof value.key === "string") &&
      (value.env === undefined || isStringRecord(value.env))
    )
  }
  return (
    value.type === "oauth" &&
    typeof value.refresh === "string" &&
    typeof value.access === "string" &&
    typeof value.expires === "number" &&
    Number.isFinite(value.expires)
  )
}

function hasCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code
}

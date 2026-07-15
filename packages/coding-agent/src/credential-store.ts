import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { basename, dirname, join } from "node:path"

import type { Credential, CredentialStore } from "@earendil-works/pi-ai"
import lockfile from "proper-lockfile"

import type { OpenZiPaths } from "./paths.js"

/** Global auth.json storage with cross-process read-modify-write serialization. */
export class FileCredentialStore implements CredentialStore {
  readonly #path: string

  constructor(paths: OpenZiPaths) {
    this.#path = paths.authFile
  }

  async read(providerId: string): Promise<Credential | undefined> {
    return this.#withLock(() => readCredential(this.#read(), providerId, this.#path))
  }

  async modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>
  ): Promise<Credential | undefined> {
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
      value = JSON.parse(readFileSync(this.#path, "utf8"))
    } catch (error) {
      throw new Error(`Could not read credentials ${this.#path}`, { cause: error })
    }
    if (!isRecord(value)) throw new Error(`Invalid credentials object: ${this.#path}`)
    return value
  }

  #write(data: Record<string, unknown>): void {
    const temporary = join(dirname(this.#path), `.${basename(this.#path)}.${process.pid}.tmp`)
    try {
      writeFileSync(temporary, `${JSON.stringify(data, null, 2)}\n`, { encoding: "utf8", mode: 0o600 })
      renameSync(temporary, this.#path)
      chmodSync(this.#path, 0o600)
    } finally {
      if (existsSync(temporary)) unlinkSync(temporary)
    }
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

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.values(value).every(item => typeof item === "string")
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function hasCode(error: unknown, code: string): boolean {
  return isRecord(error) && error.code === code
}

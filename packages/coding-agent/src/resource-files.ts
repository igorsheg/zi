import { closeSync, type Dirent, openSync, opendirSync, readSync, realpathSync, statSync } from "node:fs"
import { resolve } from "node:path"

export const maxResourceFileBytes = 1024 * 1024
export const maxResourceDirectoryEntries = 4096

export class ResourceFileLimitError extends Error {
  readonly path: string
  readonly limit: number

  constructor(path: string, limit: number) {
    super(`Resource files cannot exceed ${limit} bytes: ${path}`)
    this.name = "ResourceFileLimitError"
    this.path = path
    this.limit = limit
  }
}

export class SessionResourceBudget {
  readonly limit: number
  #used = 0

  constructor(limit: number) {
    this.limit = limit
  }

  retain(bytes: number): boolean {
    if (bytes > this.limit - this.#used) return false
    this.#used += bytes
    return true
  }
}

export function readResourceFile(path: string): string {
  const file = openSync(path, "r")
  try {
    const buffer = Buffer.allocUnsafe(maxResourceFileBytes + 1)
    let bytesRead = 0
    while (bytesRead < buffer.length) {
      const count = readSync(file, buffer, bytesRead, buffer.length - bytesRead, null)
      if (count === 0) break
      bytesRead += count
    }
    if (bytesRead > maxResourceFileBytes) throw new ResourceFileLimitError(path, maxResourceFileBytes)
    return buffer.toString("utf8", 0, bytesRead)
  } finally {
    closeSync(file)
  }
}

export function readResourceDirectory(path: string): {
  readonly entries: readonly Dirent[]
  readonly truncated: boolean
} {
  const directory = opendirSync(path)
  const entries: Dirent[] = []
  let truncated = false
  try {
    while (entries.length < maxResourceDirectoryEntries) {
      const entry = directory.readSync()
      if (!entry) break
      entries.push(entry)
    }
    if (entries.length === maxResourceDirectoryEntries) truncated = directory.readSync() !== null
  } finally {
    try {
      directory.closeSync()
    } catch {
      // Node closes a directory automatically after readSync() reaches the end.
    }
  }
  entries.sort(compareDirectoryEntries)
  return { entries, truncated }
}

export function canonicalResourcePath(path: string): string {
  try {
    return realpathSync.native(path)
  } catch {
    return resolve(path)
  }
}

export function resourcePathType(path: string): "file" | "directory" | undefined {
  try {
    const stat = statSync(path)
    if (stat.isFile()) return "file"
    if (stat.isDirectory()) return "directory"
  } catch {
    return undefined
  }
  return undefined
}

function compareDirectoryEntries(left: Dirent, right: Dirent): number {
  if (left.name < right.name) return -1
  if (left.name > right.name) return 1
  return 0
}

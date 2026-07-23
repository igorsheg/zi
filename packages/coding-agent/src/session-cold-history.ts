import { StringDecoder } from "node:string_decoder"
import { zstdCompressSync, zstdDecompressSync } from "node:zlib"

import type { SessionEntry } from "./session-manager.js"

const coldBlockBytes = 1024 * 1024

export type SessionColdBlock =
  | { readonly encoding: "raw"; readonly bytes: Buffer }
  | { readonly encoding: "zstd"; readonly bytes: Buffer; readonly logicalBytes: number }

export function appendSessionColdEntries(
  blocks: readonly SessionColdBlock[],
  entries: readonly SessionEntry[]
): readonly SessionColdBlock[] {
  if (entries.length === 0) return blocks

  const last = blocks.at(-1)
  const appendToLast = last !== undefined && blockLogicalBytes(last) < coldBlockBytes
  const retainedBlocks = appendToLast ? blocks.slice(0, -1) : blocks
  const encoder = new SessionColdEncoder()

  // Replacing the only partial block keeps total block count bounded by logical session bytes.
  if (appendToLast) encoder.append(decodeBlock(last))
  for (const entry of entries) encoder.append(Buffer.from(`${JSON.stringify(entry)}\n`, "utf8"))
  return [...retainedBlocks, ...encoder.finish()]
}

export function visitSessionColdLines(blocks: readonly SessionColdBlock[], visit: (line: string) => void): void {
  const decoder = new StringDecoder("utf8")
  let fragments: string[] = []

  const consume = (text: string) => {
    let offset = 0
    for (let newline = text.indexOf("\n"); newline >= 0; newline = text.indexOf("\n", offset)) {
      const fragment = text.slice(offset, newline)
      const line = fragments.length === 0 ? fragment : fragments.join("") + fragment
      fragments = []
      if (line) visit(line)
      offset = newline + 1
    }
    if (offset < text.length) fragments.push(text.slice(offset))
  }

  for (const block of blocks) consume(decoder.write(decodeBlock(block)))
  consume(decoder.end())
  if (fragments.length > 0) throw new Error("Invalid in-memory cold session history")
}

export function sessionColdBytes(blocks: readonly SessionColdBlock[]): number {
  return blocks.reduce((bytes, block) => bytes + block.bytes.byteLength, 0)
}

export function sessionColdLogicalBytes(blocks: readonly SessionColdBlock[]): number {
  return blocks.reduce(
    (bytes, block) => bytes + (block.encoding === "raw" ? block.bytes.byteLength : block.logicalBytes),
    0
  )
}

class SessionColdEncoder {
  readonly #blocks: SessionColdBlock[] = []
  #buffer: Buffer | undefined
  #length = 0

  append(bytes: Buffer): void {
    let offset = 0
    while (offset < bytes.byteLength) {
      const buffer = (this.#buffer ??= Buffer.allocUnsafe(coldBlockBytes))
      const copied = bytes.copy(buffer, this.#length, offset)
      this.#length += copied
      offset += copied
      if (this.#length === buffer.byteLength) this.#flush(buffer)
    }
  }

  finish(): readonly SessionColdBlock[] {
    const buffer = this.#buffer
    if (buffer) this.#flush(buffer)
    return this.#blocks
  }

  #flush(buffer: Buffer): void {
    const source = buffer.subarray(0, this.#length)
    const compressed = zstdCompressSync(source)
    if (compressed.byteLength < source.byteLength) {
      this.#blocks.push({ encoding: "zstd", bytes: compressed, logicalBytes: source.byteLength })
    } else {
      this.#blocks.push({
        encoding: "raw",
        bytes: source.byteLength === buffer.byteLength ? buffer : Buffer.from(source)
      })
    }
    this.#buffer = undefined
    this.#length = 0
  }
}

function blockLogicalBytes(block: SessionColdBlock): number {
  return block.encoding === "raw" ? block.bytes.byteLength : block.logicalBytes
}

function decodeBlock(block: SessionColdBlock): Buffer {
  switch (block.encoding) {
    case "raw":
      return block.bytes
    case "zstd": {
      const decoded = zstdDecompressSync(block.bytes)
      if (decoded.byteLength !== block.logicalBytes) throw new Error("Invalid in-memory cold session history")
      return decoded
    }
    default:
      return assertNever(block)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected cold session block: ${String(value)}`)
}

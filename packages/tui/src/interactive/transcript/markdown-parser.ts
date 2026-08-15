import { init, parseAST, type ComarkElement, type ComarkElementAttributes, type ComarkNode } from "md4x/standalone"

await init()

export const maxMarkdownSourceBytes = 8 * 1024 * 1024

const maxMarkdownBlocks = 512
const ignoredPresentationAttributes = new Set([
  "id",
  "title",
  "filename",
  "src",
  "target",
  "refId",
  "refCount",
  "block"
])

export type MarkdownAttributes = ComarkElementAttributes
export type MarkdownNode = ComarkNode
export type MarkdownElement = ComarkElement

export interface ParsedMarkdownBlock {
  readonly node: MarkdownNode
  readonly digest: Uint8Array
}

export type MarkdownParseFailure = "source_limit" | "parser"

export type MarkdownParseResult =
  | { readonly ok: true; readonly blocks: readonly ParsedMarkdownBlock[] }
  | { readonly ok: false; readonly reason: MarkdownParseFailure }

export function parseMarkdown(source: string): MarkdownParseResult {
  if (source.length > maxMarkdownSourceBytes || Buffer.byteLength(source) > maxMarkdownSourceBytes) {
    return { ok: false, reason: "source_limit" }
  }

  let nodes: readonly MarkdownNode[]
  try {
    nodes = parseAST(source, { heal: true }).nodes
  } catch {
    return { ok: false, reason: "parser" }
  }

  const retained = nodes.length > maxMarkdownBlocks ? nodes.slice(0, maxMarkdownBlocks - 1) : nodes
  const blocks = retained.map(node => ({ node, digest: digestNode(node) }))
  const omitted = nodes.length - retained.length
  if (omitted > 0) {
    const node = `[${omitted} additional Markdown blocks omitted.]`
    blocks.push({ node, digest: digestNode(node) })
  }
  return { ok: true, blocks }
}

function digestNode(node: MarkdownNode): Uint8Array {
  const projection = JSON.stringify(node, (key, value: unknown) =>
    ignoredPresentationAttributes.has(key) ? undefined : value
  )
  return new Bun.CryptoHasher("sha256").update(projection).digest()
}

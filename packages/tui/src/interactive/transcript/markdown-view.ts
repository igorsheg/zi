import {
  BoxRenderable,
  CodeRenderable,
  StyledText,
  TextAttributes,
  TextRenderable,
  TextTableRenderable,
  type ColorInput,
  type RenderContext,
  type SyntaxStyle,
  type TextChunk,
  type TextTableContent
} from "@opentui/core"

import type { Theme } from "../../theme.js"
import {
  maxMarkdownSourceBytes,
  parseMarkdown,
  type MarkdownElement,
  type MarkdownNode,
  type MarkdownParseFailure,
  type ParsedMarkdownBlock
} from "./markdown-parser.js"
import { createMermaidRenderer, type MermaidRenderer } from "./mermaid/markdown.js"

export interface MarkdownViewOptions {
  readonly content: string
  readonly theme: Theme
  readonly syntaxStyle: SyntaxStyle
  readonly fg?: ColorInput
  readonly bg?: ColorInput
}

type BlockKind = "paragraph" | "heading" | "code" | "list" | "quote" | "rule" | "table" | "text"

type BodySpec =
  | { readonly kind: "text"; readonly content: StyledText }
  | { readonly kind: "code"; readonly content: string; readonly language: string | undefined }
  | { readonly kind: "mermaid"; readonly content: string }
  | { readonly kind: "table"; readonly content: TextTableContent }

type BlockBody =
  | { readonly kind: "text"; readonly renderable: TextRenderable }
  | { readonly kind: "code"; readonly renderable: CodeRenderable }
  | { readonly kind: "mermaid"; readonly renderable: TextRenderable }
  | { readonly kind: "table"; readonly renderable: TextTableRenderable }

interface BlockRecord {
  readonly root: BoxRenderable
  kind: BlockKind
  digest: Uint8Array
  body: BlockBody
}

interface InlineFormat {
  readonly styles: readonly string[]
  readonly strikethrough: boolean
  readonly href?: string
}

const plainFormat: InlineFormat = { styles: [], strikethrough: false }

export class MarkdownView extends BoxRenderable {
  readonly #ctx: RenderContext
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #fg: ColorInput
  readonly #bg: ColorInput
  readonly #mermaid: MermaidRenderer
  readonly #blocks: BlockRecord[] = []
  #nextBlockId = 0
  #content: string
  #lifecycle: "active" | "recursive" | "destroyed" = "active"

  constructor(ctx: RenderContext, options: MarkdownViewOptions) {
    super(ctx, { width: "100%", flexDirection: "column", flexShrink: 0, rowGap: 1 })
    this.#ctx = ctx
    this.#theme = options.theme
    this.#syntaxStyle = options.syntaxStyle
    this.#fg = options.fg ?? options.theme.text.primary
    this.#bg = options.bg ?? options.theme.surface.app
    this.#content = options.content
    this.#mermaid = createMermaidRenderer(ctx, {
      compact: true,
      colors: {
        text: options.theme.text.primary,
        primary: options.theme.text.primary,
        secondary: options.theme.text.muted,
        muted: options.theme.border.default,
        warning: options.theme.text.warning,
        background: options.theme.surface.app,
        request: options.theme.text.success,
        response: options.theme.text.warning,
        note: options.theme.text.primary,
        noteBackground: options.theme.surface.panel
      }
    })
    this.#reconcile(options.content)
  }

  get content(): string {
    return this.#content
  }

  set content(value: string) {
    if (value === this.#content) return
    this.#content = value
    this.#reconcile(value)
  }

  get streaming(): true {
    return true
  }

  override destroyRecursively(): void {
    if (this.#lifecycle !== "active") return
    this.#lifecycle = "recursive"
    if (this.hasSelection()) this.#ctx.clearSelection()
    super.destroyRecursively()
  }

  override destroy(): void {
    if (this.#lifecycle === "destroyed") return
    const childrenAlreadyDestroyed = this.#lifecycle === "recursive"
    this.#lifecycle = "destroyed"
    if (this.hasSelection()) this.#ctx.clearSelection()
    for (const block of this.#blocks) {
      this.#mermaid.release(block.root.id)
      if (!childrenAlreadyDestroyed) block.root.destroyRecursively()
    }
    this.#blocks.length = 0
    super.destroy()
  }

  #reconcile(source: string): void {
    const parsed = parseMarkdown(source)
    const blocks = parsed.ok ? parsed.blocks : [fallbackBlock(source, parsed.reason)]
    let prefix = Math.min(blocks.length, this.#blocks.length)
    for (let index = 0; index < prefix; index++) {
      if (!sameDigest(this.#blocks[index]!.digest, blocks[index]!.digest)) {
        prefix = index
        break
      }
    }

    const finalChanged =
      prefix === blocks.length - 1 &&
      blocks.length === this.#blocks.length &&
      blockKind(blocks[prefix]!.node) === this.#blocks[prefix]?.kind
    if (finalChanged) {
      const block = this.#blocks[prefix]!
      this.#apply(block, blockSpec(blocks[prefix]!.node, this.#syntaxStyle))
      block.digest = blocks[prefix]!.digest
      return
    }

    if (this.#blocks.slice(prefix).some(block => block.root.hasSelection())) this.#ctx.clearSelection()
    while (this.#blocks.length > prefix) {
      const block = this.#blocks.pop()!
      this.#mermaid.release(block.root.id)
      block.root.destroyRecursively()
    }

    for (let index = prefix; index < blocks.length; index++) {
      const parsedBlock = blocks[index]!
      const node = parsedBlock.node
      const root = new BoxRenderable(this.#ctx, {
        id: `${this.id}:block:${this.#nextBlockId++}`,
        width: "100%",
        flexDirection: "column",
        flexShrink: 0
      })
      const spec = blockSpec(node, this.#syntaxStyle)
      const block: BlockRecord = {
        root,
        kind: blockKind(node),
        digest: parsedBlock.digest,
        body: this.#createBody(root.id, spec)
      }
      root.add(block.body.renderable)
      this.add(root)
      this.#blocks.push(block)
    }
  }

  #apply(block: BlockRecord, spec: BodySpec): void {
    if (block.body.renderable.hasSelection()) this.#ctx.clearSelection()
    if (spec.kind === "text" && block.body.kind === "text") {
      block.body.renderable.content = spec.content
      return
    }
    if (spec.kind === "table" && block.body.kind === "table") {
      block.body.renderable.content = spec.content
      return
    }
    if (spec.kind === "code" && block.body.kind === "code") {
      block.body.renderable.filetype = spec.language
      block.body.renderable.content = spec.content
      return
    }

    let body: BlockBody
    if (spec.kind === "mermaid" && block.body.kind === "code") {
      const diagram = this.#mermaid.render(block.root.id, spec.content)
      if (!diagram) {
        block.body.renderable.filetype = "mermaid"
        block.body.renderable.content = spec.content
        return
      }
      diagram.marginTop = 0
      body = { kind: "mermaid", renderable: diagram }
    } else {
      body = this.#createBody(block.root.id, spec)
    }
    if (block.body.kind === "mermaid" && body.kind !== "mermaid") this.#mermaid.release(block.root.id)
    block.root.remove(block.body.renderable)
    block.body.renderable.destroyRecursively()
    block.body = body
    block.root.add(body.renderable)
  }

  #createBody(key: string, spec: BodySpec): BlockBody {
    if (spec.kind === "text") {
      return {
        kind: "text",
        renderable: new TextRenderable(this.#ctx, {
          width: "100%",
          fg: this.#fg,
          bg: this.#bg,
          content: spec.content,
          wrapMode: "word"
        })
      }
    }
    if (spec.kind === "table") {
      return {
        kind: "table",
        renderable: new TextTableRenderable(this.#ctx, {
          width: "100%",
          fg: this.#fg,
          bg: this.#bg,
          content: spec.content,
          wrapMode: "word",
          columnWidthMode: "full",
          columnFitter: "balanced",
          cellPaddingX: 1,
          border: true,
          outerBorder: true,
          borderColor: this.#theme.border.default
        })
      }
    }
    if (spec.kind === "mermaid") {
      const diagram = this.#mermaid.render(key, spec.content)
      if (diagram) {
        diagram.marginTop = 0
        return { kind: "mermaid", renderable: diagram }
      }
      return this.#createCode(spec.content, "mermaid")
    }
    return this.#createCode(spec.content, spec.language)
  }

  #createCode(content: string, language: string | undefined): BlockBody {
    return {
      kind: "code",
      renderable: new CodeRenderable(this.#ctx, {
        width: "100%",
        fg: this.#fg,
        bg: this.#bg,
        content,
        ...(language === undefined ? {} : { filetype: language }),
        syntaxStyle: this.#syntaxStyle,
        baseHighlight: "markup.raw.block",
        conceal: true,
        drawUnstyledText: true,
        streaming: true,
        wrapMode: "none"
      })
    }
  }
}

function blockKind(node: MarkdownNode): BlockKind {
  if (typeof node === "string") return "text"
  const tag = node[0]
  if (tag === "p") return "paragraph"
  if (tag === "pre") return "code"
  if (tag === "ul" || tag === "ol") return "list"
  if (tag === "blockquote" || tag === "alert") return "quote"
  if (tag === "hr") return "rule"
  if (tag === "table") return "table"
  if (tag === "h1" || tag === "h2" || tag === "h3" || tag === "h4" || tag === "h5" || tag === "h6") {
    return "heading"
  }
  return "text"
}

function blockSpec(node: MarkdownNode, syntaxStyle: SyntaxStyle): BodySpec {
  if (typeof node === "string") {
    return { kind: "text", content: new StyledText([styledChunk(node, syntaxStyle, [], false)]) }
  }
  const [tag, attributes, ...children] = node
  if (tag === null) return { kind: "text", content: new StyledText([]) }
  if (tag === "pre") {
    const code = codeBlock(attributes, children)
    return code.language === "mermaid"
      ? { kind: "mermaid", content: code.content }
      : { kind: "code", content: code.content, language: code.language }
  }
  if (tag === "table") return { kind: "table", content: tableContent(node, syntaxStyle) }
  if (tag === "footnotes") return { kind: "text", content: new StyledText(footnoteChunks(children, syntaxStyle)) }
  if (tag === "ul" || tag === "ol") {
    const chunks: TextChunk[] = []
    appendList(node, 0, chunks, syntaxStyle, [])
    return { kind: "text", content: new StyledText(chunks) }
  }
  if (tag === "blockquote" || tag === "alert") {
    const quote = blockTextChunks(children, syntaxStyle, ["markup.quote"])
    if (tag === "alert") {
      const type = typeof attributes.type === "string" ? attributes.type.toUpperCase() : "ALERT"
      const label = styledChunk(type, syntaxStyle, ["markup.quote", "markup.strong"], false)
      quote.unshift(...(quote.length === 0 ? [label] : [label, plainChunk("\n")]))
    }
    const prefix = styledChunk("│ ", syntaxStyle, ["markup.quote"], false)
    return { kind: "text", content: new StyledText(prefixLines(quote, prefix)) }
  }
  if (tag === "hr") {
    return {
      kind: "text",
      content: new StyledText([styledChunk("────────────────", syntaxStyle, ["markup.quote"], false)])
    }
  }
  if (tag === "h1" || tag === "h2" || tag === "h3" || tag === "h4" || tag === "h5" || tag === "h6") {
    const format: InlineFormat = { styles: ["markup.heading", `markup.heading.${tag.slice(1)}`], strikethrough: false }
    return { kind: "text", content: new StyledText(inlineChunks(children, syntaxStyle, format)) }
  }
  if (tag === "html") {
    return { kind: "text", content: new StyledText([plainChunk(stripHtml(textContent(children)))]) }
  }
  return { kind: "text", content: new StyledText(inlineChunks(children, syntaxStyle, plainFormat)) }
}

function codeBlock(
  attributes: MarkdownElement[1],
  children: readonly MarkdownNode[]
): { readonly content: string; readonly language: string | undefined } {
  const code = children.find(child => typeof child !== "string" && child[0] === "code")
  const language =
    typeof attributes.language === "string"
      ? attributes.language
      : typeof code !== "string" && typeof code?.[1].class === "string"
        ? code[1].class.replace(/^language-/, "")
        : undefined
  const content = code && typeof code !== "string" ? textContent(elementChildren(code)) : textContent(children)
  return { content: content.endsWith("\n") ? content.slice(0, -1) : content, language }
}

function inlineChunks(nodes: readonly MarkdownNode[], syntaxStyle: SyntaxStyle, format: InlineFormat): TextChunk[] {
  const chunks: TextChunk[] = []
  for (const node of nodes) {
    if (typeof node === "string") {
      chunks.push(styledChunk(softBreaks(node), syntaxStyle, format.styles, format.strikethrough, format.href))
      continue
    }
    const [tag, attributes, ...children] = node
    if (tag === null) continue
    if (tag === "br") {
      chunks.push(plainChunk("\n"))
      continue
    }
    if (tag === "strong") {
      chunks.push(...inlineChunks(children, syntaxStyle, addStyle(format, "markup.strong")))
      continue
    }
    if (tag === "em") {
      chunks.push(...inlineChunks(children, syntaxStyle, addStyle(format, "markup.italic")))
      continue
    }
    if (tag === "del") {
      chunks.push(
        ...inlineChunks(children, syntaxStyle, { ...addStyle(format, "markup.strikethrough"), strikethrough: true })
      )
      continue
    }
    if (tag === "code") {
      chunks.push(...inlineChunks(children, syntaxStyle, addStyle(format, "markup.raw.inline")))
      continue
    }
    if (tag === "a") {
      const href = typeof attributes.href === "string" ? attributes.href : undefined
      chunks.push(
        ...inlineChunks(children, syntaxStyle, {
          ...addStyle(format, "markup.link"),
          ...(href === undefined ? {} : { href })
        })
      )
      continue
    }
    if (tag === "img") {
      if (typeof attributes.alt === "string")
        chunks.push(styledChunk(attributes.alt, syntaxStyle, format.styles, false))
      continue
    }
    if (tag === "footnote-ref") {
      const label = footnoteLabel(attributes)
      if (label) chunks.push(styledChunk(`[^${label}]`, syntaxStyle, [...format.styles, "markup.link"], false))
      continue
    }
    if (tag === "html") {
      const visible = stripHtml(textContent(children))
      if (visible) chunks.push(styledChunk(visible, syntaxStyle, format.styles, format.strikethrough, format.href))
      continue
    }
    chunks.push(...inlineChunks(children, syntaxStyle, format))
  }
  return chunks
}

function addStyle(format: InlineFormat, style: string): InlineFormat {
  return { ...format, styles: [...format.styles, style] }
}

function softBreaks(text: string): string {
  return text.replaceAll("\n", " ")
}

function styledChunk(
  text: string,
  syntaxStyle: SyntaxStyle,
  styles: readonly string[],
  strikethrough: boolean,
  href?: string
): TextChunk {
  const style = syntaxStyle.mergeStyles("default", ...styles)
  const attributes = style.attributes | (strikethrough ? TextAttributes.STRIKETHROUGH : 0)
  return {
    __isChunk: true,
    text,
    ...(style.fg === undefined ? {} : { fg: style.fg }),
    ...(style.bg === undefined ? {} : { bg: style.bg }),
    ...(attributes === TextAttributes.NONE ? {} : { attributes }),
    ...(href === undefined ? {} : { link: { url: href } })
  }
}

function plainChunk(text: string): TextChunk {
  return { __isChunk: true, text }
}

function blockTextChunks(
  nodes: readonly MarkdownNode[],
  syntaxStyle: SyntaxStyle,
  styles: readonly string[]
): TextChunk[] {
  const chunks: TextChunk[] = []
  for (const node of nodes) {
    if (chunks.length > 0) chunks.push(plainChunk("\n"))
    if (typeof node !== "string" && (node[0] === "ul" || node[0] === "ol")) {
      appendList(node, 0, chunks, syntaxStyle, styles)
    } else if (typeof node === "string") {
      chunks.push(styledChunk(softBreaks(node), syntaxStyle, styles, false))
    } else {
      chunks.push(...inlineChunks(elementChildren(node), syntaxStyle, { styles, strikethrough: false }))
    }
  }
  return chunks
}

function footnoteChunks(nodes: readonly MarkdownNode[], syntaxStyle: SyntaxStyle): TextChunk[] {
  const chunks: TextChunk[] = []
  for (const node of nodes) {
    if (!hasTag(node, "footnote")) continue
    if (chunks.length > 0) chunks.push(plainChunk("\n"))
    const label = footnoteLabel(node[1])
    if (label) {
      chunks.push(styledChunk(`[^${label}]`, syntaxStyle, ["markup.link"], false), plainChunk(": "))
    }
    chunks.push(...blockTextChunks(elementChildren(node), syntaxStyle, []))
  }
  return chunks
}

function footnoteLabel(attributes: MarkdownElement[1]): string | undefined {
  if (typeof attributes.label === "string") return attributes.label
  return typeof attributes.id === "number" ? String(attributes.id) : undefined
}

function appendList(
  list: MarkdownElement,
  depth: number,
  chunks: TextChunk[],
  syntaxStyle: SyntaxStyle,
  inheritedStyles: readonly string[]
): void {
  const ordered = list[0] === "ol"
  const start = typeof list[1].start === "number" ? list[1].start : 1
  const items: MarkdownElement[] = []
  for (const child of elementChildren(list)) {
    if (hasTag(child, "li")) items.push(child)
  }
  for (let index = 0; index < items.length; index++) {
    const item = items[index]!
    if (chunks.length > 0 && chunks.at(-1)?.text !== "\n") chunks.push(plainChunk("\n"))
    const task = item[1].task === true
    const marker = task ? (item[1].checked === true ? "☑" : "☐") : ordered ? `${start + index}.` : "•"
    chunks.push(plainChunk("  ".repeat(depth)))
    chunks.push(styledChunk(`${marker} `, syntaxStyle, [...inheritedStyles, "markup.list"], false))

    let hasContent = false
    for (const child of elementChildren(item)) {
      if (hasTag(child, "ul") || hasTag(child, "ol")) {
        chunks.push(plainChunk("\n"))
        appendList(child, depth + 1, chunks, syntaxStyle, inheritedStyles)
      } else {
        if (hasContent && isListItemBlock(child)) chunks.push(plainChunk(`\n${"  ".repeat(depth + 1)}`))
        const content = hasTag(child, "p") ? elementChildren(child) : [child]
        chunks.push(...inlineChunks(content, syntaxStyle, { styles: inheritedStyles, strikethrough: false }))
      }
      hasContent = true
    }
  }
}

function prefixLines(chunks: readonly TextChunk[], prefix: TextChunk): TextChunk[] {
  const result: TextChunk[] = [{ ...prefix }]
  for (const chunk of chunks) {
    const lines = chunk.text.split("\n")
    for (let index = 0; index < lines.length; index++) {
      if (index > 0) result.push(plainChunk("\n"), { ...prefix })
      const text = lines[index]!
      if (text) result.push({ ...chunk, text })
    }
  }
  return result
}

function tableContent(table: MarkdownElement, syntaxStyle: SyntaxStyle): TextTableContent {
  const rows: TextTableContent = []
  collectTableRows(table, rows, syntaxStyle)
  return rows
}

function collectTableRows(node: MarkdownNode, rows: TextTableContent, syntaxStyle: SyntaxStyle): void {
  if (typeof node === "string") return
  if (node[0] === "tr") {
    const row: TextChunk[][] = []
    for (const cell of elementChildren(node)) {
      if (!hasTag(cell, "th") && !hasTag(cell, "td")) continue
      const format: InlineFormat = { styles: cell[0] === "th" ? ["markup.strong"] : [], strikethrough: false }
      row.push(inlineChunks(elementChildren(cell), syntaxStyle, format))
    }
    rows.push(row)
    return
  }
  for (const child of elementChildren(node)) collectTableRows(child, rows, syntaxStyle)
}

function elementChildren([_tag, _attributes, ...children]: MarkdownElement): MarkdownNode[] {
  return children
}

function hasTag(node: MarkdownNode, tag: string): node is MarkdownElement {
  return typeof node !== "string" && node[0] === tag
}

function isListItemBlock(node: MarkdownNode): boolean {
  return typeof node !== "string" && (blockKind(node) !== "text" || node[1].block === true)
}

function textContent(nodes: readonly MarkdownNode[]): string {
  let text = ""
  for (const node of nodes) text += typeof node === "string" ? node : textContent(elementChildren(node))
  return text
}

function stripHtml(value: string): string {
  return value.replace(/<[^>]*>/g, "")
}

const maxMarkdownFallbackBytes = 256 * 1024
const fallbackEncoder = new TextEncoder()
const fallbackDecoder = new TextDecoder()

function fallbackBlock(source: string, reason: MarkdownParseFailure): ParsedMarkdownBlock {
  const candidate = source.slice(0, maxMarkdownFallbackBytes)
  const encoded = fallbackEncoder.encode(candidate)
  const clipped = encoded.subarray(0, maxMarkdownFallbackBytes)
  const visible = fallbackDecoder.decode(clipped)
  const omitted = candidate.length < source.length || clipped.byteLength < encoded.byteLength
  const explanation =
    reason === "source_limit"
      ? `Markdown exceeds the ${maxMarkdownSourceBytes / (1024 * 1024)} MiB rendering bound.`
      : "Markdown parsing failed."
  const content = `${visible}${visible ? "\n\n" : ""}[${explanation}${omitted ? " Additional source omitted." : ""}]`
  return { node: content, digest: new Bun.CryptoHasher("sha256").update(fallbackEncoder.encode(content)).digest() }
}

function sameDigest(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false
  for (let index = 0; index < left.byteLength; index++) {
    if (left[index] !== right[index]) return false
  }
  return true
}

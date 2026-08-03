import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export interface WebsiteBuildOptions {
  readonly rootDir?: string
  readonly docsDir?: string
  readonly outDir?: string
}

export interface WebsiteBuildResult {
  readonly outDir: string
  readonly pages: readonly string[]
}

interface ManualPage {
  readonly slug: string
  readonly title: string
  readonly order: number
  readonly sourcePath: string
  readonly markdownName: string
  readonly body: string
  readonly nodes: readonly MarkdownNode[]
}

type MarkdownNode =
  | { readonly type: "heading"; readonly level: number; readonly text: string }
  | { readonly type: "paragraph"; readonly text: string }
  | { readonly type: "code"; readonly language: string | undefined; readonly content: string }
  | { readonly type: "bullet_list"; readonly items: readonly string[] }
  | { readonly type: "ordered_list"; readonly items: readonly string[] }
  | { readonly type: "definition"; readonly term: string; readonly description: string }
  | { readonly type: "table"; readonly headers: readonly string[]; readonly rows: readonly (readonly string[])[] }

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDir, "..")
const defaultWebsiteRoot = join(repositoryRoot, "website")
const defaultDocsDir = join(repositoryRoot, "docs")
const defaultOutDir = join(repositoryRoot, "dist", "website")
const maxManualPages = 64
const maxWebsiteSourceBytes = 1024 * 1024

export async function buildWebsite(options: WebsiteBuildOptions = {}): Promise<WebsiteBuildResult> {
  const rootDir = resolve(options.rootDir ?? defaultWebsiteRoot)
  const docsDir = resolve(options.docsDir ?? defaultDocsDir)
  const outDir = resolve(options.outDir ?? defaultOutDir)
  await rm(outDir, { recursive: true, force: true })
  await mkdir(outDir, { recursive: true })

  await copyAssets(rootDir, outDir)
  await copyOptional(join(rootDir, "_redirects"), join(outDir, "_redirects"))
  await cp(join(dirname(docsDir), "examples"), join(outDir, "examples"), { recursive: true })
  await writeFile(join(outDir, "index.html"), renderHomePage())

  const pages = await loadManualPages(docsDir)
  const manDir = join(outDir, "man")
  await mkdir(manDir, { recursive: true })
  const written: string[] = ["index.html"]

  const pageWrites = pages.flatMap((page, index) => {
    const htmlName = page.slug === "intro" ? "index.html" : `${page.slug}.html`
    const markdownName = page.markdownName
    written.push(`man/${htmlName}`, `man/${markdownName}`)
    return [
      writeFile(join(manDir, htmlName), renderManualPage(pages, index)),
      readBoundedText(page.sourcePath).then(markdown => writeFile(join(manDir, markdownName), markdown))
    ]
  })
  await Promise.all(pageWrites)

  return { outDir, pages: Object.freeze(written) }
}

export function parseWebsiteBuildOptions(argv: readonly string[]): WebsiteBuildOptions {
  const options: { rootDir?: string; docsDir?: string; outDir?: string } = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === "--root-dir") {
      const value = argv[++i]
      if (!value) throw new Error("--root-dir requires a value")
      options.rootDir = value
    } else if (arg === "--docs-dir") {
      const value = argv[++i]
      if (!value) throw new Error("--docs-dir requires a value")
      options.docsDir = value
    } else if (arg === "--out-dir") {
      const value = argv[++i]
      if (!value) throw new Error("--out-dir requires a value")
      options.outDir = value
    } else {
      throw new Error(`Unknown website build argument: ${arg}`)
    }
  }
  return options
}

async function copyAssets(rootDir: string, outDir: string): Promise<void> {
  const assetsDir = join(rootDir, "assets")
  const entries = await readdir(assetsDir, { withFileTypes: true })
  await Promise.all(
    entries.map(entry => {
      const source = join(assetsDir, entry.name)
      const target = join(outDir, entry.name)
      return cp(source, target, { recursive: entry.isDirectory() })
    })
  )
}

async function copyOptional(source: string, target: string): Promise<void> {
  try {
    await cp(source, target)
  } catch (cause) {
    if (!isNodeError(cause) || cause.code !== "ENOENT") throw cause
  }
}

function isNodeError(cause: unknown): cause is Error & { readonly code?: string } {
  return cause instanceof Error && "code" in cause
}

async function loadManualPages(directory: string): Promise<readonly ManualPage[]> {
  const entries = (await readdir(directory, { withFileTypes: true }))
    .filter(entry => entry.isFile() && entry.name.endsWith(".md"))
    .map(entry => entry.name)
    .toSorted()
  if (entries.length === 0) throw new Error("Website manual requires at least one page")
  if (entries.length > maxManualPages) throw new Error(`Website manual cannot exceed ${maxManualPages} pages`)

  const pages = await Promise.all(
    entries.map(async markdownName => {
      const sourcePath = join(directory, markdownName)
      const source = await readBoundedText(sourcePath)
      const parsed = parseManualSource(source, sourcePath)
      return {
        slug: parsed.slug,
        title: parsed.title,
        order: parsed.order,
        body: parsed.body,
        sourcePath,
        markdownName,
        nodes: parseMarkdown(parsed.body)
      }
    })
  )
  const slugs = new Set<string>()
  for (const page of pages) {
    if (slugs.has(page.slug)) throw new Error(`Duplicate website manual slug: ${page.slug}`)
    slugs.add(page.slug)
  }
  return Object.freeze(pages.toSorted((left, right) => left.order - right.order || left.slug.localeCompare(right.slug)))
}

async function readBoundedText(path: string): Promise<string> {
  const content = await readFile(path, "utf8")
  if (Buffer.byteLength(content) > maxWebsiteSourceBytes) throw new Error(`Website source is too large: ${path}`)
  return content
}

function parseManualSource(source: string, path: string): Pick<ManualPage, "slug" | "title" | "order" | "body"> {
  const match = source.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/)
  if (!match) throw new Error(`Manual page is missing frontmatter: ${path}`)
  const frontmatter = parseFrontmatter(match[1] ?? "")
  const slug = stringField(frontmatter, "slug", path)
  if (!/^[a-z0-9-]+$/.test(slug)) throw new Error(`Invalid manual slug in ${path}`)
  const title = stringField(frontmatter, "title", path)
  const orderText = stringField(frontmatter, "order", path)
  if (!/^\d+$/.test(orderText)) throw new Error(`Invalid manual order in ${path}`)
  const order = Number(orderText)
  if (!Number.isSafeInteger(order)) throw new Error(`Invalid manual order in ${path}`)
  return { slug, title, order, body: match[2] ?? "" }
}

function parseFrontmatter(source: string): Map<string, string> {
  const fields = new Map<string, string>()
  for (const line of source.split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/)
    if (match) fields.set(match[1] ?? "", match[2] ?? "")
  }
  return fields
}

function stringField(fields: Map<string, string>, name: string, path: string): string {
  const value = fields.get(name)
  if (!value) throw new Error(`Manual page ${path} is missing ${name}`)
  return value
}

function parseMarkdown(source: string): readonly MarkdownNode[] {
  const lines = source.replace(/\r\n/g, "\n").split("\n")
  const nodes: MarkdownNode[] = []
  let i = 0

  while (i < lines.length) {
    if (lines[i]?.trim() === "") {
      i++
      continue
    }

    const line = lines[i] ?? ""
    const heading = line.match(/^(#{1,3})\s+(.+)$/)
    if (heading) {
      nodes.push({ type: "heading", level: heading[1]?.length ?? 1, text: heading[2] ?? "" })
      i++
      continue
    }

    const fence = line.match(/^```\s*([^`]*)$/)
    if (fence) {
      const content: string[] = []
      i++
      while (i < lines.length && !(lines[i] ?? "").startsWith("```")) content.push(lines[i++] ?? "")
      if (i < lines.length) i++
      const language = (fence[1] ?? "").trim() || undefined
      nodes.push({ type: "code", language, content: content.join("\n") })
      continue
    }

    if (isTableStart(lines, i)) {
      const headers = tableCells(line)
      const rows: string[][] = []
      i += 2
      while (i < lines.length && (lines[i] ?? "").trimStart().startsWith("|")) {
        const cells = tableCells(lines[i++] ?? "")
        if (cells.length !== headers.length) throw new Error("Website manual table rows must match their header")
        rows.push(cells)
      }
      nodes.push({ type: "table", headers, rows })
      continue
    }

    if (line.startsWith("- ")) {
      const items: string[] = []
      while (i < lines.length && (lines[i] ?? "").startsWith("- ")) items.push((lines[i++] ?? "").slice(2))
      nodes.push({ type: "bullet_list", items })
      continue
    }

    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^\d+\.\s+/.test(lines[i] ?? "")) {
        items.push((lines[i++] ?? "").replace(/^\d+\.\s+/, ""))
      }
      nodes.push({ type: "ordered_list", items })
      continue
    }

    if (isDefinitionStart(lines, i)) {
      const term = line
      const description = (lines[i + 1] ?? "").replace(/^:\s*/, "")
      nodes.push({ type: "definition", term, description })
      i += 2
      continue
    }

    const paragraph: string[] = []
    while (i < lines.length && !isBlockStart(lines, i)) paragraph.push(lines[i++] ?? "")
    nodes.push({ type: "paragraph", text: paragraph.join(" ") })
  }

  return Object.freeze(nodes)
}

function isBlockStart(lines: readonly string[], index: number): boolean {
  const line = lines[index] ?? ""
  return (
    line.trim() === "" ||
    /^(#{1,3})\s+/.test(line) ||
    line.startsWith("```") ||
    isTableStart(lines, index) ||
    line.startsWith("- ") ||
    /^\d+\.\s+/.test(line) ||
    isDefinitionStart(lines, index)
  )
}

function isTableStart(lines: readonly string[], index: number): boolean {
  const line = lines[index] ?? ""
  const separator = lines[index + 1] ?? ""
  if (!line.trimStart().startsWith("|") || !separator.trimStart().startsWith("|")) return false
  const headers = tableCells(line)
  const separators = tableCells(separator)
  return (
    headers.length > 0 && headers.length === separators.length && separators.every(cell => /^:?-{3,}:?$/.test(cell))
  )
}

function tableCells(line: string): string[] {
  const trimmed = line.trim()
  const body = trimmed.slice(trimmed.startsWith("|") ? 1 : 0, trimmed.endsWith("|") ? -1 : undefined)
  const cells: string[] = []
  let cell = ""
  let codeFence = 0

  for (let index = 0; index < body.length; index++) {
    const character = body[index] ?? ""
    if (character === "\\" && body[index + 1] === "|") {
      cell += "|"
      index++
      continue
    }
    if (character === "`") {
      let fenceLength = 1
      while (body[index + fenceLength] === "`") fenceLength++
      if (codeFence === 0) codeFence = fenceLength
      else if (codeFence === fenceLength) codeFence = 0
      cell += "`".repeat(fenceLength)
      index += fenceLength - 1
      continue
    }
    if (character === "|" && codeFence === 0) {
      cells.push(cell.trim())
      cell = ""
      continue
    }
    cell += character
  }

  cells.push(cell.trim())
  return cells
}

function isDefinitionStart(lines: readonly string[], index: number): boolean {
  const line = lines[index] ?? ""
  const next = lines[index + 1] ?? ""
  return line.length > 0 && !line.startsWith(" ") && /^:\s+/.test(next)
}

function renderHomePage(): string {
  return htmlPage({
    title: "zi",
    description: "Zi is a local-first coding agent that runs in your repo and keeps the work visible.",
    path: "/",
    body: `
<a class="skip-link" href="#content">skip to content</a>
<main id="content" class="home site-center stack" aria-labelledby="title">
  <pre class="logo" aria-hidden="true">░▀▀█░▀█▀
░▄▀░░░█░
░▀▀▀░▀▀▀</pre>
  <h1 class="title" id="title">A coding agent you can build with.</h1>
  <p class="lede">Zi runs in your repo, keeps the work visible, and ships as a native CLI.</p>
  <p class="lede"><code>npm install -g @with-zi/zi</code></p>
  <nav class="cluster" aria-label="links">
    <a href="/man/">manual</a>
    <a href="https://www.npmjs.com/package/@with-zi/zi">npm</a>
    <a href="https://github.com/igorsheg/zi" rel="me">github</a>
  </nav>
</main>`
  })
}

function renderManualPage(pages: readonly ManualPage[], index: number): string {
  const page = pages[index]
  if (!page) throw new Error(`Missing manual page at index ${index}`)
  const prev = pages[index - 1]
  const next = pages[index + 1]
  const pagePath = page.slug === "intro" ? "/man/" : `/man/${page.slug}.html`
  const markdownUrl = page.markdownName
  const content = page.nodes.map(node => renderNode(node, pages)).join("")
  const toc = page.nodes
    .filter(isTocHeading)
    .map(node => `<li><a href="#${slugify(node.text)}">${escapeHtml(inlineText(node.text))}</a></li>`)
    .join("\n")
  const pager = renderPager(prev, next)
  return htmlPage({
    title: `${page.title} — zi manual`,
    description: "Zi manual: a local coding agent you can build with.",
    path: pagePath,
    body: `
<a class="skip-link" href="#content">skip to content</a>
<main id="content" class="manual site-center">
  <nav class="site-nav cluster" aria-label="breadcrumb"><a href="/">withzi.dev</a><span>/</span><a href="/man/" aria-current="location">man</a></nav>
  <div class="manual-mast"><span aria-hidden="true">ZI(1)</span><span aria-hidden="true">${escapeHtml(page.title)}</span><span class="manual-view"><span aria-hidden="true">ZI(1)</span><a href="${markdownUrl}">md</a></span></div>
  <div class="manual-layout">
    <article class="manual-prose">
${content}${pager}
    </article>
    <aside class="manual-toc" aria-label="page contents"><p>on this page</p><ol>
${toc}
    </ol></aside>
  </div>
</main>`
  })
}

function isTocHeading(
  node: MarkdownNode
): node is Extract<MarkdownNode, { readonly type: "heading" }> & { readonly level: 2 | 3 } {
  return node.type === "heading" && node.level > 1
}

function renderNode(node: MarkdownNode, pages: readonly ManualPage[]): string {
  switch (node.type) {
    case "heading": {
      const tag = node.level === 1 ? "h1" : node.level === 2 ? "h2" : "h3"
      const id = slugify(node.text)
      return `<${tag} id="${id}"><a class="manual-anchor" href="#${id}">${renderInline(node.text, pages)}<span aria-hidden="true">#</span></a></${tag}>\n`
    }
    case "paragraph":
      return `<p>${renderInline(node.text, pages)}</p>\n`
    case "code": {
      const language = node.language ? safeToken(node.language) : undefined
      const caption = language ? `<figcaption>${escapeHtml(language)}</figcaption>` : ""
      const className = language ? ` class="language-${language}"` : ""
      return `<figure class="manual-code">${caption}<pre tabindex="0"><code${className}>${escapeHtml(node.content)}</code></pre></figure>\n`
    }
    case "bullet_list":
      return `<ul>\n${node.items.map(item => `  <li>${renderInline(item, pages)}</li>`).join("\n")}\n</ul>\n`
    case "ordered_list":
      return `<ol>\n${node.items.map(item => `  <li>${renderInline(item, pages)}</li>`).join("\n")}\n</ol>\n`
    case "definition":
      return `<dl>\n  <dt>${renderInline(node.term, pages)}</dt>\n  <dd>${renderInline(node.description, pages)}</dd>\n</dl>\n`
    case "table":
      return `<div class="manual-table" tabindex="0"><table>\n<thead><tr>${node.headers.map(cell => `<th scope="col">${renderInline(cell, pages)}</th>`).join("")}</tr></thead>\n<tbody>\n${node.rows.map(row => `<tr>${row.map(cell => `<td>${renderInline(cell, pages)}</td>`).join("")}</tr>`).join("\n")}\n</tbody>\n</table></div>\n`
  }
  return unexpectedNode(node)
}

function unexpectedNode(node: never): never {
  throw new Error(`Unexpected markdown node: ${String(node)}`)
}

function renderPager(prev: ManualPage | undefined, next: ManualPage | undefined): string {
  if (!prev && !next) return ""
  const prevLink = prev
    ? `<a class="manual-pager-prev" href="${manualHref(prev)}"><span>previous</span>${escapeHtml(prev.title)}</a>`
    : ""
  const nextLink = next
    ? `<a class="manual-pager-next" href="${manualHref(next)}"><span>next</span>${escapeHtml(next.title)}</a>`
    : ""
  return `<nav class="manual-pager" aria-label="manual pages">\n${prevLink}\n${nextLink}\n</nav>\n`
}

function manualHref(page: ManualPage): string {
  return page.slug === "intro" ? "index.html" : `${page.slug}.html`
}

function htmlPage(input: {
  readonly title: string
  readonly description: string
  readonly path: string
  readonly body: string
}): string {
  const url = `https://withzi.dev${input.path}`
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <meta name="theme-color" content="#050507">
  <meta name="description" content="${escapeHtml(input.description)}">
  <link rel="canonical" href="${url}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="zi">
  <meta property="og:title" content="${escapeHtml(input.title)}">
  <meta property="og:description" content="${escapeHtml(input.description)}">
  <meta property="og:url" content="${url}">
  <meta name="twitter:card" content="summary">
  <meta name="twitter:title" content="${escapeHtml(input.title)}">
  <meta name="twitter:description" content="${escapeHtml(input.description)}">
  <title>${escapeHtml(input.title)}</title>
  <link rel="icon" href="/favicon.ico" sizes="any">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <link rel="preload" href="/fonts/fragment-mono-400.ttf" as="font" type="font/ttf" crossorigin>
  <link rel="stylesheet" href="/style.css">
</head>
<body>${input.body}
</body>
</html>
`
}

function renderInline(source: string, pages: readonly ManualPage[]): string {
  let output = ""
  let i = 0
  while (i < source.length) {
    if (source[i] === "`") {
      const end = source.indexOf("`", i + 1)
      if (end !== -1) {
        output += `<code>${escapeHtml(source.slice(i + 1, end))}</code>`
        i = end + 1
        continue
      }
    }
    if (source.startsWith("**", i)) {
      const end = source.indexOf("**", i + 2)
      if (end !== -1) {
        output += `<strong>${escapeHtml(source.slice(i + 2, end))}</strong>`
        i = end + 2
        continue
      }
    }
    if (source[i] === "*") {
      const end = source.indexOf("*", i + 1)
      if (end !== -1) {
        output += `<em>${escapeHtml(source.slice(i + 1, end))}</em>`
        i = end + 1
        continue
      }
    }
    if (source[i] === "[") {
      const closeText = source.indexOf("](", i + 1)
      if (closeText !== -1) {
        const closeUrl = source.indexOf(")", closeText + 2)
        if (closeUrl !== -1) {
          const text = source.slice(i + 1, closeText)
          const url = manualLink(source.slice(closeText + 2, closeUrl), pages)
          output += `<a href="${escapeAttribute(url)}">${renderInline(text, pages)}</a>`
          i = closeUrl + 1
          continue
        }
      }
    }
    output += escapeHtml(source[i] ?? "")
    i++
  }
  return output
}

function manualLink(url: string, pages: readonly ManualPage[]): string {
  const fragmentStart = url.indexOf("#")
  const path = fragmentStart === -1 ? url : url.slice(0, fragmentStart)
  const fragment = fragmentStart === -1 ? "" : url.slice(fragmentStart)
  const page = pages.find(candidate => candidate.markdownName === path)
  return page ? `${manualHref(page)}${fragment}` : url
}

function inlineText(source: string): string {
  return source.replace(/[`*_]/g, "")
}

function slugify(source: string): string {
  const slug = inlineText(source)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  return slug || "section"
}

function safeToken(source: string): string {
  const token = source.toLowerCase().replace(/[^a-z0-9_-]/g, "")
  return token || "text"
}

function escapeHtml(source: string): string {
  return source.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
}

function escapeAttribute(source: string): string {
  if (/^https?:\/\//.test(source) || source.startsWith("/") || /^[a-z0-9._/#-]+$/i.test(source)) {
    return escapeHtml(source)
  }
  throw new Error(`Unsafe URL in website markdown: ${source}`)
}

if (import.meta.main) {
  try {
    const result = await buildWebsite(parseWebsiteBuildOptions(Bun.argv.slice(2)))
    console.log(`built website: ${result.outDir}`)
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    process.exit(1)
  }
}

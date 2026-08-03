import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"

import { publicProductDocumentationFiles } from "../packages/coding-agent/src/product-documentation.js"
import { buildWebsite, parseWebsiteBuildOptions } from "./build-website.js"

test("website options accept explicit source and output directories", () => {
  expect(parseWebsiteBuildOptions(["--root-dir", "site", "--docs-dir", "manual", "--out-dir", "public"])).toEqual({
    rootDir: "site",
    docsDir: "manual",
    outDir: "public"
  })
  expect(() => parseWebsiteBuildOptions(["--other"])).toThrow("Unknown website build argument")
  expect(() => parseWebsiteBuildOptions(["--docs-dir"])).toThrow("--docs-dir requires a value")
  expect(() => parseWebsiteBuildOptions(["--out-dir"])).toThrow("--out-dir requires a value")
})

test("website rejects ambiguous navigation and renders pipes inside table cells", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-website-validation-"))
  const rootDir = join(temporary, "website")
  const productRoot = join(temporary, "product")
  const docsDir = join(productRoot, "docs")
  const outDir = join(temporary, "out")
  try {
    await Promise.all([
      mkdir(join(rootDir, "assets"), { recursive: true }),
      mkdir(docsDir, { recursive: true }),
      mkdir(join(productRoot, "examples"), { recursive: true })
    ])
    await Promise.all([
      Bun.write(join(rootDir, "assets", "style.css"), "body {}"),
      Bun.write(
        join(docsDir, "index.md"),
        `---\nslug: intro\ntitle: Start\norder: 0\n---\n\n# Start\n\n| Value | Kind |\n| ----- | ---- |\n| \`foo | bar\` | code |\n| foo \\| bar | escaped |\n`
      )
    ])

    await buildWebsite({ rootDir, docsDir, outDir })
    const html = await readFile(join(outDir, "man", "index.html"), "utf8")
    expect(html).toContain("<td><code>foo | bar</code></td>")
    expect(html).toContain("<td>foo | bar</td>")

    await Bun.write(join(docsDir, "duplicate.md"), "---\nslug: intro\ntitle: Other\norder: 1\n---\n")
    const duplicate = buildWebsite({ rootDir, docsDir, outDir })
    await Promise.allSettled([duplicate])
    expect(duplicate).rejects.toThrow("Duplicate website manual slug: intro")

    await rm(join(docsDir, "duplicate.md"))
    await Bun.write(join(docsDir, "index.md"), "---\nslug: intro\ntitle: Start\norder: 10oops\n---\n")
    const invalidOrder = buildWebsite({ rootDir, docsDir, outDir })
    await Promise.allSettled([invalidOrder])
    expect(invalidOrder).rejects.toThrow("Invalid manual order")
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

test("website build emits static homepage, manual pages, markdown, and assets", async () => {
  const outDir = await mkdtemp(join(tmpdir(), "zi-website-"))
  try {
    const result = await buildWebsite({ rootDir: resolve("website"), outDir })
    expect(result.pages).toContain("index.html")
    expect(result.pages).toContain("man/index.html")
    expect(result.pages).toContain("man/cli.html")
    expect(result.pages).toContain("man/extensions.html")
    expect(result.pages).toContain("man/json-events.md")
    expect(result.pages).toContain("man/rpc.html")
    expect(result.pages.filter(path => path.startsWith("man/") && path.endsWith(".md")).toSorted()).toEqual(
      publicProductDocumentationFiles.map(file => `man/${file}`)
    )

    const index = await readFile(join(outDir, "index.html"), "utf8")
    expect(index).toContain("npm install -g @with-zi/zi")
    expect(index).toContain("https://github.com/igorsheg/zi")

    const cliMarkdown = await readFile(join(outDir, "man", "cli.md"), "utf8")
    expect(cliMarkdown).toBe(await readFile(resolve("docs", "cli.md"), "utf8"))

    const cli = await readFile(join(outDir, "man", "cli.html"), "utf8")
    expect(cli).toContain("--api-key")
    expect(cli).toContain("--mode rpc")
    expect(cli).toContain("<table>")
    expect(cli).toContain('href="rpc.html"')
    expect(cli).not.toContain("RPC mode is not available yet")

    const introduction = await readFile(join(outDir, "man", "index.html"), "utf8")
    expect(introduction).toContain('href="cli.html"')
    expect(introduction).not.toContain('href="cli.md"')

    const skills = await readFile(join(outDir, "man", "skills.html"), "utf8")
    expect(skills).toContain(
      '<a href="../examples/skills/review/SKILL.md"><code>examples/skills/review/SKILL.md</code></a>'
    )
    expect(existsSync(join(outDir, "examples", "skills", "review", "SKILL.md"))).toBe(true)
    expect(existsSync(join(outDir, "style.css"))).toBe(true)
    expect(existsSync(join(outDir, "fonts", "fragment-mono-400.ttf"))).toBe(true)
    expect(existsSync(join(outDir, "favicon.svg"))).toBe(true)

    const unresolvedLinks = (
      await Promise.all(
        result.pages
          .filter(path => path.endsWith(".html"))
          .map(async page => {
            const outputPath = join(outDir, page)
            const html = await readFile(outputPath, "utf8")
            const unresolved: string[] = []
            for (const match of html.matchAll(/href="([^"]+)"/g)) {
              const href = match[1] ?? ""
              if (!href || href.startsWith("#") || href.startsWith("/") || /^https?:\/\//.test(href)) continue
              const target = join(dirname(outputPath), href.split("#", 1)[0] ?? "")
              if (!existsSync(target)) unresolved.push(`${page} -> ${href}`)
            }
            return unresolved
          })
      )
    ).flat()
    expect(unresolvedLinks).toEqual([])
  } finally {
    await rm(outDir, { recursive: true, force: true })
  }
})

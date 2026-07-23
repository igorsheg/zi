import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { buildWebsite, parseWebsiteBuildOptions } from "./build-website.js"

test("website options accept explicit source and output directories", () => {
  expect(parseWebsiteBuildOptions(["--root-dir", "site", "--out-dir", "public"])).toEqual({
    rootDir: "site",
    outDir: "public"
  })
  expect(() => parseWebsiteBuildOptions(["--other"])).toThrow("Unknown website build argument")
  expect(() => parseWebsiteBuildOptions(["--out-dir"])).toThrow("--out-dir requires a value")
})

test("website build emits static homepage, manual pages, markdown, and assets", async () => {
  const outDir = await mkdtemp(join(tmpdir(), "zi-website-"))
  try {
    const result = await buildWebsite({ rootDir: resolve("website"), outDir })
    expect(result.pages).toContain("index.html")
    expect(result.pages).toContain("man/index.html")
    expect(result.pages).toContain("man/cli.html")
    expect(result.pages).toContain("man/json-events.md")

    const index = await readFile(join(outDir, "index.html"), "utf8")
    expect(index).toContain("npm install -g @with-zi/zi")
    expect(index).toContain("https://github.com/igorsheg/zi")

    const cli = await readFile(join(outDir, "man", "cli.html"), "utf8")
    expect(cli).toContain("--api-key")
    expect(cli).toContain("RPC mode is not available yet")
    expect(cli).not.toContain("zig build")

    expect(existsSync(join(outDir, "style.css"))).toBe(true)
    expect(existsSync(join(outDir, "fonts", "fragment-mono-400.ttf"))).toBe(true)
    expect(existsSync(join(outDir, "favicon.svg"))).toBe(true)
  } finally {
    await rm(outDir, { recursive: true, force: true })
  }
})

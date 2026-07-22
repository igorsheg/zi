import { expect, test } from "bun:test"
import { chmod, mkdtemp, rm } from "node:fs/promises"
import { join, resolve } from "node:path"

import { assertPinnedBunVersion, compileStandalone } from "./compile-zi.js"

test("standalone compilation requires the workspace-pinned Bun runtime", () => {
  expect(() => assertPinnedBunVersion("1.3.5", "bun@1.3.14")).toThrow("Zi builds require Bun 1.3.14; running 1.3.5")
  expect(() => assertPinnedBunVersion("1.3.14", "bun@1.3.14")).not.toThrow()
  expect(() => assertPinnedBunVersion("1.3.14", "npm@11.4.2")).toThrow("packageManager must pin Bun exactly")
})

test("the standalone bundle resolves OAuth and settles highlighted Markdown", async () => {
  const temporary = await mkdtemp(join(import.meta.dirname, ".compiled-standalone-"))
  const entrypoint = join(temporary, "smoke.ts")
  const executable = join(temporary, process.platform === "win32" ? "smoke.exe" : "smoke")
  const providers = Bun.resolveSync(
    "@earendil-works/pi-ai/providers/all",
    resolve(import.meta.dirname, "../packages/coding-agent/src")
  )
  const tuiSource = resolve(import.meta.dirname, "../packages/tui/src")
  const openTuiCore = Bun.resolveSync("@opentui/core", tuiSource)
  const openTuiTesting = Bun.resolveSync("@opentui/core/testing", tuiSource)
  const markdownFixture = [
    "## Release",
    "",
    "The **compiled** transcript keeps `inline` Markdown.",
    "",
    "```ts",
    "const answer: number = 42",
    "```"
  ].join("\n")
  try {
    await Bun.write(
      entrypoint,
      `
import { builtinModels } from ${JSON.stringify(providers)}
import {
  CodeRenderable,
  MarkdownRenderable,
  SyntaxStyle,
  destroyTreeSitterClient
} from ${JSON.stringify(openTuiCore)}
import { createTestRenderer } from ${JSON.stringify(openTuiTesting)}

const providerIds = ["anthropic", "github-copilot", "openai-codex"]
const credential = {
  type: "oauth",
  access: "compiled-oauth-access",
  refresh: "compiled-oauth-refresh",
  expires: Date.now() + 60_000
}
const credentials = {
  async read(providerId) {
    return providerIds.includes(providerId) ? credential : undefined
  },
  async modify() {
    return credential
  },
  async delete() {}
}
const models = builtinModels({ credentials })
for (const providerId of providerIds) {
  const model = models.getModels(providerId)[0]
  if (!model) throw new Error(\`Missing model for \${providerId}\`)
  const auth = await models.getAuth(model)
  if (auth?.auth.apiKey !== credential.access) throw new Error(\`OAuth derivation failed for \${providerId}\`)
}

const setup = await createTestRenderer({ width: 72, height: 12, useThread: false })
const syntaxStyle = SyntaxStyle.fromStyles({
  default: { fg: "#ffffff" },
  conceal: { fg: "#777777" },
  "markup.heading": { fg: "#ffff00", bold: true },
  "markup.heading.2": { fg: "#ffff00", bold: true },
  "markup.strong": { fg: "#ffffff", bold: true },
  "markup.raw": { fg: "#00ffff" },
  "markup.raw.block": { fg: "#aaaaaa" }
})
const markdown = new MarkdownRenderable(setup.renderer, {
  content: ${JSON.stringify(markdownFixture)},
  syntaxStyle,
  conceal: true,
  streaming: true,
  internalBlockMode: "top-level"
})
setup.renderer.root.add(markdown)

try {
  for (let attempt = 0; attempt < 20; attempt++) {
    await setup.renderOnce()
    const stack = [...markdown.getChildren()]
    const pending = []
    while (stack.length > 0) {
      const child = stack.pop()
      if (child instanceof CodeRenderable && child.isHighlighting) pending.push(child)
      stack.push(...child.getChildren())
    }
    if (pending.length === 0) break
    await Promise.all(pending.map(child => child.highlightingDone))
    if (attempt === 19) throw new Error("Compiled Markdown highlighting did not settle")
  }
  await setup.renderOnce()
  const frame = setup.captureCharFrame()
  for (const expected of ["Release", "The compiled transcript keeps inline Markdown.", "const answer: number = 42"]) {
    if (!frame.includes(expected)) throw new Error(\`Compiled Markdown omitted: \${expected}\`)
  }
  for (const sourceMarker of ["## Release", "**compiled**", "\`inline\`", "\`\`\`"]) {
    if (frame.includes(sourceMarker)) throw new Error(\`Compiled Markdown exposed source markup: \${sourceMarker}\`)
  }
} finally {
  if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  syntaxStyle.destroy()
  await destroyTreeSitterClient()
}
`
    )
    await compileStandalone(entrypoint, executable)
    if (process.platform !== "win32") await chmod(executable, 0o755)
    const child = Bun.spawn([executable], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])

    expect({ exitCode, stdout, stderr }).toEqual({ exitCode: 0, stdout: "", stderr: "" })
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}, 60_000)

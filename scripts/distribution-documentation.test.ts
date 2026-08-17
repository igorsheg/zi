import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, readdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { assertDistributionDocumentation, copyDistributionDocumentation } from "./distribution-documentation.js"

test("distribution documentation ships self-customization guides and examples", async () => {
  const destination = await mkdtemp(join(tmpdir(), "zi-distribution-documentation-"))
  try {
    await mkdir(join(destination, "docs"))
    await Bun.write(join(destination, "docs", "stale.md"), "stale")
    await copyDistributionDocumentation(resolve(import.meta.dirname, ".."), destination)
    await assertDistributionDocumentation(destination)

    expect(existsSync(join(destination, "LICENSE"))).toBe(true)
    expect(existsSync(join(destination, "THIRD_PARTY_NOTICES.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "stale.md"))).toBe(false)
    expect((await readdir(join(destination, "docs"))).toSorted()).toEqual([
      "authentication.md",
      "cli.md",
      "code-mode.md",
      "extensions.md",
      "index.md",
      "json-events.md",
      "mcp.md",
      "notifications.md",
      "prompts.md",
      "resources.md",
      "rpc.md",
      "settings.md",
      "skills.md",
      "subagents.md",
      "vocabulary.md",
      "work-plans.md"
    ])
    expect(existsSync(join(destination, "docs", "index.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "code-mode.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "extensions.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "mcp.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "notifications.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "prompts.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "skills.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "subagents.md"))).toBe(true)
    expect(existsSync(join(destination, "docs", "work-plans.md"))).toBe(true)
    expect(existsSync(join(destination, "examples", "extensions", "custom-tool", "index.ts"))).toBe(true)
    expect(existsSync(join(destination, "examples", "extensions", "durable-counter", "index.ts"))).toBe(true)
    expect(existsSync(join(destination, "examples", "extensions", "herdr-agent-state", "index.ts"))).toBe(true)
    expect(existsSync(join(destination, "examples", "extensions", "subagents", "index.ts"))).toBe(true)
    expect(existsSync(join(destination, "examples", "rpc", "client.ts"))).toBe(true)
    expect(existsSync(join(destination, "examples", "skills", "review", "SKILL.md"))).toBe(true)
  } finally {
    await rm(destination, { recursive: true, force: true })
  }
})

test("distribution documentation rejects a missing routed example", async () => {
  const destination = await mkdtemp(join(tmpdir(), "zi-distribution-documentation-incomplete-"))
  try {
    await copyDistributionDocumentation(resolve(import.meta.dirname, ".."), destination)
    await rm(join(destination, "examples", "rpc", "client.ts"))

    const assertion = assertDistributionDocumentation(destination)
    await Promise.allSettled([assertion])
    expect(assertion).rejects.toThrow()
  } finally {
    await rm(destination, { recursive: true, force: true })
  }
})

test("distribution documentation rejects internal material", async () => {
  const destination = await mkdtemp(join(tmpdir(), "zi-distribution-documentation-internal-"))
  try {
    await copyDistributionDocumentation(resolve(import.meta.dirname, ".."), destination)
    await Bun.write(join(destination, "docs", "roadmap.md"), "internal")

    const assertion = assertDistributionDocumentation(destination)
    await Promise.allSettled([assertion])
    expect(assertion).rejects.toThrow("Zi distribution docs must contain only public consumer guides")
  } finally {
    await rm(destination, { recursive: true, force: true })
  }
})

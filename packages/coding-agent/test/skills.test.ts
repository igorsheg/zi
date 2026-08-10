import { expect, test } from "bun:test"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { buildSkillPromptCatalog, expandSkillCommand, formatSkillsForPrompt, type Skill } from "../src/skills.js"

const skill = (overrides: Partial<Skill> = {}): Skill => ({
  name: "pdf-tools",
  description: "Work with <PDF> files & forms",
  filePath: "/skills/pdf/SKILL.md",
  baseDir: "/skills/pdf",
  scope: "global",
  disableModelInvocation: false,
  ...overrides
})

test("skill metadata uses progressive disclosure and XML escaping", () => {
  const prompt = formatSkillsForPrompt([skill(), skill({ name: "manual", disableModelInvocation: true })])

  expect(prompt).toContain("<name>pdf-tools</name>")
  expect(prompt).toContain("Work with &lt;PDF&gt; files &amp; forms")
  expect(prompt).toContain("/skills/pdf/SKILL.md")
  expect(prompt).not.toContain("<name>manual</name>")
  expect(prompt).not.toContain("Skill body")
  expect(formatSkillsForPrompt([skill()], "code")).toContain("Use zi.read from a code cell")
})

test("skill catalog reports included skills and UTF-8 size without omitting entries", () => {
  const skills = [
    skill({ description: "Work with café PDFs" }),
    skill({ name: "manual", disableModelInvocation: true })
  ]
  const catalog = buildSkillPromptCatalog(skills)

  expect(Object.isFrozen(catalog)).toBe(true)
  expect(catalog.includedCount).toBe(1)
  expect(catalog.omittedCount).toBe(0)
  expect(catalog.utf8Bytes).toBe(Buffer.byteLength(catalog.text))
  expect(catalog.utf8Bytes).toBeGreaterThan(catalog.text.length)
  expect(formatSkillsForPrompt(skills)).toBe(catalog.text)

  const emptyCatalog = buildSkillPromptCatalog([skill({ disableModelInvocation: true })])
  expect(Object.isFrozen(emptyCatalog)).toBe(true)
  expect(emptyCatalog).toEqual({ text: "", includedCount: 0, omittedCount: 0, utf8Bytes: 0 })
})

test("explicit skill commands read current bounded content and append arguments", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-skill-command-"))
  const filePath = join(root, "SKILL.md")
  await writeFile(filePath, "---\nname: live\ndescription: Live skill\n---\n# First\n\nUse the first version.")
  const live = skill({ name: "live", filePath, baseDir: root })

  expect(expandSkillCommand("/skill:live explain", [live])).toContain("Use the first version.\n</skill>\n\nexplain")
  await writeFile(filePath, "---\nname: live\ndescription: Live skill\n---\n# Second\n\nUse the edited version.")
  expect(expandSkillCommand("/skill:live", [live])).toContain("Use the edited version.")
  expect(expandSkillCommand("/skill:unknown", [live])).toBe("/skill:unknown")

  await rm(filePath)
  expect(() => expandSkillCommand("/skill:live", [live])).toThrow()
  await rm(root, { recursive: true })
})

import { basename, dirname, join } from "node:path"

import { parseFrontmatter, stripFrontmatter } from "./frontmatter.js"
import { type ResourceDiagnostics, type ResourceScope } from "./resource-diagnostics.js"
import {
  canonicalResourcePath,
  maxResourceDirectoryEntries,
  readResourceDirectory,
  readResourceFile,
  type SessionResourceBudget,
  resourcePathType,
  ResourceFileLimitError
} from "./resource-files.js"
import { ResourceIgnore } from "./resource-ignore.js"

export const maxSkillCount = 256
export const maxSkillDirectoryCount = 4096
export const maxSkillNameLength = 64
export const maxSkillDescriptionLength = 1024

export interface Skill {
  readonly name: string
  readonly description: string
  readonly filePath: string
  readonly baseDir: string
  readonly scope: ResourceScope
  readonly disableModelInvocation: boolean
}

export interface SkillRoot {
  readonly path: string
  readonly scope: ResourceScope
}

export function loadSkills(
  roots: readonly SkillRoot[],
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): readonly Skill[] {
  const skills = new Map<string, Skill>()
  const files = new Set<string>()
  const directories = new Set<string>()
  let directoryLimitReported = false
  let skillLimitReported = false
  let skillLimitReached = false

  const addSkill = (filePath: string, scope: ResourceScope): void => {
    const canonical = canonicalResourcePath(filePath)
    if (files.has(canonical)) return
    files.add(canonical)

    const skill = loadSkill(filePath, scope, diagnostics)
    if (!skill) return
    const winner = skills.get(skill.name)
    if (winner) {
      diagnostics.add({
        type: "collision",
        resource: "skill",
        name: skill.name,
        winnerPath: winner.filePath,
        loserPath: skill.filePath
      })
      return
    }
    if (skills.size === maxSkillCount) {
      if (!skillLimitReported) {
        skillLimitReported = true
        diagnostics.add({
          type: "limit",
          resource: "skill",
          limit: maxSkillCount,
          path: filePath,
          message: `At most ${maxSkillCount} skills can be loaded`
        })
      }
      skillLimitReached = true
      return
    }

    const bytes = Buffer.byteLength(skill.name) + Buffer.byteLength(skill.description)
    if (!budget.retain(bytes)) {
      diagnostics.add({
        type: "limit",
        resource: "skill",
        limit: budget.limit,
        path: skill.filePath,
        message: `Session resources cannot retain more than ${budget.limit} bytes`
      })
      return
    }
    skills.set(skill.name, skill)
  }

  const scan = (directory: string, scope: ResourceScope, includeRootFiles: boolean, ignored: ResourceIgnore): void => {
    if (skillLimitReached) return
    const canonical = canonicalResourcePath(directory)
    if (directories.has(canonical)) return
    if (directories.size === maxSkillDirectoryCount) {
      if (!directoryLimitReported) {
        directoryLimitReported = true
        diagnostics.add({
          type: "limit",
          resource: "skill",
          limit: maxSkillDirectoryCount,
          path: directory,
          message: `Skill discovery can visit at most ${maxSkillDirectoryCount} directories`
        })
      }
      return
    }
    directories.add(canonical)
    ignored.enter(directory)

    const rootSkillPath = join(directory, "SKILL.md")
    if (resourcePathType(rootSkillPath) === "file" && !ignored.ignores(rootSkillPath)) {
      addSkill(rootSkillPath, scope)
      return
    }

    let entries: ReturnType<typeof readResourceDirectory>
    try {
      entries = readResourceDirectory(directory)
    } catch (cause) {
      diagnostics.add({ type: "warning", resource: "skill", path: directory, message: errorMessage(cause) })
      return
    }
    if (entries.truncated) {
      diagnostics.add({
        type: "limit",
        resource: "skill",
        limit: maxResourceDirectoryEntries,
        path: directory,
        message: `Resource directories are limited to ${maxResourceDirectoryEntries} entries`
      })
    }

    for (const entry of entries.entries) {
      if (skillLimitReached) return
      if (entry.name.startsWith(".") || entry.name === "node_modules") continue
      const path = join(directory, entry.name)
      const type = resourcePathType(path)
      if (!type || ignored.ignores(path, type === "directory")) continue
      if (type === "directory") {
        scan(path, scope, false, ignored)
      } else if (includeRootFiles && entry.name.endsWith(".md")) {
        addSkill(path, scope)
      }
    }
  }

  for (const root of roots) {
    if (skillLimitReached) break
    if (resourcePathType(root.path) !== "directory") continue
    scan(root.path, root.scope, true, new ResourceIgnore(root.path))
  }
  return [...skills.values()]
}

export function formatSkillsForPrompt(skills: readonly Skill[]): string {
  const visible = skills.filter(skill => !skill.disableModelInvocation)
  if (visible.length === 0) return ""

  const lines = [
    "The following skills provide specialized instructions for specific tasks.",
    "Use the read tool to load a skill's file when the task matches its description.",
    "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
    "",
    "<available_skills>"
  ]
  for (const skill of visible) {
    lines.push("  <skill>")
    lines.push(`    <name>${escapeXml(skill.name)}</name>`)
    lines.push(`    <description>${escapeXml(skill.description)}</description>`)
    lines.push(`    <location>${escapeXml(skill.filePath)}</location>`)
    lines.push("  </skill>")
  }
  lines.push("</available_skills>")
  return lines.join("\n")
}

export function expandSkillCommand(text: string, skills: readonly Skill[]): string {
  if (!text.startsWith("/skill:")) return text
  const separator = text.indexOf(" ")
  const name = separator < 0 ? text.slice(7) : text.slice(7, separator)
  const skill = skills.find(candidate => candidate.name === name)
  if (!skill) return text

  const body = stripFrontmatter(readResourceFile(skill.filePath)).trim()
  const block = `<skill name="${escapeXml(skill.name)}" location="${escapeXml(skill.filePath)}">\nReferences are relative to ${escapeXml(skill.baseDir)}.\n\n${body}\n</skill>`
  if (separator < 0) return block
  const argumentsText = text.slice(separator + 1).trim()
  return argumentsText.length === 0 ? block : `${block}\n\n${argumentsText}`
}

function loadSkill(filePath: string, scope: ResourceScope, diagnostics: ResourceDiagnostics): Skill | undefined {
  try {
    const { frontmatter } = parseFrontmatter(readResourceFile(filePath))
    const description = frontmatter.description
    if (typeof description !== "string" || description.trim().length === 0) {
      diagnostics.add({ type: "warning", resource: "skill", path: filePath, message: "description is required" })
      return undefined
    }

    const configuredName = frontmatter.name
    if (configuredName !== undefined && typeof configuredName !== "string") {
      diagnostics.add({ type: "warning", resource: "skill", path: filePath, message: "name must be a string" })
      return undefined
    }
    const name = configuredName || basename(dirname(filePath))
    for (const message of validateSkillName(name)) {
      diagnostics.add({ type: "warning", resource: "skill", path: filePath, message })
    }
    if (description.length > maxSkillDescriptionLength) {
      diagnostics.add({
        type: "warning",
        resource: "skill",
        path: filePath,
        message: `description exceeds ${maxSkillDescriptionLength} characters (${description.length})`
      })
    }

    return {
      name,
      description,
      filePath,
      baseDir: dirname(filePath),
      scope,
      disableModelInvocation: frontmatter["disable-model-invocation"] === true
    }
  } catch (cause) {
    if (cause instanceof ResourceFileLimitError) {
      diagnostics.add({ type: "limit", resource: "skill", limit: cause.limit, path: filePath, message: cause.message })
    } else {
      diagnostics.add({ type: "warning", resource: "skill", path: filePath, message: errorMessage(cause) })
    }
    return undefined
  }
}

function validateSkillName(name: string): readonly string[] {
  const messages: string[] = []
  if (name.length > maxSkillNameLength) {
    messages.push(`name exceeds ${maxSkillNameLength} characters (${name.length})`)
  }
  if (!/^[a-z0-9-]+$/.test(name)) {
    messages.push("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)")
  }
  if (name.startsWith("-") || name.endsWith("-")) messages.push("name must not start or end with a hyphen")
  if (name.includes("--")) messages.push("name must not contain consecutive hyphens")
  return messages
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;")
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

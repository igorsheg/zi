import { basename, join } from "node:path"

import type { ExtensionSubagentProfile, ExtensionThinkingLevel } from "@with-zi/extension-api"

import { parseFrontmatter } from "./frontmatter.js"
import { type ResourceDiagnostics, type ResourceScope } from "./resource-diagnostics.js"
import {
  canonicalResourcePath,
  maxResourceDirectoryEntries,
  readResourceDirectory,
  readResourceFile,
  resourcePathType,
  ResourceFileLimitError,
  type SessionResourceBudget
} from "./resource-files.js"
import { ResourceIgnore } from "./resource-ignore.js"

export const maxSubagentProfiles = 64
export const maxSubagentProfileNameBytes = 64
export const maxSubagentProfileDescriptionBytes = 4 * 1024
export const maxSubagentProfileInstructionsBytes = 8 * 1024
export const maxSubagentProfileModelBytes = 4 * 1024

export interface SubagentProfile extends ExtensionSubagentProfile {
  readonly filePath: string
  readonly scope: ResourceScope
}

export interface SubagentProfileRoot {
  readonly path: string
  readonly scope: ResourceScope
}

export function loadSubagentProfiles(
  roots: readonly SubagentProfileRoot[],
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): readonly SubagentProfile[] {
  const profiles = new Map<string, SubagentProfile>()
  const files = new Set<string>()
  let limitReported = false

  for (const root of roots) {
    if (resourcePathType(root.path) !== "directory") continue
    let directory: ReturnType<typeof readResourceDirectory>
    try {
      directory = readResourceDirectory(root.path)
    } catch (cause) {
      diagnostics.add({ type: "warning", resource: "subagent-profile", path: root.path, message: errorMessage(cause) })
      continue
    }
    if (directory.truncated) {
      diagnostics.add({
        type: "limit",
        resource: "subagent-profile",
        limit: maxResourceDirectoryEntries,
        path: root.path,
        message: `Resource directories are limited to ${maxResourceDirectoryEntries} entries`
      })
    }

    const ignored = new ResourceIgnore(root.path)
    ignored.enter(root.path)
    for (const entry of directory.entries) {
      if (entry.name.startsWith(".") || !entry.name.endsWith(".md")) continue
      const filePath = join(root.path, entry.name)
      if (resourcePathType(filePath) !== "file" || ignored.ignores(filePath)) continue
      const canonical = canonicalResourcePath(filePath)
      if (files.has(canonical)) continue
      files.add(canonical)
      const loaded = loadSubagentProfile(filePath, root.scope, diagnostics)
      if (!loaded) continue
      const winner = profiles.get(loaded.profile.name)
      if (winner) {
        diagnostics.add({
          type: "collision",
          resource: "subagent-profile",
          name: loaded.profile.name,
          winnerPath: winner.filePath,
          loserPath: loaded.profile.filePath
        })
        continue
      }
      if (profiles.size === maxSubagentProfiles) {
        if (!limitReported) {
          limitReported = true
          diagnostics.add({
            type: "limit",
            resource: "subagent-profile",
            limit: maxSubagentProfiles,
            path: filePath,
            message: `At most ${maxSubagentProfiles} subagent profiles can be loaded`
          })
        }
        break
      }
      if (!budget.retain(loaded.bytes)) {
        diagnostics.add({
          type: "limit",
          resource: "subagent-profile",
          limit: budget.limit,
          path: filePath,
          message: `Session resources cannot retain more than ${budget.limit} bytes`
        })
        continue
      }
      profiles.set(loaded.profile.name, loaded.profile)
    }
  }
  return [...profiles.values()]
}

function loadSubagentProfile(
  filePath: string,
  scope: ResourceScope,
  diagnostics: ResourceDiagnostics
): { readonly profile: SubagentProfile; readonly bytes: number } | undefined {
  try {
    const content = readResourceFile(filePath)
    const parsed = parseFrontmatter(content)
    const name = basename(filePath).replace(/\.md$/, "")
    const description = parsed.frontmatter.description
    const model = parsed.frontmatter.model
    const thinking = parsed.frontmatter.thinking
    const admitted = admitProfile(name, description, parsed.body, model, thinking)
    if (typeof admitted === "string") {
      diagnostics.add({ type: "warning", resource: "subagent-profile", path: filePath, message: admitted })
      return undefined
    }
    const profile: SubagentProfile = { ...admitted, filePath, scope }
    return { profile: Object.freeze(profile), bytes: Buffer.byteLength(content) }
  } catch (cause) {
    if (cause instanceof ResourceFileLimitError) {
      diagnostics.add({
        type: "limit",
        resource: "subagent-profile",
        limit: cause.limit,
        path: filePath,
        message: cause.message
      })
    } else {
      diagnostics.add({ type: "warning", resource: "subagent-profile", path: filePath, message: errorMessage(cause) })
    }
    return undefined
  }
}

function admitProfile(
  name: string,
  description: unknown,
  instructions: string,
  model: unknown,
  thinking: unknown
): ExtensionSubagentProfile | string {
  if (!/^[a-z][a-z0-9_-]*$/.test(name) || Buffer.byteLength(name) > maxSubagentProfileNameBytes) {
    return "filename must be a bounded lowercase subagent profile name"
  }
  if (
    typeof description !== "string" ||
    description.trim().length === 0 ||
    Buffer.byteLength(description) > maxSubagentProfileDescriptionBytes
  ) {
    return `description must be a non-empty string of at most ${maxSubagentProfileDescriptionBytes} bytes`
  }
  if (instructions.trim().length === 0) return "profile instructions cannot be empty"
  if (Buffer.byteLength(instructions) > maxSubagentProfileInstructionsBytes) {
    return `profile instructions cannot exceed ${maxSubagentProfileInstructionsBytes} bytes`
  }
  if (
    model !== undefined &&
    (typeof model !== "string" || model.trim().length === 0 || Buffer.byteLength(model) > maxSubagentProfileModelBytes)
  ) {
    return `model must be a non-empty string of at most ${maxSubagentProfileModelBytes} bytes`
  }
  if (thinking !== undefined && !isThinkingLevel(thinking)) return "thinking must be a supported thinking level"
  return Object.freeze({
    name,
    description,
    instructions,
    ...(model === undefined ? {} : { model }),
    ...(thinking === undefined ? {} : { thinking })
  })
}

function isThinkingLevel(value: unknown): value is ExtensionThinkingLevel {
  return (
    value === "off" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh" ||
    value === "max"
  )
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

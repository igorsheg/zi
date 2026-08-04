import { basename, join } from "node:path"

import { parseFrontmatter } from "./frontmatter.js"
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

export const maxPromptTemplateCount = 256

export interface PromptTemplate {
  readonly name: string
  readonly description: string
  readonly argumentHint?: string
  readonly content: string
  readonly filePath: string
  readonly scope: ResourceScope
}

export interface PromptTemplateRoot {
  readonly path: string
  readonly scope: ResourceScope
}

export function loadPromptTemplates(
  roots: readonly PromptTemplateRoot[],
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): readonly PromptTemplate[] {
  const templates = new Map<string, PromptTemplate>()
  const files = new Set<string>()
  let limitReported = false
  let limitReached = false

  const addTemplate = (filePath: string, scope: ResourceScope): void => {
    const canonical = canonicalResourcePath(filePath)
    if (files.has(canonical)) return
    files.add(canonical)

    const loaded = loadPromptTemplate(filePath, scope, diagnostics)
    if (!loaded) return
    const winner = templates.get(loaded.template.name)
    if (winner) {
      diagnostics.add({
        type: "collision",
        resource: "prompt-template",
        name: loaded.template.name,
        winnerPath: winner.filePath,
        loserPath: loaded.template.filePath
      })
      return
    }
    if (templates.size === maxPromptTemplateCount) {
      if (!limitReported) {
        limitReported = true
        diagnostics.add({
          type: "limit",
          resource: "prompt-template",
          limit: maxPromptTemplateCount,
          path: filePath,
          message: `At most ${maxPromptTemplateCount} prompt templates can be loaded`
        })
      }
      limitReached = true
      return
    }
    if (!budget.retain(loaded.bytes)) {
      diagnostics.add({
        type: "limit",
        resource: "prompt-template",
        limit: budget.limit,
        path: filePath,
        message: `Session resources cannot retain more than ${budget.limit} bytes`
      })
      return
    }
    templates.set(loaded.template.name, loaded.template)
  }

  for (const root of roots) {
    if (limitReached) break
    const type = resourcePathType(root.path)
    if (type === "file") {
      if (root.path.endsWith(".md")) addTemplate(root.path, root.scope)
      continue
    }
    if (type !== "directory") continue

    let directory: ReturnType<typeof readResourceDirectory>
    try {
      directory = readResourceDirectory(root.path)
    } catch (cause) {
      diagnostics.add({ type: "warning", resource: "prompt-template", path: root.path, message: errorMessage(cause) })
      continue
    }
    if (directory.truncated) {
      diagnostics.add({
        type: "limit",
        resource: "prompt-template",
        limit: maxResourceDirectoryEntries,
        path: root.path,
        message: `Resource directories are limited to ${maxResourceDirectoryEntries} entries`
      })
    }

    const ignored = new ResourceIgnore(root.path)
    ignored.enter(root.path)
    for (const entry of directory.entries) {
      if (limitReached) break
      if (entry.name.startsWith(".") || !entry.name.endsWith(".md")) continue
      const filePath = join(root.path, entry.name)
      if (resourcePathType(filePath) !== "file" || ignored.ignores(filePath)) continue
      addTemplate(filePath, root.scope)
    }
  }
  return [...templates.values()]
}

export function parseCommandArgs(input: string): readonly string[] {
  const argumentsList: string[] = []
  let current = ""
  let quote: string | undefined
  for (const character of input) {
    if (quote) {
      if (character === quote) quote = undefined
      else current += character
    } else if (character === '"' || character === "'") {
      quote = character
    } else if (/\s/.test(character)) {
      if (current.length > 0) {
        argumentsList.push(current)
        current = ""
      }
    } else {
      current += character
    }
  }
  if (current.length > 0) argumentsList.push(current)
  return argumentsList
}

export function substitutePromptArguments(content: string, argumentsList: readonly string[]): string {
  const all = argumentsList.join(" ")
  return content.replace(
    /\$\{(\d+):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/g,
    (_match, defaultNumber, defaultValue, sliceStart, sliceLength, simple: string | undefined) => {
      if (defaultNumber) {
        const value = argumentsList[Number.parseInt(defaultNumber, 10) - 1]
        return value || defaultValue
      }
      if (sliceStart) {
        const start = Math.max(0, Number.parseInt(sliceStart, 10) - 1)
        if (sliceLength) {
          return argumentsList.slice(start, start + Number.parseInt(sliceLength, 10)).join(" ")
        }
        return argumentsList.slice(start).join(" ")
      }
      if (simple === "ARGUMENTS" || simple === "@") return all
      return argumentsList[Number.parseInt(simple ?? "0", 10) - 1] ?? ""
    }
  )
}

export function expandPromptTemplate(text: string, templates: readonly PromptTemplate[]): string {
  if (!text.startsWith("/")) return text
  const match = text.match(/^\/([^\s]+)(?:\s+([\s\S]*))?$/)
  if (!match) return text
  const name = match[1]
  const template = templates.find(candidate => candidate.name === name)
  if (!template) return text
  return substitutePromptArguments(template.content, parseCommandArgs(match[2] ?? ""))
}

function loadPromptTemplate(
  filePath: string,
  scope: ResourceScope,
  diagnostics: ResourceDiagnostics
): { readonly template: PromptTemplate; readonly bytes: number } | undefined {
  try {
    const content = readResourceFile(filePath)
    const parsed = parseFrontmatter(content)
    const configuredDescription = parsed.frontmatter.description
    if (configuredDescription !== undefined && typeof configuredDescription !== "string") {
      diagnostics.add({
        type: "warning",
        resource: "prompt-template",
        path: filePath,
        message: "description must be a string"
      })
    }
    const argumentHint = parsed.frontmatter["argument-hint"]
    if (argumentHint !== undefined && typeof argumentHint !== "string") {
      diagnostics.add({
        type: "warning",
        resource: "prompt-template",
        path: filePath,
        message: "argument-hint must be a string"
      })
    }

    const description =
      typeof configuredDescription === "string" && configuredDescription.length > 0
        ? configuredDescription
        : templateDescription(parsed.body)
    const template: PromptTemplate = {
      name: basename(filePath).replace(/\.md$/, ""),
      description,
      ...(typeof argumentHint === "string" && argumentHint.length > 0 ? { argumentHint } : {}),
      content: parsed.body,
      filePath,
      scope
    }
    return { template, bytes: Buffer.byteLength(content) }
  } catch (cause) {
    if (cause instanceof ResourceFileLimitError) {
      diagnostics.add({
        type: "limit",
        resource: "prompt-template",
        limit: cause.limit,
        path: filePath,
        message: cause.message
      })
    } else {
      diagnostics.add({ type: "warning", resource: "prompt-template", path: filePath, message: errorMessage(cause) })
    }
    return undefined
  }
}

function templateDescription(body: string): string {
  const firstLine = body.split("\n").find(line => line.trim())
  if (!firstLine) return ""
  return firstLine.length > 60 ? `${firstLine.slice(0, 60)}...` : firstLine
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

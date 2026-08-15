import type { AgentTool } from "@earendil-works/pi-agent-core"

import { codeModeDoctrine } from "./code-mode/prompt.js"
import { getProductDocumentationPaths } from "./product-documentation.js"
import type { SessionResources } from "./resource-loader.js"
import { buildSkillPromptCatalog } from "./skills.js"
import { peerMessagingDoctrine } from "./subagents/peer.js"
import type { ToolSurface } from "./tool-surface.js"

// Regression budget for Zi-authored sections; loaded resources and caller-provided paths are measured separately.
export const maxCoreSystemPromptRegressionBytes = 4096

type SystemPromptSectionMetadata =
  | { readonly kind: "base"; readonly source: "default" | "custom" }
  | { readonly kind: "code-mode"; readonly surface: ToolSurface }
  | { readonly kind: "work-plan" }
  | { readonly kind: "peer-subagents" }
  | { readonly kind: "product-documentation" }
  | { readonly kind: "appended-instructions"; readonly index: number }
  | { readonly kind: "project-instructions"; readonly files: readonly string[] }
  | { readonly kind: "skills"; readonly includedCount: number; readonly omittedCount: number }
  | { readonly kind: "environment" }

export type SystemPromptSection = SystemPromptSectionMetadata & {
  readonly start: number
  readonly end: number
  readonly utf8Bytes: number
}

export interface SystemPromptCapabilities {
  readonly toolSurface: ToolSurface | undefined
  readonly readFiles: boolean
  readonly editFiles: boolean
  readonly writeFiles: boolean
  readonly shell: boolean
  readonly codeMode: boolean
  readonly workPlan: boolean
  readonly peerSubagents: boolean
  readonly skillReadSurface: "direct" | "code" | undefined
}

export interface SystemPromptSnapshot {
  readonly text: string
  readonly utf8Bytes: number
  readonly sections: readonly SystemPromptSection[]
  readonly capabilities: SystemPromptCapabilities
}

type PromptSection = SystemPromptSectionMetadata & { readonly text: string }

export function compileSystemPrompt(
  cwd: string,
  resources: SessionResources,
  tools: readonly AgentTool[],
  toolSurface?: ToolSurface
): SystemPromptSnapshot {
  const capabilities = deriveCapabilities(tools, toolSurface)
  const sections: PromptSection[] = [
    {
      kind: "base",
      source: resources.systemPrompt === undefined ? "default" : "custom",
      text: resources.systemPrompt ?? defaultSystemPrompt(capabilities)
    }
  ]

  if (toolSurface) sections.push({ kind: "code-mode", surface: toolSurface, text: codeModeDoctrine(toolSurface) })
  if (capabilities.workPlan) sections.push({ kind: "work-plan", text: workPlanDoctrine() })
  if (capabilities.peerSubagents) sections.push({ kind: "peer-subagents", text: peerMessagingDoctrine() })
  if (resources.systemPrompt === undefined) {
    sections.push({ kind: "product-documentation", text: productDocumentationPrompt() })
  }
  resources.appendSystemPrompt.forEach((text, index) => {
    sections.push({ kind: "appended-instructions", index, text })
  })
  if (resources.contextFiles.length > 0) {
    sections.push({
      kind: "project-instructions",
      files: Object.freeze(resources.contextFiles.map(file => file.path)),
      text: projectInstructionsPrompt(resources)
    })
  }

  const skillCatalog = capabilities.skillReadSurface
    ? buildSkillPromptCatalog(resources.skills, capabilities.skillReadSurface)
    : buildSkillPromptCatalog([])
  if (skillCatalog.text.length > 0) {
    sections.push({
      kind: "skills",
      includedCount: skillCatalog.includedCount,
      omittedCount: skillCatalog.omittedCount,
      text: skillCatalog.text
    })
  }

  sections.push({
    kind: "environment",
    text: `Current date: ${new Date().toISOString().slice(0, 10)}\nCurrent working directory: ${cwd}`
  })

  const compiled = compileSections(sections)
  return Object.freeze({
    text: compiled.text,
    utf8Bytes: Buffer.byteLength(compiled.text),
    sections: compiled.sections,
    capabilities
  })
}

export function buildSystemPrompt(
  cwd: string,
  resources: SessionResources,
  tools: readonly AgentTool[],
  toolSurface?: ToolSurface
): string {
  return compileSystemPrompt(cwd, resources, tools, toolSurface).text
}

function deriveCapabilities(
  tools: readonly AgentTool[],
  toolSurface: ToolSurface | undefined
): SystemPromptCapabilities {
  const toolNames = new Set(tools.map(tool => tool.name))
  const skillReadSurface = !toolNames.has("read") ? undefined : toolSurface === "code-only" ? "code" : "direct"
  return Object.freeze({
    toolSurface,
    readFiles: toolNames.has("read"),
    editFiles: toolNames.has("edit"),
    writeFiles: toolNames.has("write"),
    shell: toolNames.has("bash"),
    codeMode: toolSurface !== undefined,
    workPlan: toolNames.has("update_plan"),
    peerSubagents: toolNames.has("list_peer_subagents") && toolNames.has("send_peer_message"),
    skillReadSurface
  })
}

function compileSections(sections: readonly PromptSection[]): {
  readonly text: string
  readonly sections: readonly SystemPromptSection[]
} {
  const chunks: string[] = []
  const compiled: SystemPromptSection[] = []
  let cursor = 0
  for (const section of sections) {
    if (chunks.length > 0) {
      chunks.push("\n\n")
      cursor += 2
    }
    const { text, ...metadata } = section
    const start = cursor
    chunks.push(text)
    cursor += text.length
    compiled.push(Object.freeze({ ...metadata, start, end: cursor, utf8Bytes: Buffer.byteLength(text) }))
  }
  return Object.freeze({ text: chunks.join(""), sections: Object.freeze(compiled) })
}

function defaultSystemPrompt(capabilities: SystemPromptCapabilities): string {
  const guidelines = [
    ...(capabilities.readFiles || capabilities.editFiles || capabilities.writeFiles
      ? ["- Prefer dedicated file tools over shell equivalents when available."]
      : []),
    ...(capabilities.readFiles && (capabilities.editFiles || capabilities.writeFiles)
      ? ["- Read files before changing them and prefer focused edits."]
      : []),
    ...(capabilities.shell ? ["- Use shell execution for project commands and processes."] : []),
    "- Keep changes within the requested scope.",
    "- Be concise and show file paths clearly."
  ]
  return `You are an expert coding assistant operating inside Zi.

Use the admitted tools to complete the user's request.

Guidelines:
${guidelines.join("\n")}`
}

function workPlanDoctrine(): string {
  return `## Work plans
Use update_plan to keep a concise work plan for non-trivial work with at least three distinct steps.
- Skip the plan for simple, single-step requests.
- Keep at most one step in_progress while work remains.
- Mark a step completed only after its result is verified.
- Mark obsolete or deliberately skipped steps cancelled.
- Replace the complete plan when priorities or scope change; do not repeat the plan in prose after updating it.`
}

function productDocumentationPrompt(): string {
  const paths = getProductDocumentationPaths()
  const readme = promptPath(paths.readme)
  const docs = promptPath(paths.docs)
  const examples = promptPath(paths.examples)
  return `# Zi documentation

For questions or work about Zi itself, read ${docs}/index.md and the relevant linked guides first. Resolve documentation links from ${docs} and example links from ${examples}. Product overview: ${readme}.

Customization guides and examples:
- Extensions: ${docs}/extensions.md and ${examples}/extensions/
- Skills: ${docs}/skills.md and ${examples}/skills/
- Subagents: ${docs}/subagents.md and ${examples}/subagents/`
}

function projectInstructionsPrompt(resources: SessionResources): string {
  const files = resources.contextFiles
    .map(file => {
      const path = escapeXmlAttribute(file.path)
      const content = neutralizeProjectEnvelope(file.content)
      return `<project_instructions path="${path}">\n${content}\n</project_instructions>`
    })
    .join("\n\n")
  return `# Project instructions

Direct user instructions take precedence over the project instructions below. The files are ordered from broadest to most specific; when they conflict, the later file takes precedence.

<project_context>\n${files}\n</project_context>`
}

function neutralizeProjectEnvelope(value: string): string {
  return value.replace(/<(?=\/?project_(?:context|instructions)(?:\s|\/?>))/gi, "&lt;")
}

function escapeXmlAttribute(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
}

function promptPath(path: string): string {
  return path.replaceAll("\\", "/")
}

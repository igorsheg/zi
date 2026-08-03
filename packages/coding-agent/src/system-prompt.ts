import type { AgentTool } from "@earendil-works/pi-agent-core"

import { getProductDocumentationPaths } from "./product-documentation.js"
import type { SessionResources } from "./resource-loader.js"
import { formatSkillsForPrompt } from "./skills.js"

export function buildSystemPrompt(
  cwd: string,
  resources: SessionResources,
  tools: readonly AgentTool[],
  codeMode = false
): string {
  const prompt =
    resources.systemPrompt ??
    (codeMode
      ? `You are an expert coding assistant operating inside Zi.

Available tools:
- read: Read file contents
- bash: Execute shell commands
- edit: Make exact text replacements
- write: Create or overwrite files
- code: Orchestrate data-dependent multi-tool workflows in JavaScript

Guidelines:
- Use direct read, edit, write, and bash calls for ordinary coding operations
- Use code for loops, filtering, branching, aggregation, and multi-call extension or API workflows
- Use read instead of bash with cat or sed
- Be concise
- Show file paths clearly`
      : `You are an expert coding assistant operating inside Zi.

Available tools:
- read: Read file contents
- bash: Execute shell commands
- edit: Make exact text replacements
- write: Create or overwrite files

Guidelines:
- Use read to inspect files instead of shelling out to cat or sed
- Use edit for precise changes and write for new files or complete rewrites
- Be concise
- Show file paths clearly`)

  const sections = [prompt]
  if (resources.systemPrompt === undefined) sections.push(productDocumentationPrompt())
  if (resources.appendSystemPrompt.length > 0) sections.push(resources.appendSystemPrompt.join("\n\n"))
  if (resources.contextFiles.length > 0) {
    sections.push(
      `<project_context>\n${resources.contextFiles
        .map(file => `<project_instructions path="${file.path}">\n${file.content}\n</project_instructions>`)
        .join("\n\n")}\n</project_context>`
    )
  }
  if (tools.some(tool => tool.name === "read")) {
    const skills = formatSkillsForPrompt(resources.skills)
    if (skills.length > 0) sections.push(skills)
  }
  sections.push(`Current date: ${new Date().toISOString().slice(0, 10)}\nCurrent working directory: ${cwd}`)
  return sections.join("\n\n")
}

function productDocumentationPrompt(): string {
  const paths = getProductDocumentationPaths()
  const readme = promptPath(paths.readme)
  const docs = promptPath(paths.docs)
  const examples = promptPath(paths.examples)
  return `Zi documentation (read only when the user asks about Zi itself, configuration, extensions, skills, prompts, subagents, notifications, JSON, RPC, or the terminal client):
- Documentation index: ${docs}/index.md
- Product README: ${readme}
- Documentation directory: ${docs}
- Examples: ${examples}
- When reading Zi docs or examples, resolve links and relative paths from those absolute locations, not from the current working directory
- When asked about installation or getting started, read ${docs}/index.md
- When asked about the CLI or terminal client, read ${docs}/cli.md
- When asked about authentication, settings, or resource locations, read the corresponding guide in ${docs}/
- When asked about prompts or system instructions, read ${docs}/prompts.md
- When asked about notifications, read ${docs}/notifications.md
- When asked about JSON mode, read ${docs}/json-events.md
- When asked about RPC, read ${docs}/rpc.md and ${examples}/rpc/
- When asked about extensions, read ${docs}/extensions.md and ${examples}/extensions/
- When asked about skills, read ${docs}/skills.md and ${examples}/skills/
- When asked about subagents, read ${docs}/subagents.md and ${examples}/subagents/
- When working on Zi topics, read the relevant documentation and examples before implementing, and follow Markdown cross-references`
}

function promptPath(path: string): string {
  return path.replaceAll("\\", "/")
}

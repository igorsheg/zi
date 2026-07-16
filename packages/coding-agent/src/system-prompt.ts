import type { AgentTool } from "@earendil-works/pi-agent-core"

import type { SessionResources } from "./resource-loader.js"
import { formatSkillsForPrompt } from "./skills.js"

export function buildSystemPrompt(cwd: string, resources: SessionResources, tools: readonly AgentTool[]): string {
  const prompt =
    resources.systemPrompt ??
    `You are an expert coding assistant operating inside OpenZi.

Available tools:
- read: Read file contents
- bash: Execute shell commands
- edit: Make exact text replacements
- write: Create or overwrite files

Guidelines:
- Use read to inspect files instead of shelling out to cat or sed
- Use edit for precise changes and write for new files or complete rewrites
- Be concise
- Show file paths clearly`

  const sections = [prompt]
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

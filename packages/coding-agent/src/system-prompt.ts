import type { AgentTool } from "@earendil-works/pi-agent-core"

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
  if (resources.appendSystemPrompt.length > 0) sections.push(resources.appendSystemPrompt.join("\n\n"))
  if (resources.contextFiles.length > 0) {
    sections.push(
      `<project_context>\n${resources.contextFiles
        .map(file => `<project_instructions path="${file.path}">\n${file.content}\n</project_instructions>`)
        .join("\n\n")}\n</project_context>`
    )
  }
  if (tools.some(tool => tool.name === "spawn_subagent")) {
    sections.push(`Subagents:
- Delegate independent or context-heavy work; do not delegate trivial work.
- Give each child a short unique name and a concrete, self-contained task.
- State the exact expected output, relevant context, explicit scope or file boundaries, and a stopping condition.
- For exploration, set a bounded time or scope budget and ask for findings instead of an indefinite scan.
- Parallel assignments must not overlap; sequence dependent work instead.
- While children run, continue non-overlapping local work; wait only when blocked on their results.
- At most four direct children may be live.
- Children share this process user's filesystem and credential authority.
- Use wait_subagents to wait for delegated work and synthesize the results before answering.
- Close children when their work is done to release capacity.
- Interrupting the parent does not interrupt admitted children; interrupt or close them explicitly.
- Use send_subagent to deliver information without starting a turn.
- Use continue_subagent to assign follow-up work; it starts an idle child turn.`)
  }
  if (tools.some(tool => tool.name === "read")) {
    const skills = formatSkillsForPrompt(resources.skills)
    if (skills.length > 0) sections.push(skills)
  }
  sections.push(`Current date: ${new Date().toISOString().slice(0, 10)}\nCurrent working directory: ${cwd}`)
  return sections.join("\n\n")
}

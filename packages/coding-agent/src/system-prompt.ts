import type { AgentTool } from "@earendil-works/pi-agent-core"

import { codeModeDoctrine } from "./code-mode/prompt.js"
import { getProductDocumentationPaths } from "./product-documentation.js"
import type { SessionResources } from "./resource-loader.js"
import { formatSkillsForPrompt } from "./skills.js"
import { peerMessagingDoctrine } from "./subagents/peer-messenger.js"
import type { ToolSurface } from "./tool-surface.js"

export function buildSystemPrompt(
  cwd: string,
  resources: SessionResources,
  tools: readonly AgentTool[],
  toolSurface?: ToolSurface
): string {
  const prompt = resources.systemPrompt ?? defaultSystemPrompt(toolSurface)

  const sections = [prompt]
  if (toolSurface) sections.push(codeModeDoctrine(toolSurface))
  if (tools.some(tool => tool.name === "update_plan")) sections.push(workPlanDoctrine())
  if (tools.some(tool => tool.name === "send_peer_message")) sections.push(peerMessagingDoctrine())
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
    const skills = formatSkillsForPrompt(resources.skills, toolSurface === "code-only" ? "code" : "direct")
    if (skills.length > 0) sections.push(skills)
  }
  sections.push(`Current date: ${new Date().toISOString().slice(0, 10)}\nCurrent working directory: ${cwd}`)
  return sections.join("\n\n")
}

function defaultSystemPrompt(toolSurface: ToolSurface | undefined): string {
  if (toolSurface === "code-only") {
    return `You are an expert coding assistant operating inside Zi.

Available tools:
- code: Execute JavaScript that orchestrates Zi tools and other runtime APIs

The code cell's zi catalog provides the admitted file, shell, extension, and subagent tools.

Guidelines:
- Perform tool-backed operations through zi.* inside code cells
- Keep cells cohesive: group short related operations, and use JavaScript for data-dependent workflows
- Be concise
- Show file paths clearly`
  }
  const code =
    toolSurface === "direct-and-code" ? "\n- code: Orchestrate data-dependent multi-tool workflows in JavaScript" : ""
  return `You are an expert coding assistant operating inside Zi.

Available tools:
- read: Read file contents
- bash: Execute shell commands
- edit: Make exact text replacements
- write: Create or overwrite files${code}

Guidelines:
- Use read to inspect files instead of shelling out to cat or sed
- Use edit for precise changes and write for new files or complete rewrites
- Be concise
- Show file paths clearly`
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
  return `Zi documentation (read only when the user asks about Zi itself, configuration, extensions, skills, prompts, Code Mode, work plans, subagents, notifications, JSON, RPC, or the terminal client):
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
- When asked about Code Mode or the programmatic runtime, read ${docs}/code-mode.md
- When asked about work plans, read ${docs}/work-plans.md
- When asked about skills, read ${docs}/skills.md and ${examples}/skills/
- When asked about subagents, read ${docs}/subagents.md and ${examples}/subagents/
- When working on Zi topics, read the relevant documentation and examples before implementing, and follow Markdown cross-references`
}

function promptPath(path: string): string {
  return path.replaceAll("\\", "/")
}

import type { PromptResources } from "./resource-loader.js"

export function buildSystemPrompt(cwd: string, resources: PromptResources): string {
  if (resources.systemPrompt) return resources.systemPrompt

  const sections = [
    "You are a coding agent. Use the available tools to complete the user's request.",
    `Working directory: ${cwd}`,
  ]
  if (resources.contextFiles.length > 0) sections.push(resources.contextFiles.join("\n\n"))
  if (resources.appendSystemPrompt.length > 0) sections.push(resources.appendSystemPrompt.join("\n\n"))
  return sections.join("\n\n")
}

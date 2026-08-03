import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "tool_search",
    description: "Expose the matching repository tool",
    parameters: Schema.object({ query: Schema.string({ description: "Capability to find" }) }),
    async execute({ query }) {
      const selected = query.toLowerCase().includes("rule") ? ["tool_search", "repository_rule"] : ["tool_search"]
      await zi.setActiveTools(selected)
      return selected.length === 1 ? "No matching tool" : "Enabled repository_rule for the next model step"
    }
  })

  zi.registerTool({
    name: "repository_rule",
    description: "Look up one example repository rule",
    active: false,
    parameters: Schema.object({ topic: Schema.string() }),
    execute: ({ topic }) => `Rule for ${topic}: keep changes focused and tested.`
  })
}

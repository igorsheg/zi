import type { ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerAgentRole({
    name: "finder",
    description: "Find implementation evidence for one bounded question",
    instructions: "Inspect only the requested scope. Return concrete file paths, facts, and unresolved questions."
  })
}

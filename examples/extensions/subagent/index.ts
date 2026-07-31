import type { ExtensionAPI } from "@with-zi/extension-api"

export default function registerReviewer(zi: Pick<ExtensionAPI, "registerSubagentType">): void {
  zi.registerSubagentType({
    name: "reviewer",
    description: "Review a change for correctness and missing tests",
    instructions: "Inspect the requested change. Do not edit files. Return findings with paths and line numbers."
  })
}

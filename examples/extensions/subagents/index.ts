import type { ExtensionAPI } from "@with-zi/extension-api"

export default function recursiveAgentExample(zi: ExtensionAPI): void {
  zi.registerCommand({
    name: "delegate-evidence",
    description: "Spawn one explorer and report its durable path",
    async execute(arguments_) {
      if (!zi.agents) throw new Error("This session does not belong to an AgentTeam")
      const question = arguments_.trim()
      if (!question) throw new Error("Usage: /delegate-evidence <question>")
      const path = await zi.agents.spawn(
        "extension_evidence",
        `Act as a focused explorer. Answer this question with exact file evidence: ${question}`,
        { agentType: "explorer", forkTurns: "all" }
      )
      return `Spawned ${path}. Completion will arrive as durable agent mail.`
    }
  })
}

# @with-zi/extension-api

Public TypeScript contract for trusted [Zi](https://github.com/igorsheg/zi) extensions.

```ts
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.on("agent_settled", (_event, context) => {
    console.error(`Session ${context.session.id} is idle in ${context.mode} mode`)
  })

  zi.registerCommand({
    name: "repository-check",
    description: "Run one local repository check",
    argumentHint: "[name]",
    execute: (arguments_, { signal }) => {
      signal.throwIfAborted()
      return `Checked ${arguments_.trim() || "repository"}`
    }
  })

  zi.registerTool({
    name: "repository_rule",
    description: "Look up one repository rule",
    active: false,
    parameters: Schema.object({ topic: Schema.string() }),
    outputSchema: Schema.object({ topic: Schema.string(), rule: Schema.string() }),
    execute: ({ topic }) => ({ topic, rule: `Rule for ${topic}` })
  })

  zi.registerTool({
    name: "enable_repository_rules",
    description: "Expose the repository rule catalog",
    parameters: Schema.object({}),
    async execute() {
      await zi.setActiveTools(["enable_repository_rules", "repository_rule"])
      return "Repository rules enabled"
    }
  })
}
```

Zi provides this module to extension workers at runtime. Install it as a development dependency when authoring or type-checking an extension. Extensions execute with the current user's authority; the worker is fault containment, not a security sandbox.

Each callback receives one frozen context containing the runtime mode, absolute working directory, and memory or journal session identity. `agent_start` and `agent_settled` are ordered observational notifications; commands and tools receive the same context plus an invocation-scoped `AbortSignal`.

See the [extension author guide](https://github.com/igorsheg/zi/blob/main/docs/extensions.md), [custom-tool example](https://github.com/igorsheg/zi/tree/main/examples/extensions/custom-tool), [deferred-tools example](https://github.com/igorsheg/zi/tree/main/examples/extensions/deferred-tools), [durable-counter example](https://github.com/igorsheg/zi/tree/main/examples/extensions/durable-counter), [Herdr agent-state example](https://github.com/igorsheg/zi/tree/main/examples/extensions/herdr-agent-state), and [programmatic subagent-profile example](https://github.com/igorsheg/zi/tree/main/examples/extensions/subagents).

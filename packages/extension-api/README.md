# @with-zi/extension-api

Public TypeScript contract for trusted [Zi](https://github.com/igorsheg/zi) extensions.

```ts
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
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
    parameters: Schema.object({ topic: Schema.string() }),
    outputSchema: Schema.object({ topic: Schema.string(), rule: Schema.string() }),
    execute: ({ topic }) => ({ topic, rule: `Rule for ${topic}` })
  })
}
```

Zi provides this module to extension workers at runtime. Install it as a development dependency when authoring or type-checking an extension. Extensions execute with the current user's authority; the worker is fault containment, not a security sandbox.

See the [extension author guide](https://github.com/igorsheg/zi/blob/main/docs/extensions.md), [custom-tool example](https://github.com/igorsheg/zi/tree/main/examples/extensions/custom-tool), [durable-counter example](https://github.com/igorsheg/zi/tree/main/examples/extensions/durable-counter), and [programmatic subagent-profile example](https://github.com/igorsheg/zi/tree/main/examples/extensions/subagents).

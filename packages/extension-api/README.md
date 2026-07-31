# @with-zi/extension-api

Public TypeScript contract for trusted [Zi](https://github.com/igorsheg/zi) extensions.

```ts
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_rule",
    description: "Look up one repository rule",
    parameters: Schema.object({ topic: Schema.string() }),
    outputSchema: Schema.object({ topic: Schema.string(), rule: Schema.string() }),
    execute: ({ topic }) => ({ topic, rule: `Rule for ${topic}` })
  })

  zi.registerSubagentType({
    name: "reviewer",
    description: "Review a change for correctness and missing tests",
    instructions: "Inspect the change without editing files and return path-qualified findings."
  })
}
```

Zi provides this module to extension workers at runtime. Install it as a development dependency when authoring or type-checking an extension. Extensions execute with the current user's authority; the worker is fault containment, not a security sandbox.

See the [extension author guide](https://github.com/igorsheg/zi/blob/main/docs/extensions.md), [custom-tool example](https://github.com/igorsheg/zi/tree/main/examples/extensions/custom-tool), [subagent-definition example](https://github.com/igorsheg/zi/tree/main/examples/extensions/subagent), and [durable-counter example](https://github.com/igorsheg/zi/tree/main/examples/extensions/durable-counter).

# @with-zi/extension-api

Public TypeScript contract for trusted [Zi](https://github.com/igorsheg/zi) extensions.

```ts
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_rule",
    description: "Look up one repository rule",
    parameters: Schema.object({ topic: Schema.string() }),
    execute: ({ topic }) => `Rule for ${topic}`
  })
}
```

Zi provides this module to extension workers at runtime. Install it as a development dependency when authoring or type-checking an extension. Extensions execute with the current user's authority; the worker is fault containment, not a security sandbox.

See the [extension author guide](https://github.com/igorsheg/zi/blob/main/docs/extensions.md), [custom-tool example](https://github.com/igorsheg/zi/tree/main/examples/extensions/custom-tool), and [durable-counter example](https://github.com/igorsheg/zi/tree/main/examples/extensions/durable-counter).

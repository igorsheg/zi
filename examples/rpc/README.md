# Zi RPC client example

[`client.ts`](client.ts) is a copyable one-shot client for Zi's version-1 process protocol. It imports no Zi package. The client owns its child process, strict JSONL reader, request correlation, output sequence validation, bounded stderr, request deadlines, message paging, and final process settlement.

With Zi installed and a model configured:

```sh
bun examples/rpc/client.ts "Summarize this repository"
```

As a library, pass an explicit command so the caller owns all Zi startup policy:

```ts
import { runRpcPrompt } from "./client.ts"

const controller = new AbortController()
const answer = await runRpcPrompt({
  command: ["/path/to/zi", "--no-session", "--cwd", process.cwd()],
  prompt: "List the main architectural boundaries",
  cwd: process.cwd(),
  env: process.env,
  signal: controller.signal,
  onEvent(event) {
    if (event.type === "tool_execution_start") console.error(`tool: ${event.toolName}`)
  }
})

console.log(answer)
```

`runRpcPrompt()` appends `--mode rpc`, admits one direct prompt, waits for session settlement, walks bounded message pages, returns the final assistant text, closes stdin, and joins Zi. Longer-lived applications can retain the same ownership decomposition while using the additional steering, follow-up, interruption, model, and thinking methods documented in [`docs/rpc.md`](../../docs/rpc.md).

The release-shaped custom-tool acceptance runs this exact client against the compiled standalone executable on every supported target.

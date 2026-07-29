# ADR 0024: Code mode isolates generated orchestration and remains additive

## Status

Accepted.

## Context

Direct tools are efficient and legible for ordinary coding operations, but model-driven loops over opaque extension or API tools repeatedly return intermediate data through provider context. Cloudflare's Code Mode demonstrates that one generated JavaScript program can keep data-dependent branching, filtering, aggregation, and fan-out near the tools. Its durable approvals, replay, connectors, rollback, and snippets solve a different hosted-agent problem and are not required for Zi's first local implementation.

Zi's evaluations showed the boundary clearly. Replacing direct coding tools regressed an ordinary repository edit, while a code-only opaque-record workflow reduced fourteen outer calls and four provider turns to one outer call and two turns. An additive evaluation kept all direct tools, selected `code` for the opaque workflow, and selected only direct tools for the ordinary edit. Code mode therefore belongs beside the direct catalog, not behind a feature flag and not in place of existing tools.

Generated code is untrusted model output. Running QuickJS inside the coding-agent process would let a VM fault, memory failure, or non-yielding guest threaten the session owner. It would also make worker lifetime and hard cancellation impossible to separate from `AgentSession`. The selected QuickJS build is `quickjs-emscripten-core` and `@jitl/quickjs-singlefile-mjs-release-sync` 0.32.0, based on `justjake/quickjs-emscripten` commit `7b7af98e4e69757c64c27aac46a74e1e07229545`. Its single-file synchronous WASM variant passed compiled probes on Zi's five release targets with Bun 1.3.14.

The implementation also needs normal tool schema validation, cancellation, expected-error classification, execution policy, bounded progress, durable evidence, compaction accounting, headless output, and terminal presentation. Calling private agent-loop machinery recursively would create a second conversation loop and duplicate transcript identities. Speculative extension interception hooks would widen public contracts before there is evidence for them.

## Decision

Every native Zi runtime exposes `code` alongside its admitted direct tools. The names `code` and `then` are reserved before extension tool admission; `then` keeps the guest catalog from participating in JavaScript thenable assimilation. Low-level SDK construction may omit the capability only by not supplying its concrete `CodeMode` owner; the CLI has no feature flag.

One `CodeExecution` owns one child process, protocol streams, VM deadline, parent cancellation, nested invocation queue, bounded trace, final outcome, and cleanup. Source-mode Zi starts a dedicated worker entry; compiled Zi self-hosts the same internal worker route. POSIX uses Bun's process API and Windows uses `node:child_process`, following ADR 0021's proven platform split and extra protocol pipe.

The child owns one QuickJS runtime and context. The runtime is limited to 64 MiB memory, 512 KiB stack, and 500 ms uninterrupted guest bursts. The guest receives only frozen `console` methods and a frozen, non-thenable `zi` object containing exactly the admitted tool-name catalog. Unknown properties are absent, bridge functions are removed after bootstrap, and catalog coercion cannot dispatch a host call. There is no ambient `process`, `Bun`, `require`, `fetch`, module import, filesystem, shell, credential, network, or raw protocol authority. The worker receives a reduced process environment and performs no session effects itself.

Host and worker exchange versioned, length-prefixed JSON frames over private pipes. Frames, queued bytes, code, tool names, JSON depth and nodes, calls, logs, result text, stderr, startup, execution, shutdown, and nested settlement are bounded. Cancellation aborts the active nested tool, closes protocol admission, terminates the child, and escalates to hard termination after a bounded wait. Stale nested completion cannot update a settled execution.

The host freezes the admitted direct and extension tool catalog for an execution. Nested calls use the ordinary tool's argument preparation and schema validation, receive the execution cancellation signal and partial-update callback, and retain built-in expected-error classification. Calls are serialized even when guest promises are created together so mutation order is deterministic. A terminating nested result prevents later calls and propagates termination through the outer `code` result. The guest must await every call; unawaited calls fail the execution. V1 does not promise rollback for effects admitted before that failure is detected.

Successful nested responses have the stable guest shape `{ text, details }`; failures throw `Error` so guest code can branch with `try/catch`. Full nested results remain transient protocol data. Durable `code_mode` details retain at most 64 projected calls with bounded arguments, command/path/operation evidence, outcome, duration, and a short result, error, or current preview, plus bounded completion-time console logs. Built-in write content and edit replacements are reduced to path, byte-count, and operation-count evidence. The outer tool is the single transcript identity. Coding-agent presentation projects this trace for all clients; the TUI renders the same bounded facts. Successful nested `read`, `write`, and `edit` calls contribute to compaction file accounting.

V1 is stateless. Approvals, replay, rollback, snippets, connectors, network access, and durable code artifacts remain deferred. New extension interception or approval contracts require independent product evidence.

Release acceptance compiles Zi and executes the self-hosted code worker on `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, and `windows-x64`. The acceptance verifies nested host dispatch, trace settlement, absence of ambient guest authority, and busy-loop interruption.

## Consequences

- Ordinary coding retains the direct tool path, while data-dependent orchestration can avoid repeated provider turns.
- QuickJS and its approximately 1.31 MiB compiled payload become native coding-agent dependencies, but they load only in the worker path.
- VM crashes, memory exhaustion, infinite loops, and hard cancellation are isolated from the coding-agent process.
- Tool effects, extensions, credentials, and network policy remain host-owned; code mode grants no new ambient capability.
- Process isolation contains ordinary guest failures but is not a security boundary against a QuickJS escape: the trusted worker still runs as the user and can access its process environment and filesystem.
- One outer tool result carries bounded nested evidence across session durability, compaction, JSON/RPC output, and terminal presentation without creating nested transcript rows.
- Serialization favors deterministic mutation semantics over guest-side parallel throughput. Parallel nested execution requires a later explicit ordering decision.
- Unawaited calls are an execution error, not a transaction. V1 cannot undo a tool effect already admitted before detection.
- Cloudflare Code Mode is provenance for code normalization and product evidence, not an adopted runtime or durable workflow architecture.

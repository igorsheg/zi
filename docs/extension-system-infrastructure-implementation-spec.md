# Extension system infrastructure implementation spec

- Status: in progress — lifecycle infrastructure complete; custom-tool capability implemented
- Pi behavior reference: `badlogic/pi-mono` at Zi's pinned `0e6909f0` (`v0.80.6`)
- Current Pi comparison: `fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc`
- Project-trust comparison: `5bc1c2c0a6f07e00e8c240304182f213ab8d311f`
- Product owner: `AgentSession`
- Infrastructure owner: coding-agent `ExtensionHost`

## 1. Purpose

Zi will eventually support the full behavioral capability of Pi's extension system: trusted TypeScript extensions, lifecycle and agent events, tools, commands, durable messages and entries, providers, model operations, session operations, terminal contributions, and package distribution.

This specification establishes the extension substrate before any product capability is added. The first accepted implementation can discover, trust-gate, load, identify, reload, and shut down otherwise empty TypeScript extensions through a supervised extension generation.

The initial infrastructure contract contained lifecycle registration only. Protocol version 2 adds the first separate capability: bounded model-callable tools. Commands, providers, UI, and a generic event framework remain excluded.

Lifecycle loading is an infrastructure checkpoint, not the product launch boundary. The first usable outcome is the [`custom-tool extension golden path`](extension-custom-tool-golden-path.md), which must work across interactive, text, and JSON modes against the compiled release.

The target is capability parity, not source identity with Pi. In particular, Zi will not expose Pi TUI components or copy Pi's broad in-process object graph.

## 2. Outcomes

The infrastructure must provide:

1. deterministic discovery of global, project, and explicit extension sources;
2. project-trust admission before any project-owned code or configuration is applied;
3. an immutable, cwd-bound extension load plan derived from `ZiPaths`;
4. lazy startup with no subprocess when the plan is empty;
5. TypeScript module loading with Node built-ins and extension-local npm dependencies;
6. a supervised extension worker isolated from the Zi process and TUI owner loop;
7. versioned, framed, bounded, bidirectional IPC;
8. one current extension generation and at most one candidate generation;
9. whole-generation reload with stale-generation rejection;
10. source-attributed, bounded diagnostics without aborting ordinary Zi startup;
11. bounded lifecycle settlement and final process teardown;
12. a public lifecycle contract plus protocol-v2 tool registration and execution;
13. structural and compiled acceptance tests covering races, bounds, crashes, hangs, replacement, and cleanup.

## 3. Non-goals

The current capability does not implement:

- commands, shortcuts, or extension-owned CLI flags;
- agent, provider, tool, input, compaction, or session-tree interception;
- custom messages, durable entries, names, or labels;
- model or provider registration;
- resource contribution from extensions;
- direct OpenTUI renderables or terminal widgets;
- an inter-extension event bus;
- package install, update, or removal;
- Pi extension source compatibility;
- automatic worker restart;
- an OS security sandbox or credential-confidentiality boundary;
- one process per extension;
- a generic internal command bus or event envelope inside Zi;
- a frontend store for extension state.

Later capabilities extend the closed process protocol and bind through their authoritative coding-agent or TUI owners. They do not expand this infrastructure into a manager-of-managers.

## 4. Pi provenance

The useful Pi infrastructure is spread across these sources:

- [`core/extensions/loader.ts`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/extensions/loader.ts): async factories, module loading, source records, TypeScript loading, aliases, and compiled-binary virtual modules;
- [`core/resource-loader.ts`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/resource-loader.ts): pre-trust and final extension passes, deterministic source ordering, diagnostics, and reload;
- [`core/extensions/runner.ts`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/extensions/runner.ts): source-attributed errors, ordered handlers, late-bound contexts, and stale-runtime rejection;
- [`core/agent-session.ts`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/agent-session.ts): session binding, shutdown-before-reload, generation reconstruction, and lifecycle ordering;
- [`docs/extensions.md`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/docs/extensions.md): extension locations, trust, async factory semantics, dependency resolution, and the rule that long-lived resources start at `session_start` and stop at `session_shutdown`.

The complete public Pi surface is inventoried in [`docs/pi-mono-extension-api-reference.md`](pi-mono-extension-api-reference.md).

### 4.1 Pi behavior to preserve

Zi takes these ideas from Pi:

- an extension exports one synchronous or asynchronous default factory;
- factory settlement forms the initial registration barrier;
- each extension has stable source identity and provenance;
- global, project, package, and temporary sources remain distinguishable;
- project code does not load before project trust;
- load order is deterministic and later capability owners receive that order;
- one extension's import or factory failure is attributed to that extension;
- a reload creates a fresh module generation;
- old contexts become invalid after reload or session replacement;
- lifecycle handlers are asynchronous and ordered;
- TypeScript works without a separate extension build step;
- official extension imports remain available from the standalone executable;
- npm dependencies resolve from the extension's package hierarchy;
- module caches do not leak across generations;
- long-lived resources belong between `session_start` and `session_shutdown`.

### 4.2 Pi implementation not to copy

Zi does not copy:

- Pi's in-process execution, which allows an extension to block the agent and TUI;
- the module-global cwd/generation extension cache;
- `ExtensionRuntime` objects populated with throwing stubs and mutated later by `bindCore()`;
- one `ExtensionRunner` that owns tools, commands, flags, shortcuts, providers, models, messages, rendering, UI, and events;
- generic no-op UI implementations for unsupported modes;
- direct mutable access to `SessionManager`, `ModelRegistry`, or `AgentSession`;
- direct Pi TUI `Component` values;
- an untyped event bus as internal application architecture;
- unbounded import, handler, output, queue, or shutdown waits.

Pi's event-specific combination rules remain behavioral references for later slices. Zi will implement each event explicitly rather than inventing one generic reducer now.

## 5. Terminology

**Extension source**  
One canonical extension entry point plus its declared path, scope, origin, and stable identity.

**Extension load plan**  
The immutable ordered set of extension sources admitted for one exact `ZiPaths.cwd` after trust resolution.

**Extension worker**  
The child-process program that loads TypeScript modules, owns extension JavaScript state, runs factories and handlers, and communicates only through the extension protocol.

**Extension generation**  
One worker process, one load plan, one protocol generation ID, and all resources tied to that process. A generation is never mutated into another generation.

**Extension host**  
The coding-agent owner of the current and candidate generations, protocol resources, diagnostics, reload, bounded settlement, and disposal.

**Extension lifecycle**  
The interval beginning when a committed generation receives `session_start` and ending when it receives `session_shutdown` or is forcibly terminated.

## 6. Ownership and package placement

### 6.1 `ZiPaths`

`ZiPaths` remains the only path-policy owner. Extension discovery consumes:

```text
$HOME/.zi/agent/extensions/
<effective-cwd>/.zi/extensions/
```

Explicit CLI paths are resolved once at argument admission and are never reinterpreted after session cwd replacement.

No extension owner joins `.zi`, reads `process.cwd()`, or derives the global agent directory independently.

### 6.2 Project trust

A coding-agent project-trust owner decides whether project configuration is admitted for one canonical cwd. Trust gates project settings, system prompts, skills, prompts, and extensions together, as required by ADR 0011.

Extension-only trust is forbidden. Zi must not execute project extensions while applying or rejecting other project configuration through a separate decision.

`ZiPaths.trustFile` resolves the bounded global `trust.json`. `ProjectTrustStore` owns canonical cwd persistence, locked atomic updates, and nearest-parent lookup. A bare project `.zi` directory and contextual `AGENTS.md`/`CLAUDE.md` files do not require project trust; exact project settings, system prompts, skills, prompts, themes, and extensions do. Persisted-store failure remains an unresolved safe state that the resolver diagnoses; it never admits project configuration.

### 6.3 `ExtensionHost`

`ExtensionHost` is one instance-scoped coding-agent owner. It owns:

- current and candidate generation identity;
- worker processes it creates and every attached pipe;
- protocol decoder and serialized writer queues;
- request correlation and pending-request bounds;
- startup, lifecycle, and shutdown deadlines;
- stderr retention;
- diagnostics;
- reload admission;
- stale-generation rejection;
- final disposal.

The loader, transport, request map, and generation transition rules do not become independently mutable managers. Extension-spawned processes remain extension-owned. Lifecycle documentation requires cooperative cleanup during `session_shutdown`, but forced worker teardown cannot guarantee termination of detached or otherwise surviving descendants; that would require a separately specified process-tree/job owner.

### 6.4 `AgentSession`

Runtime bootstrap may create a candidate `ExtensionHost` before `AgentSession`, because future extension registrations can affect model and tool construction. Ownership transfers only after session construction succeeds:

1. runtime bootstrap creates the host;
2. bootstrap starts and validates its initial generation;
3. successful `createAgentSession()` takes ownership;
4. failed session construction disposes the candidate host;
5. `AgentSession.dispose()` initiates final host shutdown;
6. `AgentSessionRuntime` replacement naturally replaces the entire host with the old session.

The TUI never owns or disposes the host.

### 6.5 Source layout

ADR 0021 confirmed that the initial implementation remains under coding-agent and self-hosts its worker from the compiled Zi executable:

```text
packages/coding-agent/src/extensions/
  discovery.ts
  host.ts
  protocol.ts
  worker.ts
```

These are deep modules with distinct responsibilities:

- `discovery.ts` is bounded filesystem admission and returns immutable data;
- `host.ts` owns all mutable process and generation state;
- `protocol.ts` defines and validates the closed process boundary;
- `worker.ts` is the separately invoked worker entry point and TypeScript loader.

A separate `@with-zi/extension-api` workspace package is justified when the lifecycle contract lands because external source fixtures need a stable import independent of Zi internals. It initially exports lifecycle types only; type-only imports erase before external modules execute, so the compiled virtual module is deferred until the custom-tool contract introduces runtime values. Npm publication likewise waits for the custom-tool golden path rather than promoting an otherwise empty lifecycle API as a usable platform.

Do not create a separate package solely to hold the private protocol.

## 7. Project trust and source admission

### 7.1 Trust resolution

Runtime construction awaits one immutable resolution for its canonical cwd:

```ts
type ProjectTrustResolution =
  | { type: "not_required"; cwd: string; reason: "no_project_configuration" | "project_configuration_is_global" }
  | { type: "unresolved"; cwd: string; diagnostic: ProjectTrustDiagnostic }
  | { type: "trusted"; cwd: string; source: "stored" | "interactive" | "runtime"; savedCwd?: string }
  | {
      type: "untrusted"
      cwd: string
      source: "stored" | "interactive" | "runtime"
      savedCwd?: string
      diagnostic?: ProjectTrustDiagnostic
    }
```

Trust is keyed by canonical cwd. Persisted trust input is bounded and validated before admission. Stored decisions live only in global `trust.json`; the nearest exact or parent decision applies. Process-local interactive and runtime decisions carry their exact cwd, so a decision cannot cross session replacement into another project. Only an explicit remember operation mutates the store.

The resolution becomes one `trusted | untrusted | absent` project-configuration admission shared by settings, resources, and extension discovery. `absent` means protected configuration did not exist at resolution: owners still do not scan project paths, but an explicit project-settings write may atomically create a new file and must fail if a file raced into place. Coincident global/project configuration is `not_required` and admitted only through global scope.

Global and explicit CLI extensions are already user-admitted. Project extensions require `trusted`. In noninteractive modes, unresolved or untrusted protected project configuration is excluded and emits a diagnostic.

Global extensions may participate in trust decisions in a later event slice. The initial infrastructure uses Zi's built-in trust resolver only.

### 7.2 Two-pass admission

```text
construct ZiPaths
  -> load global settings needed for trust policy
  -> discover global and explicit extension sources
  -> resolve project trust
  -> if trusted, admit project settings/resources/extensions
  -> construct final ExtensionLoadPlan
```

No project extension module, project extension package manifest, or project settings file is evaluated before trust.

### 7.3 Source value

```ts
interface ExtensionSource {
  readonly id: string
  readonly declaredPath: string
  readonly entryPath: string
  readonly scope: "global" | "project" | "temporary"
  readonly origin: "directory" | "package" | "cli"
}

interface ExtensionLoadPlan {
  readonly cwd: string
  readonly sources: readonly ExtensionSource[]
}
```

`entryPath` is canonical and absolute. `id` is derived from canonical source identity and does not depend on load success or filesystem enumeration order.

### 7.4 Initial discovery rules

The first implementation recognizes:

```text
extensions/*.ts
extensions/*.js
extensions/*/index.ts
extensions/*/index.js
```

Discovery is one level deep. Package manifests and npm/git package installation arrive in the package slice. Explicit paths may point to a file or a directory following the same entry rules.

Discovery admits explicit CLI paths first, then trusted project sources, then global sources. When `ZiPaths.projectConfigIsGlobal` is true, that coincident root is already user-admitted global configuration and is scanned exactly once as global regardless of project trust. This preserves current Pi's temporary → project → user load order while making project omission one closed admission input. Within each root it:

- requires explicit paths to have been resolved absolutely at CLI admission;
- fails closed for a root whose bounded directory read truncates before sorting;
- sorts complete bounded directory entries before admission;
- canonicalizes and deduplicates paths;
- does not traverse directory symlinks recursively;
- prefers `index.ts` only when it resolves to a file, preserves unreadable diagnostics, and otherwise falls back to a valid `index.js`;
- preserves missing, unreadable, and unsupported outcomes through extension-specific path inspection;
- resolves symlinks, revalidates the canonical path bound, and then deduplicates;
- preserves the first admitted source for a canonical duplicate;
- opens every candidate entry point for reading before admission;
- reports missing, unreadable, unsupported, duplicate, and omitted sources;
- derives stable source IDs from canonical entry paths;
- admits at most 128 sources and 256 bounded diagnostics;
- returns no executable code or mutable registry.

Capability owners, not discovery, later decide conflicts between declarations such as duplicate tool or command names.

## 8. Host state and transitions

```ts
type ExtensionHostLifecycle = "unbound" | "started" | "stopped"

type ExtensionHostState =
  | { type: "disabled"; lifecycle: ExtensionHostLifecycle }
  | { type: "starting"; lifecycle: ExtensionHostLifecycle; candidate: Candidate }
  | { type: "ready"; lifecycle: ExtensionHostLifecycle; current: ExtensionGeneration }
  | {
      type: "dispatching"
      lifecycle: ExtensionHostLifecycle
      current: ExtensionGeneration
      event: "session_start" | "session_shutdown"
    }
  | {
      type: "replacing"
      lifecycle: ExtensionHostLifecycle
      current: ExtensionGeneration
      candidate: Candidate | { type: "empty" }
    }
  | { type: "stopping"; lifecycle: ExtensionHostLifecycle; generations: readonly ExtensionGeneration[] }
  | { type: "failed"; lifecycle: ExtensionHostLifecycle; diagnostic: ExtensionDiagnostic; cleanup: Promise<void> }
  | { type: "disposed" }
```

A generation contains its immutable ID and plan plus the process resources tied to that ID. It is private to `ExtensionHost`. `Candidate` distinguishes an admitted spawn from a spawned generation so the host records its transition before performing process I/O. Failed state retains only the bounded cleanup settlement needed to prevent a retry or final disposal from outrunning process teardown.

### 8.1 Allowed transitions

```text
disabled -> starting             non-empty plan admitted
starting -> ready                worker handshake and factory barrier settle
starting -> failed               fatal spawn/handshake/protocol/startup failure
starting -> stopping             shutdown admitted during startup
ready -> dispatching             lifecycle request admitted
dispatching -> ready             lifecycle request settles
dispatching -> failed            lifecycle generation fails
dispatching -> stopping          final shutdown supersedes lifecycle work
ready -> replacing               reload admitted
ready -> stopping                final shutdown admitted
replacing -> ready(current)       candidate fails before commit
replacing -> ready(candidate)     candidate commits and old generation settles
replacing -> disabled             replacement intentionally has an empty plan
replacing -> failed               current and candidate both fail
replacing -> stopping             final shutdown supersedes reload
failed -> starting               explicit reload/retry after cleanup
failed -> disposed               final disposal after cleanup
stopping -> disposed             bounded process teardown settles
disabled -> disposed             final disposal
```

No operation is admitted from `disposed`. Concurrent reload requests share the active replacement or are rejected as already replacing; they do not create a queue.

### 8.2 Startup

An empty plan produces `disabled` and does not spawn or materialize a worker.

For a non-empty plan:

1. record `starting` with a fresh generation ID;
2. spawn the worker and install all owned readers, writers, and deadlines;
3. send `initialize`;
4. validate every worker frame;
5. wait for the factory registration barrier;
6. commit `ready`, or apply `failed` after bounded teardown.

Per-extension import or factory errors are ordinary diagnostics. The generation may become ready with the successfully loaded subset, matching Pi's non-fatal source behavior. A process crash, protocol failure, or blocked worker is a fatal generation failure.

### 8.3 Atomic replacement

Reload replaces the worker process rather than invalidating module caches in place:

1. admit `replacing` while retaining the current generation;
2. spawn and initialize one candidate generation;
3. if the candidate fatally fails, destroy it and return to the current `ready` generation;
4. after candidate readiness, send `session_shutdown` to the current generation;
5. await bounded lifecycle settlement;
6. terminate the current process and release its resources;
7. commit the candidate as current;
8. send `session_start` to the candidate;
9. reject every later frame from the old generation.

At most two generation processes exist during replacement. Ordinary per-extension load diagnostics do not make the candidate fatal; they produce the same partial extension set Pi would expose after reload.

### 8.4 Final shutdown

Final shutdown is distinct from reload and tool/run interruption:

1. stop admitting extension requests;
2. cancel an uncommitted candidate;
3. send `session_shutdown` to the current generation when possible;
4. await its bounded settlement;
5. close protocol admission;
6. request graceful process exit;
7. terminate and then force-kill within the remaining deadline;
8. close pipes, reject pending requests, and release listeners;
9. transition to `disposed`.

During terminal shutdown, OpenTUI is restored before the caller awaits this settlement, consistent with ADR 0009.

## 9. Worker runtime decision

[ADR 0021](adr/0021-compiled-zi-self-hosts-extension-workers.md) selects a self-hosted compiled Bun worker using portable Node-compatible process pipes. A release-shaped probe preceded production code and verified the decision across every release target.

### 9.1 Candidate A: self-hosted Bun worker

Spawn the Zi executable in an internal extension-worker mode. This avoids a new runtime dependency and keeps release artifacts self-contained.

### 9.2 Candidate B: supervised Node worker

If the standalone executable cannot reliably provide external TypeScript, Node built-ins, extension-local dependency resolution, and dedicated protocol pipes on every release platform, use a separately materialized Node worker with an explicit minimum version.

### 9.3 Probe requirements

The probe must run from a compiled release-shaped Zi executable containing the full CLI entrypoint plus temporary parent/worker dispatch, and prove:

- external `.ts` loading;
- async default factory execution;
- `node:fs` import;
- one extension-local npm dependency;
- extension stdout and stderr isolation from protocol traffic;
- dedicated protocol transport;
- clean process exit;
- deliberate exception attribution;
- deliberate process crash containment;
- deliberate infinite-loop containment;
- macOS, Linux, and Windows behavior.

ADR 0021 records the selected mechanism before production host code lands. The temporary probe is deleted.

### 9.4 Probe result

The probe compiled a release-shaped Zi entrypoint, self-spawned that executable as a worker, and exercised external TypeScript, an async factory, a Node built-in, an extension-local dependency, isolated stdout/stderr, a dedicated protocol pipe, attributed failure, process crash, and forced termination of an infinite loop.

The first transport used Bun's direct subprocess file-descriptor APIs. It passed on macOS and Linux but failed on Windows x64. The selected transport uses `node:child_process.spawn()` with an extra stdio pipe and `node:fs` descriptor I/O inside the Bun executable.

| Target      | Bun    | Result | Evidence                                                                              |
| ----------- | ------ | ------ | ------------------------------------------------------------------------------------- |
| macOS arm64 | 1.3.14 | Passed | [GitHub Actions 30218801769](https://github.com/igorsheg/zi/actions/runs/30218801769) |
| macOS x64   | 1.3.14 | Passed | [GitHub Actions 30218801769](https://github.com/igorsheg/zi/actions/runs/30218801769) |
| Linux arm64 | 1.3.14 | Passed | [GitHub Actions 30218801769](https://github.com/igorsheg/zi/actions/runs/30218801769) |
| Linux x64   | 1.3.14 | Passed | [GitHub Actions 30218801769](https://github.com/igorsheg/zi/actions/runs/30218801769) |
| Windows x64 | 1.3.14 | Passed | [GitHub Actions 30218801769](https://github.com/igorsheg/zi/actions/runs/30218801769) |

The temporary probe and workflow were deleted after ADR 0021 recorded the result.

## 10. TypeScript module loading

Pi's `jiti/static` integration is the reference implementation to evaluate. The selected worker must provide:

- `.ts` and `.js` entry points without a separate extension build;
- extension-local relative imports;
- extension-local `node_modules` resolution;
- Node built-ins;
- a fresh module graph per generation;
- a validated default export function;
- awaited async factory settlement;
- official virtual modules available from the standalone distribution.

The only runtime-valued official module is `@with-zi/extension-api`. Custom-tool registration adds its narrow `Schema` builders without exposing TypeBox itself as a worker virtual module. Third-party packages, including direct TypeBox usage, resolve from the extension's own package hierarchy.

Zi does not expose `@with-zi/coding-agent`, OpenTUI, `AgentSession`, `SessionManager`, `ModelRegistry`, credentials, or private implementation modules through the extension interface. Extensions remain trusted JavaScript running with the Zi user's operating-system authority: they can read user-accessible files and environment variables, spawn processes, and interfere with worker-local resources or descriptors. The worker boundary contains faults and protects Zi's owner loop from ordinary crashes and hangs; it is not a sandbox or credential-confidentiality boundary.

The factory may register lifecycle handlers and tools during execution. Factory completion closes registration and sends the worker's `ready` barrier. Registrations attempted later are rejected.

Extension factories should not create long-lived resources. The documented lifetime is `session_start` through `session_shutdown`. Zi cannot make arbitrary JavaScript obey this convention, so process replacement and forced teardown remain the final resource boundary.

## 11. Public extension contract

```ts
export type ExtensionStartReason = "startup" | "reload" | "new" | "resume" | "fork"
export type ExtensionShutdownReason = "quit" | "reload" | "new" | "resume" | "fork"

export type ExtensionLifecycleEvent =
  | { readonly type: "session_start"; readonly reason: ExtensionStartReason }
  | { readonly type: "session_shutdown"; readonly reason: ExtensionShutdownReason }

export interface ExtensionAPI {
  registerTool<TParameters extends TSchema>(definition: ExtensionToolDefinition<TParameters>): void
  on(
    event: "session_start",
    handler: (event: Extract<ExtensionLifecycleEvent, { type: "session_start" }>) => void | Promise<void>
  ): void
  on(
    event: "session_shutdown",
    handler: (event: Extract<ExtensionLifecycleEvent, { type: "session_shutdown" }>) => void | Promise<void>
  ): void
}

export interface ExtensionToolDefinition<TParameters extends TSchema> {
  readonly name: string
  readonly label?: string
  readonly description: string
  readonly parameters: TParameters
  readonly execute: (
    arguments_: Static<TParameters>,
    context: { readonly signal: AbortSignal }
  ) => string | Promise<string>
}

export type ExtensionFactory = (zi: ExtensionAPI) => void | Promise<void>
```

`Schema` exports only `string`, `number`, `integer`, `boolean`, `literal`, `optional`, `array`, and `object`. Tool parameters must have an object root. Arguments and one textual result are bounded and validated across the process boundary. Registration is factory-scoped and rolled back per source on failure.

An extension with no contribution is valid:

```ts
import type { ExtensionAPI } from "@with-zi/extension-api"

export default async function (_zi: ExtensionAPI): Promise<void> {}
```

Lifecycle handlers execute in source load order and registration order. A handler failure emits a diagnostic and continues to the next handler. A lifecycle timeout is fatal to that generation because JavaScript execution cannot be safely preempted in place.

## 12. Process protocol

### 12.1 Transport

Use length-prefixed UTF-8 JSON over dedicated process pipes:

```text
parent -> child: child stdin
child -> parent: dedicated extra pipe
child stdout: bounded extension log stream
child stderr: bounded extension diagnostic log stream
```

The frame prefix is a four-byte unsigned big-endian payload length. The decoder accepts partial prefixes, partial payloads, and multiple frames per read. It rejects zero-length, oversized, malformed UTF-8/JSON, and unknown messages before they enter the host state machine.

A dedicated child-to-parent pipe keeps arbitrary `console.log()` and `process.stdout.write()` calls from corrupting protocol framing. The runtime probe must prove extra-pipe behavior on all release platforms.

### 12.2 Host messages

```ts
type HostMessage =
  | {
      readonly type: "initialize"
      readonly protocolVersion: 2
      readonly generation: number
      readonly plan: ExtensionLoadPlan
    }
  | {
      readonly type: "session_start"
      readonly generation: number
      readonly requestId: number
      readonly reason: ExtensionStartReason
    }
  | {
      readonly type: "session_shutdown"
      readonly generation: number
      readonly requestId: number
      readonly reason: ExtensionShutdownReason
    }
  | {
      readonly type: "tool_invoke"
      readonly generation: number
      readonly requestId: number
      readonly name: string
      readonly arguments: Readonly<Record<string, JsonValue>>
    }
  | { readonly type: "cancel"; readonly generation: number; readonly requestId: number }
  | { readonly type: "stop"; readonly generation: number; readonly requestId: number }
```

### 12.3 Worker messages

```ts
type WorkerMessage =
  | {
      readonly type: "ready"
      readonly protocolVersion: 2
      readonly generation: number
      readonly extensions: readonly ExtensionLoadResult[]
      readonly tools: readonly ExtensionToolRegistration[]
    }
  | { readonly type: "settled"; readonly generation: number; readonly requestId: number }
  | { readonly type: "tool_result"; readonly generation: number; readonly requestId: number; readonly content: string }
  | { readonly type: "tool_error"; readonly generation: number; readonly requestId: number; readonly message: string }
  | { readonly type: "tool_cancelled"; readonly generation: number; readonly requestId: number }
  | { readonly type: "diagnostic"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }
  | { readonly type: "fatal"; readonly generation: number; readonly diagnostic: ExtensionDiagnostic }
```

Every open-world frame is schema-validated. Exhaustive internal handling begins only after validation.

### 12.4 Correlation and reentrancy

Future Pi-equivalent handlers must be able to call back into Zi while Zi awaits the handler, such as a tool or event requesting a confirmation. The infrastructure therefore supports bidirectional correlated requests from the start:

- host and worker use disjoint request-ID namespaces;
- each side owns one reader loop and one serialized writer;
- the reader loop never blocks while awaiting a dispatched request;
- pending requests are bounded;
- a nested request may settle before its parent request;
- cancellation identifies one request and never means process shutdown;
- process shutdown rejects every pending request exactly once.

Do not implement lockstep request/response I/O or hold one global request mutex across handler execution.

### 12.5 Protocol evolution

The protocol version is negotiated during `initialize`/`ready`. New capability messages extend closed unions. Unsupported versions fail startup with a source-independent protocol diagnostic.

Do not use JSON-RPC method strings, generic payload envelopes inside coding-agent, or an application-wide event bus. The external process seam is the only place where a transport protocol exists.

## 13. Diagnostics

```ts
interface ExtensionDiagnostic {
  readonly extensionId?: string
  readonly path?: string
  readonly phase:
    | "discovery"
    | "trust"
    | "spawn"
    | "handshake"
    | "resolve"
    | "import"
    | "factory"
    | "registration"
    | "lifecycle"
    | "tool"
    | "protocol"
    | "shutdown"
  readonly severity: "warning" | "error"
  readonly message: string
  readonly stack?: string
}

interface ExtensionLoadResult {
  readonly source: ExtensionSource
  readonly status: "loaded" | "failed"
  readonly diagnostic?: ExtensionDiagnostic
}
```

Diagnostics are data returned by coding-agent owners. Workers and components do not write application stderr directly. CLI and TUI modes decide presentation.

Import and factory failures remain local to their source. Fatal worker or protocol failures identify the generation and leave `AgentSession` usable without extensions.

## 14. Initial bounds

The first implementation uses hard limits:

```ts
const maxExtensionSources = 128
const maxExtensionPathBytes = 4 * 1024
const maxExtensionProtocolFrameBytes = 4 * 1024 * 1024
const maxExtensionPendingRequests = 128
const maxExtensionQueuedWriteBytes = 8 * 1024 * 1024
const maxExtensionQueuedWrites = 1024
const maxExtensionDiagnostics = 256
const maxExtensionDiagnosticMessageBytes = 16 * 1024
const maxExtensionDiagnosticStackBytes = 64 * 1024
const maxExtensionLoadDiagnosticMessageBytes = 2 * 1024
const maxExtensionIdBytes = 256
const maxExtensionLifecycleHandlers = 1024
const maxExtensionTools = 64
const maxExtensionToolNameBytes = 64
const maxExtensionToolLabelBytes = 256
const maxExtensionToolDescriptionBytes = 4 * 1024
const maxExtensionToolSchemaBytes = 16 * 1024
const maxExtensionToolArgumentsBytes = 256 * 1024
const maxExtensionToolResultBytes = 256 * 1024
const maxExtensionJsonDepth = 32
const maxExtensionJsonNodes = 4096
const maxExtensionJsonKeyBytes = 4 * 1024
const maxExtensionLogBytesPerStream = 256 * 1024
const extensionStartupTimeoutMs = 30_000
const extensionLifecycleTimeoutMs = 10_000
const extensionShutdownTimeoutMs = 3_000
const extensionToolTimeoutMs = 30_000
const extensionToolCancellationTimeoutMs = 1_000
```

Only the retained tail of stdout/stderr is kept, with an omitted-byte count. Frame bounds apply before JSON allocation. Source and path bounds apply before process startup.

Later capabilities must work within the frame bound through bounded chunks or references; they may not silently increase it for large tool output or images.

There is no automatic worker restart in this slice. Explicit reload is the recovery operation.

## 15. Runtime and mode integration

### 15.1 Runtime bootstrap

```text
open explicit session header if present
  -> derive effective ZiPaths
  -> resolve project trust
  -> discover ExtensionLoadPlan
  -> start ExtensionHost when non-empty
  -> construct cwd-bound settings, resources, models, and session
  -> transfer ExtensionHost ownership to AgentSession
```

Future provider declarations may require host registration before model selection. The host therefore starts before final session construction, but `session_start` is emitted only after the session and selected mode have bound their operations.

### 15.2 Interactive mode

When project trust is unresolved, `InteractiveMode` opens a below-composer picker before positional prompts run. The safe default keeps project configuration disabled; each trust or rejection choice is explicitly session-only or saved for the canonical cwd. `AgentSessionRuntime` applies the choice by replacing the whole cwd-bound runtime, so no protected owner is mutated into a newly trusted state. The TUI receives authoritative trust data and operations but no worker process or mutable extension registry.

Terminal shutdown restores OpenTUI before awaiting bounded extension settlement.

### 15.3 Text and JSON modes

Text and JSON modes load the same extension generation. Without a stored or runtime trust decision, they exclude project sources and report a diagnostic on stderr through the CLI owner. No TUI module is loaded.

### 15.4 Session replacement

`AgentSessionRuntime` continues to replace whole cwd-bound runtimes. A candidate runtime includes its own trust decision, extension plan, and host. Failure before runtime commit preserves the old session and old extension generation.

## 16. Failure policy

| Failure                          | Result                                                                               |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| Missing or unsupported source    | Source diagnostic; continue                                                          |
| Import failure                   | Source diagnostic; continue                                                          |
| Factory rejection                | Source diagnostic; continue                                                          |
| Invalid or conflicting tool      | Source registration diagnostic; omit that tool and continue                          |
| Tool rejection                   | Settle that invocation with an error; keep the generation reusable                   |
| Tool execution/cancel deadline   | Fatal generation failure and forced teardown                                         |
| Pending async factory timeout    | Source diagnostic when worker remains responsive; otherwise fatal generation failure |
| Infinite loop or blocked worker  | Kill candidate/current generation after deadline; Zi remains usable                  |
| Malformed or oversized frame     | Fatal generation protocol failure                                                    |
| Unknown protocol version/message | Fatal generation protocol failure                                                    |
| Lifecycle handler rejection      | Diagnostic; continue remaining handlers                                              |
| Lifecycle deadline               | Fatal generation failure and forced teardown                                         |
| Worker crash during startup      | Initial host becomes failed; session starts without extensions                       |
| Candidate crash during reload    | Candidate destroyed; current generation retained                                     |
| Current worker crash             | Host becomes failed; session remains usable; explicit reload may recover             |
| Shutdown timeout                 | Force-kill, release resources, report bounded diagnostic                             |
| Stale generation frame           | Ignore and count structurally; never mutate current state                            |

A failed extension host never aborts an active provider run merely because extension infrastructure disappeared. Active extension-tool invocations reject exactly once, the admitted catalog is removed, and the session remains usable without that generation.

## 17. Testing strategy

Tests fix behavior at the owners' interfaces rather than exposing private registries.

### 17.1 Discovery tests

Cover:

- exact `ZiPaths` roots;
- global/project/explicit scope;
- deterministic sorted order;
- file and one-level directory entries;
- canonical deduplication;
- symlink behavior;
- missing and unreadable sources;
- source and path bounds;
- cancellation and descriptor cleanup;
- project exclusion before trust.

### 17.2 Protocol tests

Cover:

- partial prefix and payload reads;
- multiple frames in one read;
- UTF-8 boundaries;
- malformed length, JSON, and message unions;
- frame and write-queue bounds;
- bidirectional request-ID separation;
- nested request settlement;
- cancellation races;
- stale generation frames;
- pending-request rejection on process exit;
- reader, writer, and listener cleanup.

### 17.3 Host transition tests

Use a controlled process adapter to prove:

- forbidden transitions;
- empty-plan laziness;
- startup success and failure;
- per-source diagnostic isolation;
- one admitted reload;
- fatal candidate failure preserving current;
- successful replacement invalidating old callbacks;
- shutdown superseding replacement;
- crash during every state;
- lifecycle rejection and timeout;
- bounded diagnostics and log tails;
- one settlement per request;
- final disposal idempotence.

### 17.4 Worker tests

Fixture extensions prove:

- empty factory;
- async factory;
- invalid default export;
- import failure;
- factory rejection;
- lifecycle registration and ordering;
- local module import;
- Node built-in import;
- local npm dependency import;
- stdout/stderr isolation;
- pending promise timeout;
- process crash;
- infinite loop containment.

### 17.5 Compiled acceptance

The release-shaped acceptance test:

1. compiles Zi with the pinned Bun version;
2. starts the executable with a temporary global extension;
3. loads TypeScript and one local npm dependency;
4. observes ready and lifecycle settlement through a test-only external effect;
5. reloads to a new generation;
6. proves the old process is gone;
7. exits with no leaked process or temporary artifact.

CI uses deterministic process and resource assertions rather than wall-clock performance thresholds.

## 18. Implementation slices

### Slice A — runtime probe and decision

Deliver:

- [x] throwaway self-hosted Bun worker probe;
- [x] external TypeScript, Node built-in, npm dependency, extra pipe, crash, and hang fixtures;
- [x] release-platform results;
- [x] ADR selecting a self-hosted Bun worker with portable Node-compatible process pipes;
- [x] deletion of the temporary prototype.

No production extension abstraction lands in this slice.

### Slice B — trust and discovery

Progress:

- [x] `ZiPaths`-owned global trust path;
- [x] bounded canonical persistence with nearest-parent lookup;
- [x] exact protected-project-configuration detection;
- [x] trust resolution and coordinated project gating;
- [x] bounded immutable extension discovery.

Likely files:

- `packages/coding-agent/src/paths.ts`
- `packages/coding-agent/src/settings-manager.ts`
- `packages/coding-agent/src/resource-loader.ts`
- `packages/coding-agent/src/extensions/discovery.ts`
- coding-agent tests

Deliver:

- project-trust owner and persisted/runtime decisions;
- coordinated gating of every project configuration owner;
- bounded immutable extension source discovery;
- deterministic `ExtensionLoadPlan`;
- diagnostics and explicit path admission;
- no worker process yet.

### Slice C — protocol and worker loader

Progress:

- [x] closed versioned messages, validation, framing, and bounded serialized writers;
- [x] internal CLI worker mode over stdin and a dedicated descriptor-three pipe;
- [x] external TypeScript, Node built-ins, local dependencies, and async factory settlement;
- [x] lifecycle registration, deterministic dispatch, diagnostics, deadlines, and transition rejection;
- [x] protocol-v2 tool registration, schema validation, execution, and cancellation;
- [x] runtime-valued `@with-zi/extension-api` availability from compiled workers.

Likely files:

- `packages/coding-agent/src/extensions/protocol.ts`
- `packages/coding-agent/src/extensions/worker.ts`
- extension API package or generated virtual module
- worker/protocol tests

Deliver:

- closed protocol unions and validation;
- framing and bounded writers;
- TypeScript loader;
- source metadata and per-extension results;
- async factory barrier;
- lifecycle and custom-tool registration;
- compiled public API module.

### Slice D — `ExtensionHost`

Progress:

- [x] explicit host and generation states with forbidden-transition rejection;
- [x] lazy empty plans, bounded startup, correlated lifecycle requests, and deterministic diagnostics;
- [x] current/candidate ownership with candidate-failure rollback and process-based replacement;
- [x] stale-frame rejection plus bounded stdout and stderr tails;
- [x] shutdown supersession, graceful stop, termination, force-kill, and idempotent disposal;
- [x] controlled transition tests and real CLI-worker process coverage;
- [ ] worker-initiated correlated request types, deferred until the first capability requires one.

Likely files:

- `packages/coding-agent/src/extensions/host.ts`
- host transition tests

Deliver:

- explicit host state;
- process and generation ownership;
- request correlation and reentrancy;
- startup, replacement, shutdown, and disposal;
- diagnostics and retained log tails;
- stale-generation rejection;
- all bounds.

### Slice E — runtime and session integration

Progress:

- [x] repeatable explicit extension paths admitted by CLI and runtime options;
- [x] trust-gated discovery and host startup before final session construction;
- [x] `AgentSession` ownership of start, shutdown, diagnostics, and bounded settlement;
- [x] whole-runtime replacement keeps candidates unbound until the current lifecycle retires;
- [x] text and JSON modes share the same lifecycle without contaminating stdout;
- [x] terminal restoration remains outside and before extension disposal settlement;
- [x] compiled product acceptance exercises the production `ExtensionHost` path.

Likely files:

- `packages/coding-agent/src/runtime.ts`
- `packages/coding-agent/src/sdk.ts`
- `packages/coding-agent/src/agent-session.ts`
- `packages/coding-agent/src/agent-session-runtime.ts`
- `packages/cli/src/args.ts`
- mode and runtime tests

Deliver:

- explicit extension paths reaching coding-agent;
- host construction and ownership transfer;
- lifecycle binding;
- session replacement behavior;
- text/JSON diagnostic behavior;
- terminal-shutdown ordering unchanged.

### Slice F — packaging and documentation

Progress:

- [x] canonical custom-tool example and author guide;
- [x] compiled worker acceptance for the example and public API module;
- [x] release-package assembly for `@with-zi/extension-api`;
- [ ] compiled interactive, text, and JSON acceptance on every release target.

Likely files:

- `scripts/compile-zi.ts`
- release scripts and workflows
- public manual pages
- compiled acceptance tests

Deliver:

- worker or self-host assets in every release artifact;
- no install-time downloader;
- official extension API virtual-import availability;
- infrastructure diagnostics and lifecycle documentation;
- third-party notice updates for the selected loader/runtime dependencies.

## 19. Acceptance checklist

The extension infrastructure is complete when:

- [x] the worker-runtime probe has selected and documented one mechanism;
- [x] all project configuration, including extensions, shares one trust decision;
- [x] global, project, and explicit sources produce a deterministic bounded load plan;
- [x] no extension source causes ambient cwd or `.zi` path derivation;
- [x] an empty plan creates no subprocess or materialized worker;
- [x] the compiled executable loads external TypeScript;
- [x] extension-local npm dependencies and Node built-ins resolve;
- [x] async factories are awaited before ready;
- [x] every loaded or failed extension retains stable source metadata;
- [x] import and factory failures are source-attributed and non-fatal;
- [x] a blocked factory cannot freeze Zi or the TUI;
- [x] protocol frames, queues, logs, requests, sources, diagnostics, and waits are bounded;
- [ ] nested bidirectional requests cannot deadlock the protocol;
- [x] candidate fatal failure preserves the current generation;
- [x] successful replacement rejects all stale-generation work;
- [x] lifecycle handlers run in deterministic order;
- [x] lifecycle and shutdown waits are bounded;
- [x] a worker crash leaves `AgentSession` usable;
- [x] terminal restoration still precedes bounded extension settlement;
- [x] final disposal leaves no `ExtensionHost`-owned worker process, listener, pipe, callback, or temporary artifact;
- [x] text and JSON modes do not load OpenTUI;
- [x] no commands, providers, UI contributions, generic event bus, or package manager entered with custom tools;
- [x] formatting, linting, typechecking, unit tests, and compiled acceptance pass.

## 20. Capability sequence after infrastructure

Once this substrate is accepted, capabilities should arrive independently in this order unless user evidence changes the priority:

1. custom tools and bounded tool execution — implemented;
2. project/global extension lifecycle and explicit reload UX;
3. agent and tool interception events;
4. commands and durable extension state;
5. declarative and executable provider registration;
6. session-tree hooks after Zi owns branch navigation;
7. terminal contributions after OpenTUI keymap adoption;
8. package install, update, remove, and source provenance.

Each slice adds closed protocol messages, behavior tests, and upstream provenance. No slice expands a generic extension facade in anticipation of later ones.

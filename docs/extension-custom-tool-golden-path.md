# Custom-tool extension golden path

- Status: target
- Product milestone: teach Zi one executable habit without modifying Zi
- Authoritative product owner: `AgentSession`
- Infrastructure owner: coding-agent `ExtensionHost`

## User outcome

A user adds one TypeScript extension beneath the current project's `.zi/extensions/`, trusts that project, starts the compiled Zi executable, and lets the model invoke the extension's tool. The same extension works in interactive, text, and JSON modes without importing Zi internals or building a separate bundle.

The canonical [`repository_status` example](../examples/extensions/custom-tool/index.ts) is a small repository-specific tool with typed arguments, cooperative cancellation, and a bounded textual result. It is meant to be copied and changed by a person or coding agent, not to demonstrate every future extension capability.

## Authoring path

The extension author should need only to:

1. create `.zi/extensions/<name>/index.ts`;
2. optionally install dependencies beside that extension;
3. import the public `@with-zi/extension-api` contract;
4. export one synchronous or asynchronous factory;
5. register one named tool with a description, argument schema, and asynchronous execution;
6. run Zi, choose **Trust and remember** in the project-trust picker, and let Zi reload the project runtime.

No separate TypeScript build, generated manifest, OpenTUI dependency, coding-agent import, or package publication is required.

## Ownership path

```text
ZiPaths + project trust
  -> immutable ExtensionLoadPlan
  -> ExtensionHost generation
      -> extension factory registration
      -> bounded tool invocation in worker
  -> AgentSession authoritative tool catalog and invocation lifecycle
  -> interactive | text | JSON mode presentation
```

- `ZiPaths` supplies exact global and project roots.
- The project-trust owner gates all project settings, resources, and executable extensions together.
- `ExtensionHost` owns the worker, protocol, registrations, invocation correlation, cancellation, diagnostics, and teardown.
- `AgentSession` decides whether the tool joins a session and exposes the same tool to every mode.
- The TUI renders client-neutral tool presentation and never receives extension JavaScript or worker resources.

## End-to-end acceptance

### Loading and trust

- The release-shaped executable discovers the project extension only beneath the exact session cwd.
- No project extension code or package metadata executes before trust admission.
- A stored trust decision works across launches; rejecting trust excludes all project configuration covered by that decision.
- TypeScript, relative imports, Node built-ins, and one extension-local npm dependency load without a separate build.
- A missing, malformed, or rejected extension produces a bounded source-attributed diagnostic and does not prevent Zi startup.

### Registration

- The extension factory may settle asynchronously.
- One valid tool registration joins the session's authoritative tool catalog before the first provider request.
- Invalid names, descriptions, schemas, duplicates, and registration counts are rejected at the host boundary with source attribution.
- The public extension interface does not expose `AgentSession`, `SessionManager`, model credentials, OpenTUI renderables, or private protocol values.
- Extensions are trusted JavaScript with the authority of the Zi user account: they may read `auth.json` or the environment, spawn processes, and interfere with worker-local resources. Worker processes provide fault containment, not a sandbox or credential-confidentiality boundary.

### Invocation

- A faux provider can select the custom tool during a real agent turn.
- Arguments are validated before extension code receives them.
- Invocation crosses bounded correlated IPC; model-facing content and client-neutral result facts remain bounded.
- Successful output returns through the normal Pi tool-result path and appears exactly once in durable session history.
- Run interruption cancels the invocation without disposing the reusable extension generation.
- Terminal shutdown restores OpenTUI before bounded invocation and worker settlement.

### Presentation and modes

- Interactive mode preserves one transcript identity from preparing through durable result.
- Custom tools use the existing generic presentation unless a later semantic presentation contract is explicitly added.
- Text mode continues to emit only final assistant text.
- JSON mode emits ordered tool lifecycle and result events without extension logs corrupting stdout.
- Extension stdout and stderr are retained only through bounded, source-attributed diagnostics/log tails.

### Failure containment

- Import and factory failure affect only the originating extension.
- A thrown tool error settles that invocation once and leaves the session and generation usable.
- Malformed or oversized protocol data fails the generation without crashing Zi.
- A worker crash settles pending invocations, leaves `AgentSession` usable without extensions, and requires explicit reload to recover.
- A blocked factory or invocation is killed after its deadline and cannot freeze the TUI.
- Stale completions from a replaced generation cannot mutate the current session.
- Final disposal releases every `ExtensionHost`-owned worker process, pipe, listener, request, timer, and temporary artifact. Extensions own processes they spawn and should stop them during `session_shutdown`; Zi does not guarantee cleanup of detached or otherwise surviving descendants.

### Distribution

- `@with-zi/extension-api` is the only supported package import.
- `examples/extensions/custom-tool/` is copyable, documented, and run against the compiled executable in CI.
- Acceptance passes on macOS arm64/x64, Linux arm64/x64, and Windows x64.

`scripts/extension-custom-tool-acceptance.ts` owns the release-shaped check. It copies the canonical source into a trusted temporary project's `.zi/extensions/`, starts a bounded local Responses provider, requires the provider to select `repository_status`, verifies the tool result on the second request, and runs the complete turn in text, JSON, and interactive modes. Interactive acceptance drives the native executable through Bun's PTY on POSIX and bounded stdio pipes on Windows; it verifies the final assistant presentation and terminal restoration (alternate-screen exit on POSIX and cursor restoration on Windows). The provider boundary verifies the exact tool result because incremental terminal frames do not guarantee that an already-visible row appears contiguously in the raw terminal byte stream. `scripts/build-release.ts` runs this check before archiving every native artifact.

## Launch boundary

Lifecycle-only loading is an infrastructure milestone. Zi calls the extension platform usable only when the custom-tool example passes this document against a compiled release on every supported platform.

## Non-goals for the first path

- commands, shortcuts, or extension CLI flags;
- agent/tool interception hooks;
- providers or models;
- durable extension-owned entries;
- direct UI or OpenTUI contributions;
- package installation, update, registry, or marketplace behavior;
- Pi source compatibility;
- automatic worker restart;
- publishing `@with-zi/coding-agent`.

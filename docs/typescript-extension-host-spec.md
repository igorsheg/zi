# TypeScript extension host infrastructure specification

- Status: approved infrastructure direction; ready for phased implementation
- Date: 2026-07-12
- Product owner: `coding_agent.RuntimeServices`
- Mechanism owners: `src/runtime` for persistent child-process I/O; `src/coding_agent` for extension-host policy
- Runtime language: TypeScript on Node.js
- Distribution decision: the compiled host bundle is embedded in the Zi binary with `@embedFile`
- Public extension API: deliberately out of scope

## 1. Purpose

Zi will support trusted TypeScript extensions with normal Node.js capabilities,
including `node:fs`, `node:child_process`, networking, package resolution, and
npm dependencies. Zi remains a Zig-owned application: Node is a supervised
extension runtime, not Zi's process owner.

This specification establishes only the infrastructure required for that system
to grow safely:

- the TypeScript host project and reproducible build;
- embedding and materializing the host bundle;
- Node command resolution and version negotiation;
- one long-lived Node child process;
- bounded, bidirectional, framed IPC;
- request correlation, cancellation, and deadlines;
- owner-loop wake integration;
- crash, shutdown, and atomic replacement behavior;
- project-trust and process-permission boundaries;
- deterministic tests and implementation phases.

It does not specify which extension events, tools, commands, providers, UI
operations, renderers, or session actions Zi will expose.

## 2. Product decision

The extension runtime has this shape:

```text
Zi process
  cli
    -> concrete frontend
       -> RuntimeServices
          -> ExtensionHost                    coding-agent policy owner
             -> runtime persistent child      process mechanism
                -> node <materialized-host>
                   -> embedded host bundle
                   -> TypeScript module loader
                   -> trusted extensions
```

The direction of ownership is binding:

```text
Zig owns Node; Node does not own or embed Zig.
```

Zi will not become a Node native addon, embed V8/libnode, emulate Node APIs over
QuickJS, or introduce Lua alongside TypeScript for the initial extension system.

## 3. Design constraints

### 3.1 Preserve gen-3 ownership

The process boundary justifies an external protocol; it does not justify an
in-process translation corridor.

- `RuntimeServices` owns the extension host lifetime.
- Future product owners call `ExtensionHost` directly and receive typed operation
  handles or typed inbound requests.
- Reader/writer tasks never mutate `Loop`, `AgentSession`, `Transcript`, settings,
  or session persistence.
- A wake carries no payload. After waking, the current frontend owner polls
  `ExtensionHost` and applies work through direct owner methods.
- No extension event bus, Engine, ViewModel, client protocol, or duplicate
  transcript model may be introduced.
- External JSON-RPC envelopes end at `ExtensionHost`; they do not travel through
  Zi as a second internal protocol.

### 3.2 One bounded owner

`ExtensionHost` is allowed to contain locally complex lifecycle and correlation
logic because it owns the whole boundary. Do not split framing, pending calls,
reload state, and generation state among independently synchronized product
modules.

`src/runtime` owns only reusable mechanism:

- spawn a persistent child with explicit `std.Io` and environment;
- expose or drive its stdin, stdout, stderr, wait, terminate, and kill paths;
- guarantee that deinit cannot race worker-visible memory.

`src/runtime` must not know extension paths, Node versions, JSON-RPC method
names, trust, reload policy, or extension diagnostics.

### 3.3 Optional runtime cost

Zi must not start Node merely because extension support was compiled in. A
caller supplies an `ExtensionLoadPlan`. An empty or disabled plan creates no
child process and does no cache materialization.

How settings, CLI flags, and resource discovery produce that load plan is a
later product specification.

### 3.4 Zi responsiveness guarantee

For extension-caused failures contained to the extension boundary, the required
guarantee is:

> A TypeScript extension may block or crash its Node host, but it cannot run on,
> synchronously wait on, or otherwise block Zi's TUI owner loop.

This guarantee is structural, not cooperative:

- extension JavaScript executes only in the child process;
- Zi does not load extension native libraries, Node-API addons, V8, or extension
  code into its own address space;
- the child receives protocol stdin/stdout/stderr only; Zi does not pass its
  terminal descriptor, runtime internals, pointers, shared memory, or owner-state
  handles;
- every post-startup Zig -> Node call starts an operation and returns to the
  caller without waiting for Node;
- the TUI only polls already-published state using fixed count/byte work budgets;
- pipe reads, writes, process waiting, framing, JSON validation, encoding, and
  expensive payload copying/decoding execute in runtime tasks, never in
  `Loop.step`;
- every operation that waits on Node has an owner-supplied deadline maintained
  by Zig's clock and supervisor, independent of Node's event loop;
- an unresponsive host is terminated and then force-killed as a process group;
- cancellation and shutdown are request -> observe completion; Zi never frees
  task-visible memory merely because kill was requested.

Initial activation may delay process bootstrap before the TUI starts, but it is
bounded by the startup deadline. Reload, invocation, cancellation, and shutdown
after the frontend starts are always operation-backed and polled.

This does not claim machine isolation. Trusted extensions may exhaust host CPU,
memory, file descriptors, disk, or process limits, or deliberately spawn detached
work. Such machine-wide resource exhaustion can affect Zi like any other
process. Within normal OS scheduling and memory availability, a JavaScript
infinite loop is confined to Node and expires through Zig's independent deadline
and process supervision.

## 4. Domain model

### Extension host

The supervised Node process plus the Zig owner that manages it. It executes
trusted extension code and requests actions from Zi owners. It owns no agent,
session, transcript, settings, or TUI state.

### Host asset

The compiled, self-contained JavaScript module embedded into the Zi executable.
It contains the host runtime and TypeScript loader, but not user extensions.

### Materialized host

A verified filesystem copy of the embedded host asset. Node requires a file to
execute while stdin remains available for protocol traffic.

### Extension load plan

A bounded, immutable startup input containing canonical extension module paths
and their resolved provenance. Trust is decided before a project-local path may
enter the plan.

### Host generation

One child process running one host asset and one load plan. Requests and
responses are generation-scoped so stale completion from a replaced process
cannot affect the active process.

### Host operation

A Zig-initiated request with an owned deadline, cancellation state, and typed
terminal result. Starting an operation does not imply completion.

### Inbound host request

A Node-initiated request for an action owned by Zi. `ExtensionHost` validates and
queues it; the relevant product owner decides and replies. The concrete methods
are outside this specification.

## 5. Source and build layout

Create the following initial layout:

```text
extensions/
  host/
    package.json
    package-lock.json
    tsconfig.json
    scripts/
      build.mjs
    src/
      main.ts
      framing.ts
      transport.ts
      loader.ts
      protocol.ts
    test/
      fixtures/
      *.test.ts
src/
  coding_agent/
    ExtensionHost.zig
    extension_host_asset.zig
  runtime/
    duplex_child.zig
```

Names may change before implementation only if the final ownership remains the
same. Do not create a generic `plugins` framework around these files.

### 5.1 Node project policy

The host package uses:

- exact, lockfile-pinned versions;
- `jiti` as the runtime TypeScript module loader;
- TypeScript for type checking with `noEmit`;
- a small Node-targeted bundler, initially `esbuild`, to produce one ESM file;
- Node's built-in test runner unless a concrete test need proves otherwise.

Initial `package.json` dependency roles:

```text
dependencies:
  jiti              runtime behavior, bundled into the host asset

devDependencies:
  esbuild           create the self-contained host asset
  typescript        no-emit host type checking
  @types/node       host type definitions
```

All versions are exact rather than ranges. `package-lock.json` is committed.
`npm ci` is never run implicitly by `zig build`; builds must not initiate network
access. A missing `node_modules` produces a direct setup diagnostic telling the
developer to run:

```sh
npm --prefix extensions/host ci
```

This deliberately makes a compatible Node installation and the locked host
packages source-build prerequisites, even when the resulting Zi invocation will
not enable extensions. Release users still need Node only when a non-empty load
plan is activated. Do not hide the source-build prerequisite behind an automatic
download or silently use a globally installed bundler.

### 5.2 TypeScript policy

The host source is type checked under strict settings and targets the minimum
supported Node version. User extension loading uses `jiti/static`, not Node's
built-in type stripping, because native stripping intentionally excludes valid
TypeScript forms and ignores `tsconfig.json`.

The initial host does not promise arbitrary extension `tsconfig` path aliases.
Package and relative import resolution must work normally. Any later alias or
virtual-module behavior belongs to the public extension API specification.

Jiti's filesystem and module caches are disabled initially. Reload is a host
generation replacement, so keeping transpiled extension state outside the
generation would weaken atomicity and create another unbounded cache. A bounded
transpile cache may be specified later only with an owner, invalidation rule,
and eviction policy.

### 5.3 Bundle output

`extensions/host/scripts/build.mjs` accepts an explicit output path supplied by
the Zig build and produces exactly one deterministic ESM bundle:

```text
extension-host.mjs
```

Required bundle properties:

- `platform=node`;
- ESM output;
- `jiti/static` bundled into the asset;
- no runtime dependency on Zi's `node_modules`;
- no user extension bundled into the asset;
- inline source map for actionable host stack traces;
- stable banner containing the host protocol version;
- maximum output size of 8 MiB, enforced by the build.

The build script must not include timestamps, absolute checkout paths, random
identifiers, or other nondeterministic bytes.

### 5.4 Zig build integration

The generated bundle is a Zig build output (`LazyPath`), not a checked-in `dist`
artifact. Both the library and executable modules receive it as an anonymous
file import named `extension_host_bundle`. The owning Zig declaration embeds it:

```zig
pub const bytes = @embedFile("extension_host_bundle");
```

The exact Zig 0.16 build API must be verified against the local toolchain, but
the dependency graph is binding:

```text
host typecheck
      +
host bundle command -> generated LazyPath
                           -> Zig compile using @embedFile
```

`zig build`, `zig build test`, and release builds cannot compile against a stale
bundle. The bundle command must be a dependency of every artifact importing
`RuntimeServices`.

The JavaScript source is present once in each final executable image. Do not
also install an adjacent host file.

## 6. Embedded asset materialization

### 6.1 Why materialization exists

Passing the bundle through `node --eval` risks platform argument limits and poor
stack paths. Passing it through stdin consumes the duplex protocol input. Zi
therefore writes the embedded bytes to a content-addressed cache before spawn.

### 6.2 Path ownership

All directory and environment names are declared in
`src/coding_agent/paths.zig`. The initial derived-cache shape is:

```text
<agent-dir>/cache/extension-host/<sha256>/extension-host.mjs
```

No extension-host path component may be hardcoded outside the path owner.

### 6.3 Integrity and races

`extension_host_asset.zig` exposes the embedded bytes and their SHA-256 digest.
The materializer must:

1. reject an embedded bundle larger than 8 MiB;
2. create cache directories with user-only permissions where supported;
3. verify an existing target's size and SHA-256 before every launch;
4. write a mismatched or missing target through a uniquely named temporary file;
5. flush and atomically publish the complete file;
6. tolerate another Zi process publishing the same digest concurrently;
7. verify the winning target after a publication race;
8. never launch a partial or unverified file.

The materialized file is read-only to the user where practical. File permissions
are defense in depth; digest verification is the authority.

A materialization failure disables the extension subsystem for that startup and
returns a typed diagnostic. It must not corrupt an already verified generation.

### 6.4 Cache bound

The cache is derived state, not durable configuration. On materialization, Zi
best-effort evicts old host digest directories while preserving the current
asset. The bound is:

- at most 4 host versions;
- at most 32 MiB total host bundle bytes;
- current embedded version is never evicted by its own process.

Each active or starting generation holds a lease on its digest from final
verification until child exit. The lease uses a shared advisory lock; eviction
requires the corresponding exclusive lock. If reliable locking is unavailable
on a platform, Zi skips eviction there rather than racing another process's
spawn. Stale lock files are harmless because lock ownership, not file presence,
is authoritative.

Eviction failure is diagnostic-only unless the current asset cannot be
materialized. Cache traversal and deletion work must run outside the TUI owner
loop.

## 7. Node resolution

### 7.1 Command resolution

`ExtensionHost.Options` receives an explicit argv when supplied by tests or a
future setting. Otherwise resolution is:

1. `ZI_NODE`, interpreted as one executable path or name without shell parsing;
2. `node` resolved through the inherited `PATH`.

Zi never invokes a shell to launch the host. An argv-capable `nodeCommand`
setting may be specified later without changing the process boundary.

### 7.2 Supported runtime

The initial minimum is Node 22.19.0, matching the Pi reference baseline. The host
reports `process.versions.node` during handshake. Zig validates it and rejects an
unsupported major/minor version before any extension module is loaded.

Bun, Deno, and other Node-compatible runtimes are not accepted implicitly. They
may become explicit, tested runtime choices later.

### 7.3 Child environment

The child receives an explicitly supplied environment map derived from Zi's
process environment. The host may add namespaced internal variables, but secrets
are not stripped: trusted extensions intentionally have the same user-level
capabilities as Zi.

The child cwd is the `RuntimeServices.cwd` associated with the load plan.

## 8. Persistent child-process mechanism

`src/runtime/duplex_child.zig` is a concrete persistent-process mechanism, not a
generic plugin manager. It owns:

- one `std.process.Child`;
- piped stdin, stdout, and stderr;
- one process-wait task;
- reader/writer task lifetimes;
- graceful close, termination, force-kill, wait, and join;
- process-group termination on platforms where Zi's existing process policy
  supports it.

It does not parse JSON or know Node.

The implementation reuses Zi's existing runtime patterns rather than creating a
second concurrency model:

- receive `std.Io` and `*runtime.Runtime` explicitly from `RuntimeServices`;
- keep zio private behind `src/runtime/zio_backend.zig`;
- use zio-backed `std.Io.concurrent`/runtime tasks for pipe I/O and process wait;
- use `spawnBlocking` for CPU work whose bounded worst case can exceed a frame
  budget, including large frame validation or product payload decoding;
- publish into caller-owned, fixed-capacity queues/slots and signal a
  payload-free `runtime.WakeEvent`;
- follow the existing `process_runner.zig` race shape for wait, deadline,
  cancellation, grace termination, stdout completion, and stderr completion;
- follow `EventPipe`/`std.Io.Queue` backpressure rather than unbounded lists;
- join every task before releasing the child, queues, buffers, or generation.

Each generation owns a fixed task set: one stdout framing reader, one serialized
stdin writer, one bounded stderr reader, one process waiter, and at most one
serial CPU decode worker. It does not spawn a task per frame or per request.
Atomic replacement therefore raises the fixed maximum to two task sets, matching
the two-generation bound.

The duplex child must not use a raw worker callback to call `Loop`,
`AgentSession`, or another product owner. Cross-task mutexes protect only small
bounded transport structures, never product state.

The mechanism follows request -> observe completion semantics:

```text
request stop
  -> stop accepting writes
  -> close/drain according to policy
  -> wait for process result
  -> join reader/writer/wait tasks
  -> release worker-visible memory
```

`deinit` is valid only after terminal completion has been observed. Debug builds
assert this contract.

Termination progress cannot depend on cooperative child I/O or EOF. When the
owned deadline expires, the supervisor stops queue acceptance, cancels and/or
closes its pipe operations, terminates the process group, observes the process
result, and awaits the canceled I/O tasks. A child that never reads stdin, floods
stdout, or leaves a descendant holding a pipe open cannot make Zi wait without a
supervisor deadline. Force-kill progression uses reserved owner state and does
not need capacity in either protocol queue.

The existing `runtime.runProcess` remains the owner of run-to-completion tools.
Do not contort it to support a persistent duplex child.

## 9. Transport protocol

### 9.1 Stream ownership

- Zig writes protocol frames to child stdin.
- Node writes protocol frames to child stdout.
- Child stderr is diagnostics only.
- Before loading extensions, the host captures a private bound reference to the
  original stdout writer for transport and replaces public `process.stdout.write`
  plus `console` methods with bounded diagnostic writers to stderr.
- Extensions must not write directly to stdout; stdout is reserved for protocol.

A trusted extension can still open file descriptor 1 directly. That is not
sandboxed. Any resulting malformed protocol fails the host generation rather
than attempting resynchronization.

### 9.2 Framing

Use LSP-style framing over byte streams:

```text
Content-Length: <decimal bytes>\r\n
\r\n
<UTF-8 JSON body>
```

Parser requirements:

- maximum header block: 1 KiB;
- exactly one `Content-Length` header;
- decimal, non-negative length with checked arithmetic;
- maximum body: 8 MiB;
- exact reads; partial pipe reads are normal;
- EOF in a header or body is terminal truncation;
- body must be valid UTF-8 and one valid JSON object;
- maximum JSON nesting depth: 64;
- maximum JSON token count: 262,144;
- maximum decoded method name: 128 bytes;
- maximum decoded request ID: 64 bytes;
- malformed input terminates the generation;
- no scan-forward or stream resynchronization.

The framing task does not build an unrestricted `std.json.Value` tree. It
validates envelope structure with a streaming scanner, enforces the structural
bounds above, and retains owned raw parameter/result slices. Infrastructure
methods and future typed extension methods decode those slices directly into
bounded typed values inside `ExtensionHost`.

### 9.3 Envelope

Use JSON-RPC 2.0 envelopes because communication is bidirectional and needs
correlated requests, replies, errors, and notifications. IDs are transport-only
strings:

```text
z:<counter>    Zig-originated request
n:<counter>    Node-originated request
```

Counters use checked increment and never recycle within a generation. A response
with the wrong direction, unknown ID, duplicate terminal response, or stale
generation is a protocol error.

Only infrastructure methods are reserved here:

```text
host/initialize
host/loadExtensions
host/initialized
host/ping
host/shutdown
host/cancel
```

Their payloads carry protocol negotiation, liveness, shutdown, and cancellation
only. Names and schemas for extension-facing behavior are out of scope.

### 9.4 Version negotiation

The initialize exchange includes:

- protocol major and minor;
- embedded host SHA-256;
- Zi version;
- Node version;
- host implementation version;
- cwd;
- a generation nonce generated by Zig.

A major mismatch rejects startup. Minor compatibility is accepted only when both
sides explicitly advertise the needed infrastructure capability. Do not silently
continue after a version mismatch.

## 10. Bounds and failure policy

All values below are initial infrastructure constants and must live with the
owner that enforces them.

| Accumulation/work | Bound | At the bound |
|---|---:|---|
| Embedded host asset | 8 MiB | Build/runtime reject |
| Frame header | 1 KiB | Terminate generation |
| One frame body | 8 MiB | Terminate generation |
| JSON nesting / tokens | 64 / 262,144 | Terminate generation |
| Inbound queue | 32 frames and 16 MiB | Reader backpressure |
| Outbound application lane | 24 frames and 15 MiB | Reject new operation as busy |
| Outbound control lane | 8 frames and 1 MiB | Backpressure; failure terminates generation |
| Zig-originated pending requests | 64 | Reject new operation as busy |
| Node-originated pending requests | 32 | Reply overloaded |
| Load-plan entries | 128 | Reject plan before spawn |
| One canonical path | 16 KiB UTF-8 | Reject entry |
| Startup/handshake | 5 seconds | Terminate generation |
| Graceful shutdown response | 1 second | Close/terminate |
| Termination grace before kill | 250 ms | Force-kill process group |
| Retained stderr tail | 256 KiB | Evict oldest bytes |
| Total stderr per generation | 16 MiB | Terminate noisy generation |
| Simultaneous generations | 2 during replacement | Reject another replacement |
| Materialized host cache | 4 versions / 32 MiB | Best-effort evict old versions |
| Node V8 old-space | 512 MiB | Node terminates on exhaustion |

Queue limits are both count- and byte-based. An owned frame is charged before
allocation/publication and released after its consumer deinitializes it. Replies,
cancellation, shutdown, and protocol errors use the reserved control lane so an
application flood cannot prevent protocol progress. The writer prioritizes
control traffic but services application traffic with bounded fairness.

Application requests added later must supply a deadline explicitly. The
infrastructure does not invent one timeout for all future extension behavior.
Cancellation is terminal only after a response, host exit, or deadline policy
settles the operation. No public or internal TUI call may expose a synchronous
"invoke extension and wait" path.

Framing validation and infrastructure-envelope decoding run outside the TUI
owner loop. Future product payload decoding that can exceed a frame budget must
also run in a bounded task. Polling moves validated owned envelopes or typed
results; it does not parse an 8 MiB JSON body or execute extension behavior.

The frontend integrates extension work into the existing `Loop.step` order after
input has been drained and before composition. One iteration may observe at most:

- 32 already-decoded infrastructure transitions;
- 256 KiB of owner-side payload inspection;
- any stricter per-capability limit established by the owning product API.

Reaching a limit leaves work queued, sets the same coalesced owner wake, and
returns to render/input. It does not increase the budget to catch up. Future
capabilities whose one indivisible application step can exceed the watchdog
budget must complete that step in a bounded runtime task and publish a typed
result. The TUI debug watchdog receives no extension exemption.

## 11. `ExtensionHost` ownership and API shape

The initial Zig API is infrastructure-only and should remain small:

```text
ExtensionHost.init(..., load_plan)
ExtensionHost.setWake(...)
ExtensionHost.start()
ExtensionHost.poll(now)
ExtensionHost.nextDeadline()
ExtensionHost.startPing(deadline)
ExtensionHost.cancel(handle)
ExtensionHost.beginReplacement(load_plan)
ExtensionHost.requestShutdown()
ExtensionHost.shutdownComplete()
ExtensionHost.deinit()
```

This is shape, not required spelling. Required semantics:

- only `ExtensionHost` mutates generation, request, queue, and diagnostic state;
- request handles are typed, generation-scoped, and caller-deinitialized;
- the generic JSON-RPC send/correlation mechanism is private;
- each future capability adds a direct typed host method rather than exposing a
  method-name-plus-JSON API to product callers;
- borrowed payloads are valid only for the owner call that returns them;
- product callers do not inspect JSON-RPC IDs or child-process internals;
- producer tasks publish owned results then wake;
- `start*` methods enqueue a bounded typed value or reject and return
  immediately; large JSON encoding and payload copies happen in the fixed
  producer task set;
- polling performs no pipe I/O, task join, process wait, JSON parse/encode,
  extension execution, or unbounded allocation;
- no callback from a reader task enters product state;
- `deinit` poisons the owner after all tasks and child processes settle.

`RuntimeServices` constructs and destroys the host. A frontend registers its
existing owner wake with the host, just as it does with agent-run streams. Print
mode and TUI use the same host; mode-specific extension behavior is decided by
later public API policy.

## 12. Lifecycle

### 12.1 Startup

For a non-empty load plan:

1. validate and own the bounded plan;
2. resolve Node without a shell;
3. materialize and verify the embedded host;
4. acquire the digest lease;
5. spawn one child generation;
6. start pipe and wait tasks;
7. perform the bounded `host/initialize` trust/version handshake without loading modules;
8. use `host/loadExtensions` to initialize the supplied modules;
9. commit the generation as active only after module initialization succeeds.

Until step 9, no registration or action from the candidate is visible to Zi.
The exact registration transaction belongs to the later extension API, but the
commit boundary is infrastructure.

Initial activation is a bounded bootstrap operation completed while
`RuntimeServices` is being assembled and before `session_bootstrap.openSession`
returns an `AgentSession`. This preserves the ability for later extension
registrations to participate in complete session construction. Reload after a
frontend starts is operation-backed and polled by that frontend owner.

A host-wide startup failure yields a typed extension-subsystem diagnostic and no
active generation. Whether an explicitly requested extension makes CLI startup
fatal is frontend/CLI policy and is not decided here.

### 12.2 Normal operation

The active generation remains alive across prompts and session replacement.
Session-specific facts are borrowed snapshots or explicit calls supplied later;
they are not cached as a second session model in Node.

The host may issue requests while handling a Zig request, so transport must be
fully duplex. A lockstep "write request, synchronously read one reply" design is
forbidden.

### 12.3 Crash

EOF, malformed output, wait completion, stderr overflow, or an infrastructure
deadline transitions the generation once to terminal failure. The owner then:

- stops accepting requests;
- settles every pending handle with the same typed generation failure;
- drains/joins process tasks;
- records a bounded diagnostic including exit status and stderr tail;
- wakes the frontend owner.

There is no automatic restart in the initial infrastructure. Automatic restart
can replay extension side effects and needs separate product policy. Explicit
reload/replacement is supported.

### 12.4 Atomic replacement and reload

Replacement builds a complete candidate generation while the active generation
continues serving. At most two generations exist.

```text
active A
  -> start candidate B
  -> handshake and initialize B
  -> if B fails: destroy B, keep A
  -> if B succeeds: publish B as active
  -> settle/cancel A operations as replaced
  -> request A shutdown, observe exit, deinit A
```

Generation tags prevent late A responses from reaching B callers. Callers must
not retain extension-owned registrations or contexts after replacement; the
later public API must model those values as generation-bound.

### 12.5 Shutdown

Shutdown is two phase and driven by the concrete frontend:

1. `requestShutdown` stops new operations and sends `host/shutdown`;
2. frontend polling observes response/exit or the owned deadline;
3. expiration closes stdin, requests termination, then force-kills after grace;
4. stdout/stderr/wait tasks are drained and joined;
5. only then may `ExtensionHost.deinit` and `Runtime.deinit` run.

The TUI loop includes the host's nearest deadline in its existing single wait
point. The runtime task that publishes transport progress sets the same
coalesced `WakeEvent` already used by the owner. After waking, `Loop` inspects
`ExtensionHost`; the wake carries neither payload nor mutation authority. This
does not add a second timer loop, wait point, producer pacing layer, or extension
thread that owns UI state.

## 13. TypeScript host responsibilities

The embedded host bundle owns:

- bounded frame reading and serialized frame writing;
- JSON-RPC envelope validation;
- Jiti configured with `fsCache: false` and `moduleCache: false`;
- request correlation for Node-originated calls;
- protocol handshake and version reporting;
- Jiti construction and TypeScript module import;
- one host generation's JavaScript callback tables;
- catching extension exceptions at each invocation boundary;
- converting exceptions into bounded diagnostics with stack traces;
- `AbortController` propagation for canceled invocations;
- orderly shutdown of host-owned resources registered by future APIs.

The host must honor Node stream backpressure. It cannot concatenate unbounded
`Buffer`s, queue unbounded promises, or fire-and-forget protocol writes.

The initial host may expose test-only probes proving that it can:

- import a `.ts` fixture through Jiti;
- import `node:fs/promises`;
- resolve a fixture package from `node_modules`;
- make a nested Node -> Zig request during a Zig -> Node request;
- receive cancellation and shut down.

Those probes are excluded from release protocol capabilities and do not become
public extension API.

## 14. Trust and security

Extensions are arbitrary trusted code, not a sandbox.

A loaded extension can:

- read and write files available to the user;
- inspect inherited environment variables;
- access the network;
- spawn subprocesses;
- consume CPU and native memory;
- terminate or corrupt its Node host process.

The subprocess boundary protects Zig memory and lets Zi survive a host crash. It
does not protect the user's account or files.

Project-local module paths must not enter an `ExtensionLoadPlan` before the
project-trust owner approves them. The host cannot make or persist trust
decisions. Global, explicit, package-managed, and project provenance remain
visible in the load plan so later diagnostics can identify the source.

Do not market queue bounds, V8 heap bounds, or process separation as a security
sandbox.

## 15. Persistence

The extension infrastructure persists no product state.

- The materialized host is verified derived cache.
- Loaded modules, registrations, pending operations, and diagnostics are
  generation-local ephemeral state.
- Future extension settings belong to settings owners.
- Future per-session durable extension facts must be appended through
  `AgentSession`/`SessionManager`; Node may request persistence but never writes
  Zi session JSONL directly as an implementation shortcut.

## 16. Explicit non-goals

This specification does not define:

- the extension factory signature;
- lifecycle event names;
- custom tools or their schemas;
- commands, shortcuts, flags, or completion;
- provider registration;
- UI notifications, confirmations, widgets, overlays, or custom renderers;
- session-entry formats;
- package discovery, npm/git installation, or lockfile policy for user packages;
- extension ordering and conflict resolution;
- per-extension isolation;
- capability permissions or sandboxing;
- compatibility with imports from Pi's TUI package;
- Bun/Deno support;
- Lua or WebAssembly extensions;
- an RPC frontend for controlling Zi itself.

Adding one of these requires an owner, bounds, persistence decision, frontend
behavior, and focused tests. It must use this host boundary rather than bypassing
it.

## 17. Tests and acceptance gates

### 17.1 TypeScript tests

The host package tests:

- split headers and split bodies across arbitrary chunks;
- multiple frames in one chunk;
- oversized/duplicate/invalid `Content-Length`;
- invalid UTF-8 and invalid JSON;
- write serialization and stream backpressure;
- unknown, duplicate, and wrong-direction IDs;
- Jiti loading of TypeScript;
- Node built-in import;
- package resolution from a fixture extension;
- thrown/rejected extension errors;
- cancellation and shutdown;
- stdout reservation and console-to-stderr routing.

### 17.2 Zig unit tests

Same-file tests cover:

- load-plan validation and ownership;
- frame/accounting bounds;
- pending-request capacity and generation tags;
- stale/duplicate response rejection;
- terminal settlement of all pending handles;
- stderr tail eviction and total cap;
- deadline transitions;
- shutdown state machine;
- replacement success and rollback;
- verified cache materialization, corruption repair, and publication race;
- cache eviction bounds.

Most Zig tests use a deterministic fake child/transport seam owned by
`ExtensionHost`; they do not inject callbacks into agent or frontend paths.

### 17.3 Process integration tests

A focused build step launches the real embedded host with real Node and proves:

1. handshake and version rejection;
2. TypeScript fixture load;
3. use of `node:fs/promises`;
4. bidirectional nested request/reply;
5. queue backpressure without unbounded allocation;
6. a fixture extension that spins forever does not prevent the TUI owner from
   processing synthetic input and rendering while its operation deadline kills
   the host;
7. a fixture host that never reads stdin, floods stdout, and keeps a pipe open
   cannot prevent deadline-driven termination and task settlement;
8. cancellation;
9. child crash settlement;
10. oversized/malformed frame failure;
11. graceful and forced shutdown;
12. successful and failed atomic replacement;
13. no adjacent host asset is required after the Zi binary is built.

No network access is permitted in tests. npm fixture packages are local.

### 17.4 Repository gates

Implementation adds host checks to CI and keeps the normal Zi gates:

```sh
npm --prefix extensions/host ci
npm --prefix extensions/host run check
npm --prefix extensions/host test
zig build test
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
git diff --check
```

PTY coverage is not required for handshake-only infrastructure, but the existing
suite remains a regression gate. User-visible extension UI added later requires
focused headless and PTY tests.

## 18. Implementation phases

### P0 — Host project and reproducible asset

- Create the locked Node project.
- Implement framing/transport unit tests in TypeScript.
- Bundle Jiti and the host into one deterministic ESM asset.
- Add the 8 MiB build gate.
- Wire the generated `LazyPath` into `@embedFile`.

Gate: a Zig test can inspect the embedded bytes and matching SHA-256; the bundle
has no runtime import from Zi's `node_modules`.

### P1 — Verified materialization

- Add path-owner constants and helpers.
- Implement content-addressed extraction, verification, atomic publication, and
  bounded cache eviction.
- Test corruption and concurrent publication.

Gate: tests never execute bytes that were not verified against the embedded
asset.

### P2 — Persistent duplex child

- Add the concrete runtime process mechanism.
- Implement request -> observe completion shutdown.
- Prove reader/writer/wait tasks are joined on success, failure, cancel, and kill.

Gate: leak/race tests pass and no worker can observe freed memory.

### P3 — ExtensionHost protocol owner

- Implement bounded queues, decoding tasks, handshake, request handles,
  generation failure, stderr policy, and wake registration.
- Add the real Node integration fixture.

Gate: handshake, duplex nested calls, backpressure, crash, deadline, shutdown,
and infinite-loop responsiveness integration tests pass. A headless `Loop` test
proves extension timeout progress does not block input dispatch or rendering.

### P4 — RuntimeServices integration

- Make `RuntimeServices` own an optional `ExtensionHost`.
- Keep the default load plan disabled/empty so ordinary Zi startup does not spawn
  Node.
- Expose typed host availability and diagnostics to concrete frontends without
  adding UI behavior.
- Integrate host deadlines and wakes into frontend drain/shutdown paths.

Gate: TUI and print start and shut down unchanged with no extensions; an explicit
test load plan starts and drains the real host through each frontend owner.

### P5 — Atomic generation replacement

- Add candidate generation startup, commit, rollback, stale-handle settlement,
  and old-generation drain.

Gate: failed replacement leaves the active generation usable; successful
replacement never delivers an old response to a new handle; at most two child
processes exist.

Only after P0-P5 pass should Zi specify its first public extension capability.

## 19. Evidence and rejected alternatives

This design was informed by:

- Pi's Jiti extension loader at `.references/pi`, which proves the desired
  TypeScript and Node behavior but not Zi's ownership architecture;
- `ooyeku/stem` commit `b5a8c289b0c2f3b08ca80a4b8157569b4f38fb32`,
  which demonstrates a Zig-owned out-of-process JSON-RPC plugin;
- `botopink/botopink-lang` commit
  `33c4b23d7b4f8b349ee2932cd313cf644df9a74d`, which demonstrates one persistent
  Node process with framed pipe IPC;
- `unjs/jiti`, a focused runtime TypeScript/ESM loader;
- TigerBeetle and Zigar as evidence that N-API is useful when Node owns the
  application, which is the wrong direction for Zi;
- `mitchellh/zig-quickjs-ng` as evidence that embedded JavaScript is practical
  but does not supply Node compatibility.

Rejected alternatives:

| Alternative | Reason rejected |
|---|---|
| N-API Zig addon | Makes Node the application/process owner |
| Embedded libnode/V8 | Large C++ ABI, distribution, and lifecycle burden |
| QuickJS | No Node standard library or npm compatibility |
| Lua | Zi would have to rebuild the developer integration ecosystem |
| One Node process per call | Startup cost and no long-lived extension state |
| One Node process per extension initially | Higher memory and coordination cost before isolation is proven necessary |
| Host beside the Zi executable | Fragile installation layout and version skew |
| Host source over stdin | Consumes the duplex protocol input |
| Host source through `--eval` | Argument limits and poor diagnostics |
| Native Node type stripping only | Intentionally incomplete TypeScript support |
| In-process generic event bus | Reintroduces a synchronization/translation corridor |

## 20. Completion definition

The infrastructure is complete when a release Zi binary, copied by itself to a
new location, can—when given an explicit test load plan and a compatible `node`
executable—materialize its verified embedded host, load a TypeScript fixture that
uses a Node built-in, exchange bounded bidirectional requests, survive host
failure, atomically replace the host, and shut down without leaked children or
worker races.

Completion does not require any public extension capability. It establishes the
small, direct, bounded boundary on which those capabilities can be designed.

# North-star PRD: Zi TypeScript extension API

- Status: product and architecture north star; not a single implementation tranche
- Date: 2026-07-13
- Product owner: `coding_agent.RuntimeServices`
- Public runtime: supervised TypeScript/Node extension host
- Current implemented capability: prompt commands, documented in `docs/typescript-extension-api.md`
- Compatibility target: equivalent user-visible products for representative extensions,
  not Pi API or source compatibility

## 1. Purpose

Zi has the hard infrastructure for trusted TypeScript extensions: bounded
discovery, project trust, one supervised Node host, framed IPC, cancellation,
deadlines, generation replacement, and concrete TUI and print integration. Its
public API is intentionally small: an extension can currently register a prompt
command that turns one slash invocation into one bounded user prompt.

The next extension should not determine the architecture accidentally. Adding an
action command, settings mutation, provider override, or request-payload hook only
because one feature needs it would grow a collection of unrelated escape hatches.
It would also recreate the ambient service-locator and event-bus relationships
that Zi's gen-3 architecture removed in-process.

This PRD defines the north star for the complete public extension system before
more capabilities are implemented. It answers:

- what kinds of products Zi extensions should eventually support;
- how extension code relates to Zi's existing state owners;
- which public capability families are distinct;
- how extensions observe facts and request mutations;
- how settings, session facts, and extension files differ;
- how TUI and print behavior remain explicit;
- where Zi deliberately remains less permissive than Pi;
- how future capability tranches are accepted without prematurely freezing every
  TypeScript signature.

The governing product promise is:

> Zi supports commands, tools, managed workflows, settings, session operations,
> lifecycle participation, AI integrations, and rich native interaction through
> explicit bounded capabilities. Extensions do not receive ambient access to Zi
> owners or terminal internals.

## 2. Relationship to existing documents

The following documents remain binding:

- `CONTEXT.md` defines Zi's owners and extension-host vocabulary.
- `AGENTS.md` defines gen-3 ownership, layering, boundedness, and frontend rules.
- `docs/typescript-extension-host-spec.md` defines the supervised process and
  private host-protocol infrastructure.
- `docs/typescript-extension-api.md` defines the currently implemented public
  prompt-command capability.
- `docs/runtime-zio-capabilities.md` remains binding whenever host/runtime
  mechanism changes.
- `docs/gen3-tui-plan.md` remains binding for TUI ownership and the prohibition
  on in-process protocol corridors.

This PRD does not supersede the current prompt-command contract. Prompt commands
are the first completed capability tranche and an example of the desired shape:
static registration, atomic publication, a generation-bound operation, bounded
input/output, cancellation, and native owner application.

The TypeScript examples below are conceptual. They name capability families and
semantic contracts; they do not freeze every method name or field. Each tranche
requires a focused implementation design and tests before its exact public types
become stable.

## 3. Product goals

### 3.1 Extension products

The mature system should make these products natural:

1. Prompt macros and slash commands.
2. Commands that perform bounded actions without starting an agent turn.
3. Agent-callable tools backed by Node packages, files, processes, or networks.
4. Persistent extension settings rendered by Zi's native settings experience.
5. Multi-step workflows using native selection, confirmation, input, form, and
   progress interactions.
6. Bounded reads of session facts followed by typed session requests.
7. Semantic lifecycle observation and narrowly defined guards.
8. Auxiliary model calls using Zi's model catalog, authentication, runtime, and
   cancellation.
9. Declarative policy for approved semantic model-request options.
10. New AI protocol adapters and model catalogs.
11. Native presentation contributions for extension-owned tools and workflows.
12. Extension-local global, project, and cache files using paths supplied by
    Zi's path owner.

### 3.2 Zi product properties

Adding those products must preserve:

- one owner for each mutable Zi fact;
- the direct frontend -> `AgentSession` -> `agent` -> `ai` path;
- one bounded TUI `Transcript` rather than an extension transcript mirror;
- persistence before live mutation for durable facts;
- input responsiveness while extensions run;
- cancellation as request -> observe completion;
- atomic host-generation publication and replacement;
- optional Node cost when no extensions are selected;
- explicit behavior in TUI, print text, and print JSON modes.

### 3.3 Author experience

An extension author should be able to understand an extension locally:

- activation declares the capabilities it contributes;
- each handler receives only the facts and operations relevant to that
  capability;
- capability docs state bounds, deadlines, frontend availability, persistence,
  and failure behavior;
- stable extension identity namespaces settings, facts, data, diagnostics, and
  conflicts;
- normal Node libraries remain available for extension-owned mechanism.

## 4. Explicit non-goals

This north star does not promise:

- Pi API compatibility or the ability to run an arbitrary Pi extension unchanged;
- access to `Loop`, `Transcript`, `AgentSession`, `SettingsManager`, provider
  instances, Vaxis windows, or runtime pointers;
- a generic `zi.on(name, callback)` event bus;
- arbitrary JSON-RPC calls exposed as a public extension API;
- raw terminal input, ANSI output, terminal cells, or custom frame rendering;
- a React-like or generic frontend framework around `src/tui`;
- direct session-jsonl editing;
- replacing a builtin provider by registering the same provider id;
- arbitrary mutation of provider wire payloads;
- synchronous Node callbacks on the TUI owner loop;
- an OS security sandbox for trusted Node extensions;
- unrestricted transcript or message-history access;
- dynamic registration after activation;
- extension-defined CLI flags in the initial or default surface;
- implementation of every capability in one project or release.

Zi may deliberately remain less permissive than Pi. The success criterion is
user-visible product capability, not arbitrary access to application internals.

## 5. Core model

### 5.1 Stable extension identity

Capabilities that persist or compose require an identity independent of a file
path:

```ts
export default defineExtension({
  id: "dev.igors.codex-features",
  version: "1.0.0",
  apiVersion: 1,
  activate(zi) {
    // Registration only.
  },
})
```

Requirements:

- ids use a documented bounded syntax and are unique in one load plan;
- duplicate ids reject the candidate generation;
- the canonical source path remains available for diagnostics and trust;
- version is extension metadata, not host-protocol negotiation;
- public API versioning is independent of the private host protocol;
- persistent keys are namespaced by extension id, never by load order;
- persistent capabilities require stable identity before they can ship.

The migration from today's activation-function-only shape requires its own API
version decision. This PRD does not authorize a permanent old/new compatibility
shim.

### 5.2 Registration

Activation is a bounded declaration transaction:

```ts
interface ZiExtensionRegistrar {
  readonly commands: CommandRegistrar
  readonly shortcuts: ShortcutRegistrar
  readonly tools: ToolRegistrar
  readonly settings: SettingRegistrar
  readonly instructions: InstructionRegistrar
  readonly lifecycle: LifecycleRegistrar
  readonly ai: AiRegistrar
  readonly presentation: PresentationRegistrar
}
```

The exact namespaces may evolve, but their separation is binding. A single
ambient application object must not absorb mutation methods over time.

Registration rules:

- registration is accepted only while activation is running;
- registrations are generation-local;
- all modules in a candidate must activate successfully;
- validation and conflict detection happen before publication;
- publication is atomic;
- dynamic registration is absent;
- declarations are immutable after publication except through an explicitly
  defined setting or operation result;
- replacement prepares a complete candidate before swapping generations.

### 5.3 Snapshots

A handler may receive a bounded immutable snapshot of facts relevant to its
operation. Examples include:

- current cwd;
- frontend kind and interaction availability;
- selected model identity and capabilities;
- session id and lifecycle status;
- a requested bounded tail of durable messages;
- extension setting values;
- an approved model catalog view;
- tool-call context.

A snapshot is not a live object and grants no mutation authority. Slices or data
returned through the host are valid only for the operation that requested them
unless the extension copies them into extension-owned memory.

### 5.4 Typed owner requests

When an extension needs Zi to change, it makes a capability-specific typed
request. The existing owner validates and applies that request:

```text
extension command requests prompt submission
  -> concrete frontend validates availability
  -> AgentSession starts or queues the prompt

extension requests a setting update
  -> SettingsManager validates and persists it
  -> relevant live owner receives the resolved fact

extension requests a durable session fact
  -> AgentSession persists it before publishing live state
```

There is no universal `dispatch(action)` or untyped action dictionary inside Zi.
The external JSON-RPC envelope ends at `ExtensionHost`; typed direct calls carry
the request to the concrete owner.

### 5.5 Extension operations

Every handler invocation is a generation-bound extension operation with:

- a typed input;
- a specific owner and caller;
- an explicit concurrency bound;
- a deadline;
- an `AbortSignal`;
- bounded output;
- one terminal result;
- deterministic behavior on host replacement, crash, and shutdown.

An operation never outlives the generation that supplied its code.

## 6. Ownership map

| Capability | Native owner | Extension authority |
|---|---|---|
| Discovery, trust, load plan | `coding_agent`/CLI | None |
| Host process and generation | `RuntimeServices`/`ExtensionHost` | Activation code and handlers only |
| Slash command catalog | `coding_agent` plus concrete frontend | Declare a command |
| Command execution UX | TUI `Loop` or print frontend | Return the command's typed result |
| Settings persistence | `SettingsManager` | Declare namespaced schema; request value changes |
| Native picker/form interaction | concrete frontend | Request one bounded interaction |
| Session lifecycle and durable facts | `AgentSession` | Read snapshots; make typed requests |
| Runtime agent context | `agent.Agent` | No direct access |
| Extension tools | `AgentSession` tool catalog and agent tool runner | Declare and execute extension-owned tool behavior |
| Model-request serialization | `ai` provider adapter | Contribute approved semantic options or implement a new adapter |
| Provider/auth/model resolution | `RuntimeServices`, `auth`, `ai` registry | Query bounded availability; declare a new adapter/catalog |
| Transcript rendering | TUI `Transcript` and `blocks.zig` | Declare supported presentation metadata only |
| Terminal rendering/input | TUI `Loop`, Vaxis | None |
| Extension files | extension through Node, under paths from `coding_agent.paths` | Full ownership of its own files |

A capability implementation is rejected if callers must mirror the native
owner's mutable state or if the extension host becomes an alternate owner.

## 7. Public capability families

The matrix distinguishes today's contract from the north star. `Planned` means
architecturally reserved, not scheduled; each row still needs a focused
capability PRD before implementation.

| Capability | Current status | North-star frontend scope | Primary native owner |
|---|---|---|---|
| Prompt commands | Stable initial capability | TUI, print text | concrete frontend |
| Action commands | Planned | TUI, print text | concrete frontend |
| Argument completions | Planned | TUI | `Loop`/command catalog |
| Shortcut bindings | Planned | TUI | `Loop` |
| Agent tools | Planned | TUI and print agent runs | `AgentSession`/`agent` |
| Extension settings | Planned | native TUI settings; explicit non-interactive policy | `SettingsManager` |
| Native interactions | Planned | TUI; declared print fallback | concrete frontend |
| Session snapshots/requests | Planned | capability-specific | `AgentSession` |
| Lifecycle observers/guards | Planned | frontend-independent facts | fact owner |
| Instruction contributions | Planned | all session frontends | `AgentSession` |
| Auxiliary AI calls | Planned | TUI and print workflows | `RuntimeServices`/`ai` |
| Existing-provider request policy | Planned | all agent runs | `AgentSession`/`ai` |
| New AI provider adapters | Reserved advanced capability | all agent runs | `ai`/`RuntimeServices` |
| Presentation contributions | Reserved advanced capability | TUI with generic fallback | `Transcript`/`blocks.zig` |
| Extension-scoped paths | Planned | all trusted extensions | `coding_agent.paths` |

### 7.1 Commands

Commands are explicit user-invoked frontend operations. The mature command
surface should support distinct, typed outcomes:

```ts
type CommandResult =
  | { kind: "prompt"; prompt: string; delivery: "submit" | "steer" | "follow-up" }
  | { kind: "notice"; level: "info" | "warning" | "error"; message: string }
  | { kind: "completed" }
```

A richer command may call capability-specific context methods during its
operation and then return one terminal result. There must not be a generic list
of arbitrary application actions that turns command results into a second
frontend protocol.

Required command features over time:

- prompt generation, already implemented;
- action commands that do not generate a prompt;
- direct and interactive availability declarations;
- bounded argument completion;
- cancellation and foreground progress;
- prompt delivery as submit, steering, or follow-up when the session state
  permits it;
- explicit TUI, print-text, and print-JSON behavior.

Prompt submission remains a Zi operation. The extension does not append a fake
user message or mutate runtime context directly.

### 7.2 Shortcuts and command bindings

A shortcut is a declarative binding to an existing extension command or native
interaction entry point:

```ts
zi.shortcuts.bind({
  key: "ctrl+.",
  command: "answer",
})
```

Rules:

- the TUI owns key decoding and the ESC cascade;
- extensions do not receive raw key streams;
- shortcut declarations are TUI-only and report that availability explicitly;
- builtin and extension conflicts reject the candidate generation;
- load order never silently wins;
- print frontends ignore the binding while retaining the command itself.

### 7.3 Agent tools

An extension tool is an agent-callable operation with schema, prompt metadata,
implementation, and bounded output:

```ts
zi.tools.register({
  name: "todos",
  description: "Manage project todo items",
  input: schema,
  async execute(ctx, input) {
    return {
      content: [{ type: "text", text: "Created TODO-a83f1c20" }],
      details: { action: "create", id: "a83f1c20" },
    }
  },
})
```

Zi owns:

- conversion to borrowed `agent.AgentTool` views;
- per-session tool catalog construction;
- input validation at the process boundary;
- concurrency, deadline, cancellation, and host-failure settlement;
- tool output caps and classification;
- durable tool-call/result behavior;
- generic transcript fallback.

The extension owns its Node implementation. It may use Node filesystem,
subprocess, package, and network facilities. A tool that mutates Zi-managed files
or state still uses a typed Zi capability rather than bypassing the native owner.

Tool registration does not imply custom rendering. Presentation is a separate
capability.

### 7.4 Settings

Extension settings are declarative, namespaced product settings:

```ts
const fastMode = zi.settings.boolean({
  key: "fast-mode",
  group: "Codex features",
  label: "Fast mode",
  description: "1.5x speed with increased usage",
  default: false,
  scopes: ["global"],
})

const verbosity = zi.settings.enumeration({
  key: "verbosity",
  group: "Codex features",
  label: "Verbosity",
  values: ["low", "medium", "high"],
  default: "low",
  scopes: ["global", "project"],
})
```

Zi owns:

- schema validation;
- global/project/default resolution;
- atomic persistence through `SettingsManager`;
- unknown-key preservation;
- native `/settings` picker composition;
- non-interactive read/write behavior when such a frontend is specified;
- propagation into future sessions and explicitly supported live owners.

Settings are stored under an extension-id namespace. Extension groups appear
under a native `Extensions` settings category by default so an extension cannot
masquerade as a builtin root setting.

A setting declaration may produce a typed reference usable by other static
registrations. This allows a native policy to depend on a resolved setting
without calling Node on every request.

Settings are not arbitrary extension files, and extension files do not become
settings merely because they contain JSON.

### 7.5 Native interaction

Zi should support rich extension workflows without exposing terminal rendering.
Handlers may request a bounded native interaction when the concrete frontend
supports it:

```ts
const target = await ctx.interaction.select({
  title: "Review target",
  items: [
    { value: "working-tree", label: "Uncommitted changes" },
    { value: "branch", label: "Compare with branch" },
  ],
})
```

North-star primitives:

- notice;
- confirmation;
- single or multi-select;
- bounded text input;
- bounded form/questionnaire;
- list/detail workflow;
- progress with cancellation;
- model or session selection where Zi already owns such catalogs.

These are concrete Zi product interactions, not an extension UI framework.
`Loop` retains composer focus, picker stacks, foreground-operation state,
rendering, and ESC ownership. Extensions receive semantic results, not key events
or cells.

Print behavior is declared per interaction:

- consume an explicit non-interactive value;
- use a documented default;
- return `InteractionUnavailable`;
- never read an implicit nested terminal prompt from non-interactive stdin.

Progress updates are bounded and coalesced by normal frame policy. They do not
introduce producer-side UI pacing.

### 7.6 Session snapshots and requests

A command, workflow, or lifecycle operation may request a bounded session view:

```ts
const tail = await ctx.session.readTail({
  messages: 32,
  bytes: 128 * 1024,
})
```

Possible snapshots include:

- session identity and persistence intent;
- selected model and thinking level;
- idle/running/retry/compaction status at a semantic level;
- bounded durable-message tail;
- bounded queued-prompt summary;
- namespaced facts belonging to the requesting extension.

Possible typed requests include:

- submit, steer, or follow up with a prompt;
- create, resume, or replace a session through existing bootstrap policy;
- append or update a namespaced durable extension fact;
- request a native session workflow supported by Zi's own session model.

Not exposed:

- mutable session-entry arrays;
- raw jsonl paths or editing;
- `AgentSession` or `agent.Agent` references;
- a second live transcript feed;
- Pi tree-navigation semantics unless Zi adopts an equivalent native product
  concept independently.

All durable requests preserve persistence-before-live-mutation ordering.

### 7.7 Lifecycle observers and guards

Lifecycle participation is semantic and typed:

```ts
zi.lifecycle.observeSessionOpened(...)
zi.lifecycle.observeSessionRestored(...)
zi.lifecycle.observeRunSettled(...)
zi.lifecycle.observeToolCompleted(...)
```

Observers:

- receive completed facts;
- cannot veto or rewrite the observed transition;
- run with deadlines and bounded concurrency;
- do not block the TUI owner loop;
- receive snapshots rather than owner references;
- do not receive token/delta firehoses by default.

Guards are a separate capability for operations where veto power is a real
product requirement, such as a future pre-tool-execution policy. Every guard
specification must define:

- exact input;
- allow/block result;
- ordering and composition;
- timeout behavior;
- whether failure is fail-open or fail-closed;
- user-visible diagnostics.

A generic event name plus arbitrary payload is forbidden. New lifecycle facts
are added only when repeated extension products justify a semantic contract.

### 7.8 Instruction contributions

Some tools and workflows require stable agent instructions. Extensions may
declare bounded instruction contributions rather than mutating the system prompt
at runtime:

```ts
zi.instructions.register({
  id: "todos-guidance",
  text: "Use the todos tool to track durable follow-up work...",
  when: { toolEnabled: "todos" },
})
```

`AgentSession` remains the system-prompt owner. It assembles approved extension
instructions with normal resources before the session begins. Conditions may
refer to declared tools, settings, provider/model capability, or frontend policy
only when the native resolver supports them.

Arbitrary per-turn system-prompt mutation is not the default surface.

### 7.9 Auxiliary AI calls

Extensions such as a question extractor need bounded model work independent of
the active agent turn:

```ts
const result = await ctx.ai.complete({
  model: { provider: "openai-codex", id: "gpt-5.4" },
  systemPrompt: "Extract questions as JSON.",
  prompt: sourceText,
  maxTokens: 2_000,
  output: schema,
})
```

Zi owns:

- bounded model catalog queries;
- authentication and credential lifetime;
- provider resolution;
- task runtime, timeout, cancellation, and retry policy;
- request/response byte and token caps;
- optional structured-output validation;
- operational failure classification.

Extensions may inspect model identity, capabilities, and availability but do not
receive builtin provider credentials merely to make a Zi-mediated call.

Auxiliary AI work is a foreground workflow step or a bounded background
operation. It is not hidden work on the TUI loop.

### 7.10 Existing-provider request policy

Modifying an existing provider is distinct from registering a provider. The
preferred surface is a static, typed policy over semantic request options:

```ts
zi.ai.requestOptions.contribute({
  target: {
    provider: "openai-codex",
    models: ["gpt-5.4", "gpt-5.5"],
  },
  set: {
    textVerbosity: verbosity.reference(),
    serviceTier: fastMode.when(true, "priority"),
  },
})
```

Requirements:

- fields are typed semantic options owned by `ai`, not raw provider JSON;
- model/provider matching is validated and bounded;
- setting references resolve natively;
- the resulting policy is immutable for one settings/session snapshot;
- Node is not called on every provider request;
- `AgentSession` copies resolved options into a run configuration;
- the provider adapter performs final capability checks and wire translation;
- overlapping writes to the same semantic field reject the candidate unless the
  field defines an explicit commutative composition rule;
- load order never decides which request mutation wins.

An advanced normalized-request transform may be considered later when several
real extensions cannot be expressed statically. It would still receive a typed,
bounded normalized request and return an approved typed patch under a deadline.
It would not receive or return arbitrary wire JSON. The implementation must
solve worker/host backpressure and cancellation explicitly before that capability
can ship.

### 7.11 New AI provider adapters

A genuinely new provider is a protocol adapter, not a replacement hook:

```ts
zi.ai.providers.register({
  id: "example-provider",
  models: [...],
  async *stream(ctx, request) {
    // Emit Zi-normalized assistant events.
  },
})
```

The eventual provider capability must specify:

- stable provider and API ids;
- model-catalog ownership and bounded publication;
- normalized request and stream-event types;
- streaming backpressure across the host boundary;
- cancellation and deadline behavior;
- retry and operational-failure classification;
- tool-call and usage semantics;
- authentication declarations and status;
- replacement and crash behavior during a live stream;
- print and TUI parity.

Rules:

- builtin ids cannot be replaced or shadowed;
- an adapter owns its external wire protocol;
- it emits normalized `ai` events rather than UI events;
- `agent` remains product-agnostic;
- provider-specific presentation does not enter `ai`;
- OAuth or secret-management integration requires a separate focused contract;
- trusted extensions may use Node environment/files directly, but Zi must not
  claim those paths are integrated authentication.

This is an advanced capability and must not be approximated with
`registerProvider(existingId, onPayload)`.

### 7.12 Presentation contributions

Presentation is separate from execution. The north star permits declarative
contributions that Zi can render natively, such as:

- tool summary and detail metadata;
- semantic status items;
- transcript annotations attached to extension-owned facts;
- command completion labels;
- settings descriptions;
- workflow list/detail schemas.

It does not permit:

- arbitrary terminal components;
- custom render callbacks;
- ANSI strings as styled UI;
- cell buffers or width engines;
- direct viewport or composer mutation;
- extension-owned transcript items outside `Transcript`'s bounded fold.

`src/tui/blocks.zig` remains the owner of tool-call UX. A presentation
contribution is converted into neutral bounded display data before rendering.
Unknown external tools always retain a safe generic fallback.

If a desired product cannot fit concrete native interaction or presentation
primitives, Zi may add a new product primitive after owner, bounds, frontend
behavior, and tests are specified. It must not add a generic extension component
framework as an escape hatch.

### 7.13 Paths, files, and diagnostics

Trusted extensions already have Node filesystem, process, package, and network
access. Zi should not wrap those APIs unnecessarily.

Zi should supply canonical, extension-scoped locations resolved by
`coding_agent.paths`:

- global data;
- project data, subject to project trust;
- cache/temp data with documented durability;
- current cwd.

The exact directory names remain owned by `paths.zig`. `ZI_CODING_AGENT_DIR`
must relocate Zi-owned global extension resources consistently.

Extension module variables are ephemeral generation state. They are lost on
replacement and process restart.

Structured diagnostics may supplement redirected `console` output, but they
remain byte-bounded and operational. Diagnostics are not a UI mutation channel.

## 8. Persistence model

Zi recognizes four distinct persistence classes:

| Class | Owner | Lifetime | Examples |
|---|---|---|---|
| Extension setting | `SettingsManager` | global/project settings | verbosity, feature toggle |
| Extension session fact | `AgentSession`/durable session log | one durable session | review workflow state |
| Extension data file | extension through Node | extension-defined | todo files, indexes |
| Generation state | extension host process | one host generation | memoized client, transient workflow cache |

Rules:

- settings are namespaced by extension id and validated against declarations;
- session facts are namespaced, bounded, and appended through `AgentSession`;
- extension data paths are supplied by Zi but file formats are extension-owned;
- caches are never durable truth;
- module globals never masquerade as durable state;
- no extension writes Zi's settings or session jsonl directly;
- project settings/data require the current run's project trust decision.

## 9. Frontend contract

Every capability specifies frontend availability rather than inferring it from
nullable state.

### 9.1 TUI

`Loop` owns:

- foreground extension operations;
- native interaction state;
- notices and progress;
- composer updates;
- ESC cancellation;
- frame composition;
- applying successful typed requests to `AgentSession` and other owners.

Extensions never run code on the owner loop. Producers wake; `Loop` polls the
host and applies bounded work.

### 9.2 Print text

Print mode supports capabilities that can resolve without interactive UI:

- direct commands;
- tools during an agent run;
- settings already resolved before startup;
- auxiliary AI and provider behavior;
- explicit non-interactive command inputs.

An unavailable interaction returns a process-ready error; print mode does not
silently invent answers.

### 9.3 Print JSON

JSON mode emits only documented frontend/session events. An extension capability
must not inject arbitrary JSON records into the stream. If extension operation
records become a product requirement, they need a versioned, typed print
contract owned by the print frontend.

### 9.4 Capability declaration

A registration may declare `interactive`, `non-interactive`, or both only where
the capability supports that distinction. Frontends reject impossible
invocations before starting an operation.

## 10. Composition and conflict rules

A mature extension ecosystem must not use load order as hidden policy.

### 10.1 Names

- extension ids are globally unique in a load plan;
- command names cannot collide with builtins or other extensions;
- tool names obey the agent tool namespace and reject duplicates;
- settings and session facts are namespaced by extension id;
- provider and API ids cannot shadow builtins;
- presentation contributions normally target resources owned by the declaring
  extension.

### 10.2 Multiple observers

Observers receive the same immutable fact. Their order is not a coordination
contract. One observer cannot mutate input seen by another. Bounded fan-out and
failure isolation are defined by the lifecycle capability specification.

### 10.3 Multiple guards

A guard type defines its composition explicitly. For an allow/block guard, all
registered guards normally must allow. No guard may depend on registration order.

### 10.4 Multiple request policies

Disjoint semantic fields may compose. Overlapping writes reject registration
unless the field owns a documented associative and commutative merge operation.
Raw object merge and last-writer-wins are forbidden.

### 10.5 Replacement

Operations remain pinned to their generation. Candidate replacement either:

- commits a complete validated catalog and settles old operations according to
  replacement policy; or
- fails and leaves the active catalog unchanged.

Persistent extension state is not implicitly migrated by host replacement.
Schema migration is extension-owned for files and capability-owned for declared
settings/session facts.

## 11. Execution and failure model

Each capability specification must define a failure matrix. The defaults are:

| Failure | Default behavior |
|---|---|
| Invalid or conflicting registration | Reject candidate; preserve active generation |
| Extension handler exception | Fail that operation with bounded diagnostic |
| Cooperative cancellation | Settle operation as canceled |
| Deadline expiry | Request cancellation; observe completion; escalate unresponsive generation |
| Malformed or oversized host output | Fail generation |
| Host crash | Settle all generation operations; preserve Zi owner validity |
| Replacement during operation | Settle as replaced according to capability contract |
| Native owner rejects request | Return typed rejection; do not partially mutate |
| Persistence failure | Do not apply corresponding live mutation |
| Unsupported frontend interaction | Return typed unavailable result |
| Provider stream host failure | Produce classified terminal provider failure and drain safely |

A JavaScript infinite loop may block the single Node event loop. Zi therefore
retains host-level deadline, terminate, and kill policy. It never assumes that an
`AbortSignal` alone stopped extension code.

## 12. Trust and authority

Extensions are trusted user code with normal Node authority. Once loaded, they
may read files, spawn processes, use the network, and import packages according
to the OS account running Zi.

Typed Zi capabilities are not a security sandbox. They serve different goals:

- preserve native ownership;
- prevent accidental dependence on internal representations;
- keep IPC and accumulated state bounded;
- make frontend and failure behavior explicit;
- allow Zi internals to evolve without breaking every extension;
- prevent one extension from mutating another extension's namespaced Zi state.

Project extension trust remains a load-time decision. Capability declarations do
not elevate an untrusted project extension into a trusted one.

## 13. Binding boundedness requirements

Current prompt-command bounds remain binding. Every future capability PRD must
name at least these dimensions where applicable:

| Accumulation/work point | Required policy |
|---|---|
| Registrations per capability per generation | Fixed cap; reject candidate |
| Names, descriptions, ids, schemas | Byte/depth/token caps; reject candidate |
| Concurrent operations | Fixed cap; return overloaded |
| Operation input/output | Byte/item caps; reject or fail operation |
| Session snapshot | Message and byte caps; reject oversized request |
| Native interaction choices/fields | Item and text caps; reject operation |
| Progress updates | Bounded slot/coalescing; frontend samples owned state |
| Tool output | Explicit truncate/reject/spill classification |
| Lifecycle fan-out | Fixed observer cap and bounded dispatch work |
| Auxiliary AI | Prompt/output/token/deadline caps |
| Request policy | Rule/model/field caps; reject candidate |
| Provider stream | Bounded pipe with backpressure and terminal deadline |
| Session facts | Entry and encoded-line caps; reject write |
| Diagnostics | Tail and total-byte caps; fail generation at hard ceiling |

No capability ships with “expected to remain small” as its bound.

## 14. Representative extension suite

The public API is evaluated against products, not method count.

### 14.1 Prompt macro

Example: current `/review concurrency` prompt command.

Required capabilities:

- command registration;
- bounded args;
- generated prompt;
- normal Zi prompt submission;
- TUI and print parity.

Status: implemented.

### 14.2 Persistent todo tool

Required capabilities:

- extension-owned files;
- agent tool registration;
- command registration;
- session identity snapshot for claims;
- native list/detail workflow;
- generic and optionally specialized tool presentation.

Acceptance: the agent can create/read/update todos and a user can manage them
without custom terminal rendering.

### 14.3 Question-and-answer workflow

Required capabilities:

- command and optional shortcut;
- bounded last-assistant-message snapshot;
- model catalog query;
- auxiliary AI call;
- native multi-question form;
- prompt submission.

Acceptance: equivalent user-visible question extraction and answering is
possible even though the Pi custom component is not reused.

### 14.4 Review workflow

Required capabilities:

- Node git/process/filesystem code;
- commands and native selection;
- bounded session snapshots;
- namespaced durable review facts;
- create/resume/replace requests supported by Zi's session model;
- prompt submit/follow-up;
- semantic lifecycle observation;
- progress and cancellation.

Acceptance: a durable review workflow can start, survive restore, and return to
normal work without direct session-manager access. Exact Pi session-tree behavior
is not required.

### 14.5 Codex features

Required capabilities:

- extension settings;
- native settings picker rows;
- static typed model-request policy;
- exact provider/model targeting;
- live-next-run propagation.

Acceptance: verbosity and Fast Mode can be configured without provider
replacement, payload mutation, custom state files, or Node calls per request.

### 14.6 New AI provider

Required capabilities:

- provider and model registration;
- normalized streaming;
- authentication declaration;
- usage and error classification;
- cancellation, backpressure, and host-crash settlement.

Acceptance: the provider works through normal `AgentSession` runs in TUI and
print without importing TUI policy into `ai` or `agent`.

### 14.7 Presentation contribution

Required capabilities:

- neutral bounded display metadata;
- extension-owned tool details;
- safe generic fallback.

Acceptance: useful custom tool UX is possible while `Transcript` and
`blocks.zig` remain the presentation owners.

If the first five products require ambient owner access, the surface is too
weakly designed. If they cannot be implemented with reasonable locality, the
surface is too weak in capability. If arbitrary Pi extensions can patch Zi
internals, the surface is too permissive.

## 15. Capability ladder

Capabilities should deepen in this order, though independent tranches may move
when a concrete product justifies them.

### Level 1 — Declarative contributions

- prompt and action commands;
- argument completions;
- shortcuts bound to commands;
- settings;
- instruction contributions;
- static request-option policy;
- basic tool presentation metadata.

### Level 2 — Managed workflows

- native interaction primitives;
- bounded session snapshots;
- prompt submit/steer/follow-up requests;
- namespaced session facts;
- auxiliary AI calls;
- progress and cancellation.

### Level 3 — Tools and semantic lifecycle

- extension tools;
- lifecycle observers;
- narrowly specified guards;
- session-create/resume/replace workflows.

### Level 4 — Protocol adapters

- new AI providers;
- model catalogs;
- authentication integrations;
- other complete external protocol adapters proven by repeated needs.

### Level 5 — Advanced native presentation

- richer fixed workflow primitives;
- tool summaries and details;
- semantic status and transcript annotations;
- no arbitrary renderer.

### Level 6 — Expert typed transforms

- normalized request transforms or similarly narrow expert hooks only after
  static declarations prove insufficient;
- explicit composition, deadlines, and failure policy;
- no generic event bus or raw wire-payload transform.

The ladder is not an excuse to prebuild speculative abstractions. A level becomes
real only through a focused capability PRD and representative extension.

## 16. Implementation strategy

### 16.1 One deep capability at a time

Each tranche should include:

1. public TypeScript declaration and host implementation;
2. bounded private wire additions ending at `ExtensionHost`;
3. one direct native owner integration;
4. TUI and print behavior;
5. host generation, replacement, cancellation, and shutdown tests;
6. one real representative extension or fixture;
7. documentation of bounds and failure semantics.

Do not add generic operation registries, event buses, owner mirrors, or UI
frameworks in anticipation of later levels.

### 16.2 Public API package

`@zi/extension-api` remains type-oriented for authors. Runtime objects are
supplied by the embedded host. The package should expose:

- stable public types;
- extension definition/identity helper when adopted;
- schema helpers only when Zi can validate them equivalently on both sides;
- no dependency on Zi's Zig implementation details;
- no private host-protocol types as public API.

### 16.3 Private protocol containment

The Node/Zig boundary justifies JSON-RPC. It remains contained:

```text
Node handler
  -> private framed request
  -> ExtensionHost typed decode
  -> concrete owner direct method
```

Protocol envelopes, method strings, and generic JSON values do not flow through
`Loop`, `AgentSession`, `agent`, or `ai` as a second internal architecture.

### 16.4 No Codex-shaped shortcut

Codex Fast Mode must not be used to justify:

- arbitrary `onPayload` hooks;
- replacing the builtin Codex provider;
- mutable options on a shared provider instance;
- provider-worker calls into the TUI owner;
- a one-off settings file outside `SettingsManager` if extension settings exist.

Either implement the feature natively, defer it, or first implement the coherent
settings plus typed request-policy tranches.

## 17. Test strategy

### 17.1 Host contract tests

For every capability:

- valid activation and publication;
- invalid schema and bounds;
- duplicate and builtin conflicts;
- handler success, exception, cancellation, and timeout;
- malformed/oversized output;
- host crash and uncooperative handler;
- replacement pinning and rollback;
- shutdown with active operations.

### 17.2 Native owner tests

- settings persist before live propagation;
- session facts persist before live publication;
- rejected requests leave owner state unchanged;
- tool operations settle exactly once;
- request policies produce immutable per-run options;
- provider failures classify and settle correctly;
- no deinit races worker-visible memory.

### 17.3 Headless frontend tests

- TUI foreground operation remains responsive;
- ESC requests cancellation and waits for settlement;
- native picker/form flows preserve composer ownership;
- no extension interaction creates a nested text-focus owner;
- print mode succeeds for non-interactive operations;
- print mode reports unavailable interactions deterministically;
- JSON mode contains no undocumented extension records.

### 17.4 Representative extension tests

Maintain fixtures for the seven products in Section 14. Tests should exercise
normal discovery, trust, `RuntimeServices`, provider resolution, `AgentSession`,
and the concrete frontend. Do not inject private callbacks that bypass those
paths.

### 17.5 Adversarial composition tests

- two extensions declare the same id;
- command, shortcut, tool, and provider collisions;
- overlapping request-option writes;
- one observer fails while others complete;
- host replacement during tool, workflow, and provider operations;
- project extension loses trust on the next run;
- settings remain namespaced across two extensions;
- one extension cannot mutate another's settings or session facts.

## 18. Versioning and compatibility

Three versions are distinct:

1. Zi application version.
2. Public `@zi/extension-api` version.
3. Private host protocol major/minor version.

Rules:

- a private protocol change does not imply a public API change;
- public semantic changes require normal API versioning;
- capabilities declare their minimum public API version;
- unsupported public API versions fail activation with a clear diagnostic;
- no silent best-effort interpretation of unknown declarations;
- experimental capabilities are named and gated explicitly rather than added as
  unstable fields to stable registrations;
- before the public identity shape stabilizes, update the implementation and
  fixtures directly rather than preserving permanent compatibility layers.

## 19. Documentation requirements

Every capability document must include:

- user-visible behavior;
- author-facing TypeScript types and examples;
- native owner and direct dataflow;
- all bounds and cap behavior;
- persistence class;
- TUI, print text, and print JSON behavior;
- cancellation and deadline semantics;
- host crash/replacement/shutdown behavior;
- composition and conflict rules;
- security/trust statement;
- focused and front-door tests.

The extension API overview should maintain a capability matrix showing:

- unavailable;
- experimental;
- stable;
- frontend availability;
- first representative extension.

## 20. North-star acceptance criteria

This PRD is satisfied as an architectural guide when future extension work can
answer all of the following before implementation:

1. Which capability family owns the author-facing declaration?
2. Which native owner is allowed to mutate the affected state?
3. What immutable snapshot or typed request crosses the host boundary?
4. What are the operation and accumulation bounds?
5. What happens on cancellation, timeout, crash, replacement, and shutdown?
6. Is the fact a setting, session fact, extension file, or generation state?
7. What do TUI, print text, and print JSON do?
8. How do two extensions compose or conflict?
9. Which representative extension proves the capability is deep enough?
10. Can the implementation avoid an ambient application object, generic event
    bus, raw payload hook, owner mirror, or frontend framework?

The mature API succeeds when the representative suite can deliver equivalent
user-visible products while Zi's existing owners remain authoritative.

## 21. Rejected directions

| Direction | Reason rejected |
|---|---|
| Copy Pi's `ExtensionAPI` wholesale | Couples extensions to application internals and in-process ownership assumptions |
| Generic `zi.on(event, callback)` | Event names and payloads become an unbounded shadow architecture |
| Universal action/result envelope | Turns the process protocol into an in-process frontend protocol |
| Raw `onPayload` provider hook | Leaks wire formats, creates ordering conflicts, and calls Node in a critical request path |
| Replace builtin provider by id | Creates mutable global policy and unclear ownership |
| Direct `SessionManager` access | Bypasses persistence ordering and couples extensions to durable representation |
| Arbitrary custom TUI components | Reintroduces terminal mechanisms and a generic frontend framework |
| Extension-specific native hardcoding | Makes every extension a builtin split across Zig and TypeScript |
| Build every level before use | Speculative complexity without representative products |
| Declare extensions sandboxed | False security claim; trusted Node code retains OS authority |
| Last-loaded extension wins | Hidden, order-dependent composition contract |

## 22. Review rubric

Reject a proposed extension capability if any answer is yes:

1. Does it expose a native owner object or mutable mirror?
2. Does it add a generic event, action, middleware, or UI framework where a typed
   capability would suffice?
3. Can Node block the TUI owner loop?
4. Is any queue, snapshot, output, fan-out, or operation unbounded?
5. Can load order change product semantics silently?
6. Can a persistence failure leave live state changed?
7. Is print or JSON behavior inferred instead of specified?
8. Does it require raw terminal or provider-wire access?
9. Does it bypass `RuntimeServices`, `AgentSession`, `SettingsManager`,
   `Transcript`, or `ai` ownership?
10. Is it designed around one extension without a coherent capability and a
    representative second use?

Approve a capability when it is a deep, bounded module: a small explicit author
surface that gives multiple extensions meaningful leverage while concentrating
native policy in the owner that already knows how to apply it.

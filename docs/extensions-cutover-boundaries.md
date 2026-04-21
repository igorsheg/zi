# extension v2 cutover boundaries

## status

contract for `zi-fex.12`.

this doc scopes the repo-facing cutover boundary: which consumers move together, which seams stay public, which host views get re-derived internally, and which v1 seams get deleted. it follows the [v2 cutover adr](./adr/extensions-v2-cutover.md), [architecture](./architecture.md), [runtime](./runtime.md), [agent events and transport boundaries](./agent-events-and-transport-boundaries.md), [runtime roots](./runtime-roots.md), [extensions](./extensions.md), [lifecycle](./extensions-lifecycle.md), [events](./extensions-events.md), [retained objects](./extensions-retained-objects.md), [tools](./extensions-tools.md), [jobs/subagents](./extensions-jobs-subagents.md), [ui contract](./extensions-ui-contract.md), [state rebinding](./extensions-state-rebinding.md), [providers](./extensions-providers.md), and [commands/flags/actions](./extensions-commands-flags-actions.md).

two adjacent updates are part of this boundary:

- commands are the explicit ordered-aggregation exception. they are not silent-drop first claimant anymore (`docs/runtime-roots.md:132-146`).
- `session_start` and `session_shutdown` observer payloads carry the rebinding binding identity set, not a looser lifecycle stub (`docs/extensions-events.md:97-100`, `docs/extensions-state-rebinding.md:101-121`).

## decision

- the cutover boundary is repo-wide. loaders, bootstrap, bind/rebind, registries, tui bridges, built-ins, examples, cli/json observers, and external extensions move together. no consumer gets to stay on v1 behind hidden glue (`docs/adr/extensions-v2-cutover.md:25-56`).
- `AgentEvent` survives only where zi is intentionally exporting a semantic observer stream as product output. batch json is such a surface (`src/coding_agent/cli/run_batch.zig:115-123`, `src/agent3/json.zig:1-108`). the internal agent↔tui conversation/render path is not: it stays request/snapshot/patch-shaped (`docs/extensions-events.md:18-20`, `src/coding_agent/request.zig:7-35`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/conversation_projection.zig:179-215`, `src/tui/conversation_projection.zig:412-430`).
- compatibility theater is forbidden. no compat layers, no shims, no glue code, no hidden fallback to legacy registries, and no hidden fallback to legacy transport (`docs/adr/extensions-v2-cutover.md:35-43`).

```text
public extension contract
  ├─ semantic events / interceptors
  ├─ semantic capabilities / retained objects
  └─ runtime-root provenance
            │
            v
host re-derives
  ├─ merged registries + visible views
  ├─ system prompt + tool metadata assembly
  ├─ conversation / ui / transcript snapshots + patches
  └─ request queue + run control
```

## boundary taxonomy

| boundary type | what crosses the cut | cutover rule | anchor |
| --- | --- | --- | --- |
| public event-shaped contract | semantic observer/interceptor payloads, including `session_start`, `session_shutdown`, `tool_call`, `tool_result`, `context`, `before_provider_request`, `input`, `session_compact`, and `session_tree` | keep only real product events. payloads stay semantic. they are not aliases of raw `AgentEvent`, `AgentRequest`, `UiEvent`, snapshots, or mailbox blobs. `AgentEvent` may remain the host envelope for external observer outputs such as batch json, but not for live tui transport | `docs/extensions-events.md:10-20`, `docs/extensions-events.md:97-143`, `docs/extensions-state-rebinding.md:101-121`, `src/coding_agent/cli/run_batch.zig:115-123`, `src/agent3/json.zig:1-108` |
| public retained-object / semantic capability | runtime roots, tools, commands, shortcuts, flags, providers, ui primitives, progress, transcript attachments, subagents, state-owner ids | keep the product seams. namespace owns registrations; host owns merged views and retained lifetimes. commands keep ordered aggregation as the explicit exception | `docs/runtime-roots.md:75-146`, `docs/extensions-lifecycle.md:41-73`, `docs/extensions-retained-objects.md:12-19`, `docs/extensions-ui-contract.md:10-21`, `docs/extensions-tools.md:12-25`, `docs/extensions-jobs-subagents.md:10-23`, `docs/extensions-providers.md:12-17`, `docs/extensions-commands-flags-actions.md:19-24` |
| internal derived view / assembly | merged tool/provider/model/command views, system prompt, prompt-template/skill expansion order, tool metadata assembly | re-derive from the public contracts every generation. do not version these as separate public seams and do not preserve old assembly helpers behind adapters | `src/coding_agent/session_bootstrap.zig:142-179`, `src/coding_agent/session_bootstrap.zig:242-286`, `src/coding_agent/system_prompt.zig:49-55`, `docs/extensions-events.md:132-135`, `docs/extensions-tools.md:91-105`, `docs/extensions-providers.md:15-17` |
| internal snapshot/patch transport | conversation snapshots, conversation patches, queued-message snapshots, family-scoped semantic snapshots, presentation documents, tool partial-result patches | keep the transport host-private. it exists so the tui can render and reconcile safely; it is not another public event protocol | `docs/extensions-retained-objects.md:133-165`, `docs/extensions-ui-contract.md:230-307`, `docs/extensions-tools.md:217-223`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/conversation_projection.zig:179-215`, `src/tui/conversation_projection.zig:412-430` |
| internal request/run-control transport | `AgentRequest`, request queue, queued steering/follow-up, abort, new/resume/compact/shutdown controls | keep the mailbox/run-control path host-owned. extensions and external observers consume semantic actions/results above it, never the raw transport types | `docs/runtime.md:10-19`, `src/coding_agent/request.zig:7-35`, `src/coding_agent/request.zig:47-86`, `src/coding_agent/runtime_host.zig:153-188` |
| deleted outright | dual registration/loading surfaces, direct tui→lua hot-path execution, silent-drop duplicate command visibility, legacy catch-all helper shapes, hidden fallback to legacy registries/transport | delete or rewrite. do not wrap old seams in adapters. do not keep them alive behind a new name | `docs/adr/extensions-v2-cutover.md:35-43`, `docs/extensions-tools.md:448-488`, `docs/extensions-jobs-subagents.md:96-118`, `docs/extensions-ui-contract.md:381-405`, `src/tui/interactive.zig:1961-1975` |

## consumer and callsite matrix

| consumer / subsystem | today's seam | v2 seam | boundary type | required action | blocked by |
| --- | --- | --- | --- | --- | --- |
| resource loader + discovery/preference wiring | `ResourceLoader` still reloads extensions, skills, and themes through separate namespace-specific passes, and `extendResources` only merges non-extension resource paths (`src/coding_agent/resources/loader.zig:133-199`) | one canonical runtime-root list plus `resources_discover`; loader becomes a root walker, not a per-namespace precedence owner (`docs/runtime-roots.md:54-119`, `docs/extensions-events.md:130-133`) | public retained-object / semantic capability | move loader inputs to root descriptors and delete bespoke namespace precedence logic | canonical root normalization is contractual in docs but not wired as the loader's only source of truth yet |
| settings/package/explicit-path provisioning seams | ingress still reaches bootstrap/loader as cwd + settings manager + direct resource inputs (`src/coding_agent/session_bootstrap.zig:98-104`, `src/coding_agent/resources/loader.zig:43-80`) | settings, packages, and explicit paths normalize into runtime roots before discovery; packages are materialized roots, not a second architecture (`docs/runtime-roots.md:54-87`, `docs/runtime-roots.md:161-171`) | public retained-object / semantic capability | make every provisioning path feed roots only | root normalization + package materialization plumbing |
| session bootstrap / `AgentSession` bind + rebind paths | bootstrap builds runner/tools/system prompt up front; bind still wires `.ui = null` and `.command_actions = null`; session replacement tears down and recreates sessions directly (`src/coding_agent/session_bootstrap.zig:142-179`, `src/coding_agent/agent_session.zig:624-639`, `src/coding_agent/runtime_host.zig:229-247`, `src/coding_agent/runtime_host.zig:249-282`, `src/coding_agent/runtime_host.zig:468-479`) | bind → `session_start` → steady state → `session_shutdown` → unbind/teardown, with stable binding ids across reload/new/resume/fork (`docs/extensions-lifecycle.md:10-18`, `docs/extensions-lifecycle.md:119-158`, `docs/extensions-state-rebinding.md:101-121`, `docs/extensions-state-rebinding.md:172-317`) | public event-shaped contract | route every replacement path through the same rebinding contract and finish bind-time runtime wiring | runner bind surface is still incomplete today |
| extension runner registries and namespace-owned retained objects | runner owns generation-local tool/event/command/provider slots (`src/coding_agent/extensions/runner.zig:129-160`) | namespaces own registrations; host exposes merged views and host-owned retained leases (`docs/extensions-lifecycle.md:41-73`, `docs/extensions-retained-objects.md:66-81`) | public retained-object / semantic capability | move all consumers to namespace claims + merged views; forbid fallback to old registries after cutover | command/provider/ui/state families are not fully wired yet |
| agent hook wiring for `tool_call` / `tool_result` / `context` / provider / `input` / session hooks | today `AgentSession` wires before/after tool hooks and a provider stream hook, while `transformContext` is still a documented no-op seam (`src/coding_agent/agent_session.zig:29-40`, `src/coding_agent/agent_session.zig:158-190`) | named observer/interceptor classes with semantic payloads, including rebinding-aware `session_start` and `session_shutdown` (`docs/extensions-events.md:10-20`, `docs/extensions-events.md:97-143`, `docs/extensions-state-rebinding.md:351-388`) | public event-shaped contract | replace ad hoc hook seats with the v2 event/interceptor family set | payload builders and dispatch coverage are still partial in the current codebase |
| system-prompt/tool-metadata assembly | bootstrap derives tool names, tool snippets, guidelines, skills section, and prompt inputs into one assembled prompt (`src/coding_agent/session_bootstrap.zig:242-286`, `src/coding_agent/system_prompt.zig:49-149`) | host re-derives prompt assembly from v2 tool definitions, prompt metadata, skills/prompt surfaces, and `before_agent_start`; the assembly is not itself a separate public api (`docs/extensions-events.md:132-135`, `docs/extensions-tools.md:91-105`) | internal derived view / assembly | keep the assembled prompt internal and rebuild it from v2 contracts every generation | tool-definition and prompt-metadata cutover |
| slash-command registry / autocomplete / dispatch surfaces | builtins and dynamic commands share one tui-owned registry, builtin precedence is hard-coded, and extension handlers still run inline on the tui path (`src/coding_agent/slash_commands.zig:68-119`, `src/coding_agent/slash_commands.zig:163-177`, `src/tui/interactive.zig:1874-1975`) | built-in interactive commands stay local; extension commands become agent-owned command registrations with ordered aggregation and host-resolved invocation names (`docs/runtime-roots.md:132-146`, `docs/extensions-commands-flags-actions.md:19-24`, `docs/extensions-commands-flags-actions.md:60-74`, `docs/extensions-commands-flags-actions.md:146-159`) | public retained-object / semantic capability | split built-in interceptors from extension commands; delete inline tui execution and silent-drop command assumptions | command registry/bind/runtime work is still reserved-seam only |
| interactive tool-renderer resolution and transcript presentation plumbing | transcript projection already rebuilds from owned snapshots and `ToolRendererResolver`, but current extension rendering still centers old `render_result` assumptions (`src/tui/conversation_projection.zig:152-294`, `docs/extensions-ui-contract.md:381-390`, `docs/extensions-tools.md:475-488`) | host-owned `call` / `result` presentation slots, transcript attachments, and presentation documents derived from semantic objects plus renderer refs (`docs/extensions-ui-contract.md:230-307`, `docs/extensions-tools.md:22-24`, `docs/extensions-tools.md:452-456`) | internal snapshot/patch transport | re-derive presentation from semantic retained objects; delete render-result-only special casing | public renderer-hook and tool-presentation cutover |
| host-owned ui request/snapshot/patch paths between agent and tui | runtime host publishes full conversation replace-all patches, incremental conversation patches, and queued snapshots; tui projection applies patches, stores owned snapshots, and reconciles transcript state (`src/coding_agent/runtime_host.zig:302-408`, `src/tui/interactive.zig:2776-2866`, `src/tui/conversation_projection.zig:152-215`, `src/tui/conversation_projection.zig:412-430`) | keep request/snapshot/patch transport internal; public ui stays the host-owned retained primitive family (`docs/runtime.md:10-19`, `docs/extensions-retained-objects.md:133-165`, `docs/extensions-ui-contract.md:10-21`) | internal snapshot/patch transport | keep the transport private and avoid rebranding it as a public event bus | ui retained-primitive implementation work |
| provider registry / model catalog integration | provider registry is api-string keyed, while model registry is a session-owned immutable snapshot (`src/ai/provider.zig:62-132`, `src/coding_agent/model_registry.zig:1-6`, `src/coding_agent/model_registry.zig:21-98`) | namespace-owned provider claims activate at bind, and host provider/model views are rebuilt from surviving claims on rebind (`docs/extensions-providers.md:12-17`, `docs/extensions-providers.md:86-100`, `docs/extensions-providers.md:114-123`, `docs/extensions-state-rebinding.md:375-409`) | public retained-object / semantic capability | add public provider registration/unregistration and rebuild visible model state from claims instead of pointer survival | provider bind flush + model-view rebuild are not wired yet |
| runtime host / request queue / run-control publication | `AgentRequest` owns tui→agent mutation, and `RuntimeHost` owns queued steering/follow-up, abort, and session replacement (`src/coding_agent/request.zig:7-35`, `src/coding_agent/request.zig:47-86`, `src/coding_agent/runtime_host.zig:153-188`, `src/coding_agent/runtime_host.zig:198-250`) | stays host-only transport below the public contract (`docs/runtime.md:10-19`, `docs/extensions-events.md:18-20`, `docs/extensions-events.md:61-64`) | internal request/run-control transport | keep it private; delete any cutover plan that exposes mailbox payloads as extension api | consumer discipline, not a missing contract |
| cli/json/rpc observer surfaces | batch json already emits semantic `AgentEvent` jsonl (`src/coding_agent/cli/run_batch.zig:115-123`, `src/agent3/json.zig:1-108`) | only explicit observer products keep event-shaped output; any rpc surface should reuse the same semantic observer contract, not snapshots or request mailboxes (`docs/extensions-events.md:18-20`, `docs/extensions-events.md:52-64`) | public event-shaped contract | freeze external observer payloads at semantic level only | explicit rpc contract if that surface is added later |
| built-in extension/tool examples and v1-era callsites still assuming the old surface | current examples/tests still speak `zi.register_tool(...)` and `zi.on(...)`, and the current tool docs explicitly map `render_result`, `ctx.update`, and `zi.spawn` away from the old v1 center (`src/coding_agent/extensions/loader.zig:434-476`, `src/coding_agent/extensions/loader.zig:516-534`, `docs/extensions-tools.md:448-488`) | rewrite to the v2 public contract or delete | deleted outright | migrate or delete every v1-shaped example and helper callsite; do not keep them alive behind adapters | final v2 lua surface spellings |
| external user/project extensions in the field | the adr already says there is no promise that a v1 extension keeps running after the cut (`docs/adr/extensions-v2-cutover.md:45-56`) | one truthful v2 api only | deleted outright | ship migration docs/examples after the internal cut, but do not ship a runtime shim | final public v2 surface + migration materials |

## survives as public contract

- semantic observer/interceptor classes and their payload meaning/order, including rebinding-aware `session_start` and `session_shutdown` (`docs/extensions-events.md:10-20`, `docs/extensions-events.md:97-143`, `docs/extensions-state-rebinding.md:101-121`).
- runtime-root provenance, precedence, and the commands ordered-aggregation exception (`docs/runtime-roots.md:75-146`).
- namespace-owned registration classes and host-owned retained capability families: tools, commands, flags, providers, ui primitives, progress, transcript attachments, jobs, and subagents (`docs/extensions-lifecycle.md:41-73`, `docs/extensions-retained-objects.md:66-81`, `docs/extensions-tools.md:29-37`, `docs/extensions-jobs-subagents.md:80-95`, `docs/extensions-providers.md:86-100`, `docs/extensions-commands-flags-actions.md:117-206`).
- external semantic observer output where zi intentionally publishes it as product surface, such as batch json (`src/coding_agent/cli/run_batch.zig:115-123`, `src/agent3/json.zig:1-108`).

## re-derived internally from v2 contracts

- merged visible registries and catalogs: tool lists, command invocation names, provider views, and model visibility (`docs/extensions-lifecycle.md:12-18`, `docs/extensions-providers.md:15-17`, `docs/extensions-commands-flags-actions.md:146-159`).
- system-prompt assembly, tool prompt metadata assembly, skill/prompt expansion order, and any other host prompt-building pass (`src/coding_agent/session_bootstrap.zig:242-286`, `src/coding_agent/system_prompt.zig:49-149`).
- conversation patches and snapshots, queued snapshots, family-scoped semantic snapshots, presentation documents, and transcript/tool projection state (`docs/extensions-retained-objects.md:133-165`, `docs/extensions-ui-contract.md:230-307`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/conversation_projection.zig:152-215`, `src/tui/conversation_projection.zig:412-430`).
- bind-time activation and rebind-time reconstruction of live handles, provider instances, and other session-live state (`docs/extensions-state-rebinding.md:351-409`).

## deleted outright

- compat layers, shims, glue code, and hidden fallback to legacy registries or legacy transport (`docs/adr/extensions-v2-cutover.md:35-43`).
- direct tui→lua hot-path execution for extension commands, rendering, or other live interaction paths (`docs/extensions-lifecycle.md:16-18`, `docs/extensions-ui-contract.md:14-17`, `src/tui/interactive.zig:1961-1975`).
- any plan that exports `AgentRequest`, snapshots, mailbox wake details, or other owner-boundary machinery as extension api (`docs/extensions-events.md:18-20`, `docs/extensions-events.md:61-64`, `src/coding_agent/request.zig:7-35`).
- silent-drop duplicate command visibility and other legacy slash-surface conflict rules (`docs/runtime-roots.md:132-146`, `docs/extensions-commands-flags-actions.md:146-159`).
- the v1 catch-all tool/subagent/render center: `render_result`, `ctx.update`, and `zi.spawn` as doctrine shapes (`docs/extensions-tools.md:448-488`, `docs/extensions-jobs-subagents.md:96-118`).

## gating order

1. cut ingress first: normalize settings/package/explicit-path inputs into canonical runtime roots, including the commands aggregation exception (`docs/runtime-roots.md:54-146`).
2. cut lifecycle next: make bind/rebind flows speak the rebinding ids and lifecycle ordering everywhere (`docs/extensions-lifecycle.md:119-158`, `docs/extensions-state-rebinding.md:101-121`, `docs/extensions-state-rebinding.md:172-317`).
3. cut namespace ownership next: move tool/command/provider/ui/job state to namespace-owned registrations plus host-owned retained objects (`docs/extensions-lifecycle.md:41-73`, `docs/extensions-retained-objects.md:66-81`).
4. cut public event and command/provider/tool surfaces next: wire semantic observer/interceptor payloads, ordered slash aggregation, provider claims, and tool presentation from the v2 docs (`docs/extensions-events.md:97-143`, `docs/extensions-commands-flags-actions.md:60-206`, `docs/extensions-providers.md:86-123`, `docs/extensions-tools.md:91-105`).
5. cut tui transport next: keep agent↔tui transport request/snapshot/patch-shaped and rebuild presentation from semantic state only (`docs/runtime.md:10-19`, `docs/extensions-ui-contract.md:230-307`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/conversation_projection.zig:152-294`).
6. only then migrate built-ins, examples, cli/json observers, and external extensions. after those are moved, delete every remaining v1 seam instead of bridging it (`docs/adr/extensions-v2-cutover.md:35-43`, `docs/adr/extensions-v2-cutover.md:45-56`).

## blocked downstream work

- the current public `zi` table still exposes only `register_tool`, `on`, and `spawn` (`src/coding_agent/extensions/api.zig:64-81`).
- bind-time runtime wiring still leaves ui and command actions empty (`src/coding_agent/agent_session.zig:624-639`).
- the tui still dispatches extension slash commands inline (`src/tui/interactive.zig:1969-1974`).
- provider activation/view rebuild is not complete yet: the runner has a provider queue, but `bindRuntime` still only flips stub→bound, and the model registry is still immutable per session (`src/coding_agent/extensions/runner.zig:155-159`, `src/coding_agent/extensions/runner.zig:422-425`, `src/coding_agent/model_registry.zig:1-6`).
- loader/bootstrap still assemble resources and prompt state through pre-root-normalization seams (`src/coding_agent/resources/loader.zig:141-159`, `src/coding_agent/session_bootstrap.zig:242-286`).

## done-state checks

- every row in the consumer matrix is either moved to the v2 seam or deleted. there is no mixed v1/v2 runtime surface left.
- `session_start` and `session_shutdown` payloads match the rebinding binding contract in every replacement flow (`docs/extensions-events.md:97-100`, `docs/extensions-state-rebinding.md:101-121`).
- internal agent↔tui conversation/render transport still uses request/snapshot/patch machinery, not a second public event protocol (`src/coding_agent/request.zig:7-35`, `src/coding_agent/runtime_host.zig:302-408`, `src/tui/conversation_projection.zig:179-215`, `src/tui/conversation_projection.zig:412-430`).
- external observer products still see semantic event payloads where zi intentionally exports them (`src/coding_agent/cli/run_batch.zig:115-123`, `src/agent3/json.zig:1-108`).
- slash-command collision behavior matches the ordered-aggregation contract, not hidden first-wins drop (`docs/runtime-roots.md:132-146`, `docs/extensions-commands-flags-actions.md:146-159`).
- no compat layer, shim, glue path, or hidden fallback to legacy registries/transport remains in tree or docs (`docs/adr/extensions-v2-cutover.md:35-43`).

## non-goals

- this is not a parity matrix.
- this is not the full per-field contract for tools, events, providers, ui, jobs, or state. the linked docs own those details.
- this is not a migration guide for external extension authors.
- this does not pin the final lua spelling for every v2 api surface.
- this does not bless internal mailbox, snapshot, or patch shapes as public api.

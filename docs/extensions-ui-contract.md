# extension ui: host-owned interaction and custom presentation

## status

contract for `zi-fex.8`.
it follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions-retained-objects.md](./extensions-retained-objects.md), [extensions-events.md](./extensions-events.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

## decision

- extension ui is a family of **host-owned retained primitives**.
- zi keeps common interaction capability, but not pi-mono's raw tui component reach-through.
- extensions publish semantic intent, slot claims, payload, and optional renderer references.
  they do not publish live components, overlay handles, focus objects, or editor implementations across the lua boundary.
- render work is host-scheduled agent-thread work.
  tui paint, layout, input, and overlay hot paths never call lua directly.
- render hooks are side-effect free contractually.
  the host may rerun, coalesce, defer, or drop stale render work.
- cleanup is deterministic by `{ generation, namespace }` lease scope.
  `session_shutdown` is the last session-visible mutation edge.
  `unbind` revokes session-scoped ui leases.
  `teardown` destroys generation-scoped renderer registrations and retained host caches that still exist for that namespace.

## model

```text
extension code
   │
   │  semantic intent
   │  prompt requests
   │  surface payloads
   │  renderer refs
   ▼
┌──────────────────────────────────────────────────────────────┐
│ agent-owned host ui store                                   │
│  generation g                                               │
│  namespace n                                                │
│                                                              │
│  notifications           prompt requests                     │
│  status / working        slot leases                         │
│  title / header/footer   editor actions                      │
│  transcript attachments  renderer registrations              │
│  presentation caches     overlay / panel descriptors         │
└───────────────┬──────────────────────────────────────────────┘
                │
                │ family-scoped semantic publication
                │ revisioned, host-timed, owner-safe
                ▼
┌──────────────────────────────────────────────────────────────┐
│ tui thread                                                   │
│  slot materialization                                        │
│  overlay stack + focus                                       │
│  transcript rows + renderer caches                           │
│  editor component + local interaction state                  │
│  layout, paint cadence, animation                            │
└──────────────────────────────────────────────────────────────┘
```

reading rule:

- if the extension wants to mutate ui, it mutates a host-owned primitive.
- if the tui wants to render, it reads a published semantic view.
- if a capability needs a real component, the tui builds it from host-owned state.

## parity classes

terms:

- **direct equivalent** — zi keeps the user-visible capability with substantially the same semantic outcome.
- **host-owned reinterpretation** — zi keeps the product capability, but the object crossing the boundary is a host-owned primitive rather than a raw tui object or callback graph.
- **excluded** — zi does not expose that pi-mono seam across the lua boundary.

| class | parity | host primitive | contract note |
| --- | --- | --- | --- |
| notify / toast | host-owned reinterpretation | `notification` record | extensions publish level, text, and optional lifetime hints. host may materialize as toast, banner, rpc event, or ignore by mode policy. |
| confirm | direct equivalent | `prompt<bool>` | modal vs inline vs rpc request is host policy. the semantic result is boolean confirmation. |
| text input | direct equivalent | `prompt<string?>` | single-line user input request. host owns focus, validation chrome, timeout display, and dismissal. |
| select / picker | direct equivalent | `prompt<option_id?>` | extensions publish stable option ids plus labels/metadata. host owns list ui, search, focus, and keybindings. |
| status items | direct equivalent | keyed `status_item` records | same product meaning as `setStatus(key, text)`, but authoritative state is host-owned and revisioned. |
| working message | direct equivalent | singleton `working_surface` | same product meaning as a working/loading label. host chooses where it appears. |
| hidden-thinking label | direct equivalent | singleton `thinking_label_surface` | same product meaning as the hidden-thinking label. host chooses exact placement and styling. |
| widgets | host-owned reinterpretation | `surface_lease` in a widget slot | no component factory crosses lua. extensions provide payload or renderer ref for host-owned materialization. |
| panels | host-owned reinterpretation | `surface_lease` in a panel slot | advanced panels stay possible, but only through named slots, semantic payload, and host-owned rendering. |
| header / footer | host-owned reinterpretation | singleton `surface_lease` | extensions may claim those surfaces semantically. they do not hand the host a live component factory. |
| title | direct equivalent | singleton `title_surface` | same product meaning as window/tab title intent. host resolves conflicts and applies per mode. |
| editor text / get / set / paste | direct equivalent | `editor_buffer_action` against host-owned editor state | extensions can read or mutate text through host actions. they do not replace the editor object. |
| editor modal | direct equivalent | `prompt<editor_text?>` | multi-line edit request with host-owned editor implementation. |
| transcript attachments | host-owned reinterpretation | `transcript_attachment` record | attachment meaning, metadata, and lifecycle are semantic. transcript row construction stays host-owned. |
| transcript custom presentation | host-owned reinterpretation | attachment / tool / message object with `renderer_ref` | custom transcript presentation is allowed through host-owned renderer hooks, not `TranscriptRenderable` reach-through. |
| advanced overlays / modal panels | host-owned reinterpretation | `overlay_surface_lease` | host owns overlay stack, focus restore, dismissal, and geometry. extension supplies semantics and optional renderer ref only. |
| raw custom component trees (`custom()`) | excluded | none | zi does not expose arbitrary tui component factories across the lua boundary. |
| custom editor component replacement | excluded | none | zi does not expose `setEditorComponent()`-style editor replacement to extensions. |
| raw terminal input listeners | excluded | none | terminal byte streams and focus routing stay host-private. |

## primitive families

### 1. notification family

notifications are ephemeral retained records.

they carry semantic fields such as:

- level
- message text
- optional ttl / dismissal hint
- provenance

they are not promises, overlay handles, or direct paint commands.

the host may:

- coalesce duplicates
- drop stale notifications on mode changes
- map them to toast, banner, log, rpc event, or no-op by mode policy

### 2. prompt family

confirms, text input, select, and editor-modal flows are one family: retained prompt requests.

each request has:

- a stable request id
- prompt kind
- prompt payload
- optional timeout / cancellation metadata
- terminal resolution state

resolution is host-owned.
extensions observe only the semantic result.

default unbind outcomes:

- confirm resolves `false`
- select resolves `null` / `undefined`
- text input resolves `null` / `undefined`
- editor-modal resolves `null` / `undefined`

that keeps teardown deterministic without replaying old prompts into a new binding.

### 3. status family

status-like surfaces are small retained records, not direct footer mutations.

members:

- keyed status items
- working message singleton
- hidden-thinking label singleton
- title singleton

these publish through family-scoped snapshots.
the tui is free to merge, order, truncate, or restyle them.

### 4. surface-slot family

widgets, panels, header, footer, and advanced overlays are all slot leases.

a slot lease says:

- which surface family the extension is claiming
- which host-defined slot within that family
- what semantic payload to render there
- whether a renderer ref is attached
- ordering / visibility hints

it does **not** say:

- which concrete component class to instantiate
- what focus object to borrow
- which overlay stack entry id to use
- how often the tui must repaint

### 5. editor family

editor capabilities split in two:

- **editor actions** — get text, set text, paste text, clear text, maybe open editor-modal
- **editor presentation** — border, autocomplete, cursoring, ime, focus, history, collapse behavior

extensions may use the first class.
the host owns the second class.

### publication boundary

extension ui publication is not command-owned.

any extension execution boundary that can mutate host-owned ui must publish or schedule publication of the affected semantic families before the host considers that boundary quiescent. examples include:

- startup / `session_start`
- session replacement lifecycle (`new`, `resume`, `fork`, `reload`)
- extension commands
- observer events such as `model_select`
- future tool/event/job/subagent callbacks that expose `ctx.ui`

this publication is a boundary object, not store access:

- the agent-side extension runtime owns retained ui records, namespace/generation cleanup, dirty-family tracking, and any pending action queues.
- the tui consumes semantic publications (`surface`, `prompt`, `editor_action`, notification, panel, etc.) and materializes local components from them.
- the tui must not read an `ExtensionUiStore`, `ExtensionRunner`, lua registry, or mailbox internals to discover ui state.
- lua extensions call capability functions (`ctx.ui.set_widget`, `ctx.ui.show_panel`, `ctx.ui.confirm`, etc.); they never observe the store or transport shape.

closed primitive families are intentional. extensibility happens through host-defined slots, semantic payloads, renderer refs, presentation documents, and deliberately added versioned families — not through raw tui component reach-through.

### 6. transcript family

transcript-facing ui uses semantic attachment and presentation records.

an extension may:

- attach semantic objects to transcript entries or tool results
- mark an object with a renderer ref
- update or detach that object while its lease is valid

an extension may not:

- inject a live transcript row object
- pass a `TranscriptRenderable`
- retain a cleanup callback that the tui must call later

## render-work contract

renderer hooks are the only advanced custom-presentation seam.

they are still host-owned.

### registration

renderer hooks are registered during load/register as namespace-scoped names.
a ui object may later reference one by id.

a renderer registration is generation-scoped.
it dies at teardown, even if no session was bound.

### inputs

a renderer hook receives only host-approved inputs, such as:

- object family
- semantic payload for that object
- presentation context (`width`, `expanded`, host mode, theme roles, density class, maybe slot kind)
- object revision metadata

it does not receive:

- a live tui object
- focus handles
- overlay handles
- editor instances
- mailbox send functions
- raw terminal input streams

### outputs

a renderer hook returns a **presentation document**.

a presentation document is host data, not a component instance.
it may contain host-approved nodes such as text runs, stacks, lists, tables, badges, markdown/code blocks, and other future serializable presentation nodes the host defines.

the host may copy, cache, diff, or discard that document.

the tui materializes its own render objects from the document.

### scheduling

render work is host-scheduled.

the host may run a renderer when:

- an object is created
- semantic payload changes
- expansion state changes
- a slot or transcript context changes
- theme or width class invalidates the cached document

render work does **not** run from tui paint or input hot paths.

the tui consumes the newest retained presentation document that already exists.

### purity

renderer hooks are side-effect free by contract.

that means:

- no mutation of other retained objects
- no prompt creation
- no spawn / job scheduling
- no reliance on paint-time callback ordering
- no yielding or blocking

if a renderer tries to act like a controller instead of a pure function, host behavior is undefined except for one guarantee: the host may reject the output and fall back to default presentation.

### failure and fallback

renderer failure is fail-open.

if a renderer is missing, invalid, stale, or rejected:

- the host keeps the semantic object alive
- the host drops the stale presentation cache
- the host uses family-default presentation

## transcript integration

transcript integration stays semantic first.

```text
extension tool / event / attachment
   │
   ├─ create transcript object record
   ├─ optional renderer_ref
   └─ semantic revision bumps
            │
            ▼
      host transcript projection
            │
            ├─ build / refresh presentation document
            ├─ publish transcript semantic snapshot
            └─ invalidate tui-local retained rows as needed
                     │
                     ▼
                tui transcript rows
```

rules:

- transcript ids and semantic revisions are host-owned.
- renderer refs may influence presentation, but not transcript ownership.
- transcript rows remain rebuildable from semantic state plus host-owned render caches.
- transcript attachments clean up on unbind if session-local, or when the owning transcript object dies if later contracts add longer-lived transcript storage.

## cleanup and rebind

this section applies the retained-object and lifecycle docs directly to ui.

### `session_shutdown`

`session_shutdown` is the last session-visible edge where a namespace may:

- finalize visible status or working text
- publish terminal prompt outcomes if already resolved
- withdraw or mark transcript attachments terminal
- request surface teardown in an orderly way

it must not create new long-lived session-scoped ui leases.

### unbind

after unbind:

- every pending prompt owned by that namespace is resolved or cancelled by host policy
- notification records still pending display are dropped
- status / working / hidden-thinking / title records for that namespace are withdrawn
- widget / panel / header / footer / overlay leases are revoked
- editor actions from stale handles are rejected or ignored
- transcript attachments owned by the old binding are detached
- all renderer caches derived from revoked session-scoped objects are invalidated

no stale ui handle silently reattaches to a later binding.

### reload

reload is same-session generation swap.

```text
old generation g
   │
   ├─ session_shutdown(reason=reload)
   ├─ unbind ui leases for g
   ├─ discover + load generation g+1
   ├─ bind g+1 to same session
   ├─ session_start(reason=reload)
   └─ teardown g renderer registrations + remaining caches
```

rules:

- no prompt, status item, surface lease, attachment, or renderer ref from `g` is valid in `g+1`
- the new generation must create fresh ui objects explicitly
- the host may rebuild identical-looking presentation, but only from fresh `g+1` state

### session replacement

new-session, resume, and fork replace both the session binding and the generation.

```text
session a / generation g
   │
   ├─ session_shutdown(reason=new|resume|fork)
   ├─ unbind ui leases for g
   ├─ teardown g
   ├─ discover + load generation h for session b
   ├─ bind h to session b
   └─ session_start(reason=new|resume|fork)
```

rules:

- no ui state crosses the session replacement boundary implicitly
- transcript attachments from session `a` do not rebind into session `b`
- if the same extension id appears again, it still gets fresh namespace ownership and fresh ui leases

## what this replaces or tightens in current zi

- `src/coding_agent/extensions/context.zig` and `src/coding_agent/agent_session.zig` currently model a nullable `ctx.ui` seam.
  this contract replaces that placeholder with host-owned ui primitives.
- `src/tui/status_data.zig` currently stores extension statuses inside tui-owned state.
  this contract moves status authority to the agent-owned host store and treats tui state as published materialization.
- `src/coding_agent/extensions/api.zig` and `src/coding_agent/extensions/lua_renderer.zig` currently expose `render_result` as an optional lua hook for tool results.
  this contract keeps the useful part — host-scheduled pure render work returning owned data — and generalizes it into renderer hooks for ui families without exposing raw tui reach-through.
- `src/tui/tool_display.zig`, `src/tui/transcript.zig`, and `src/tui/conversation_projection.zig` already separate semantic input from retained presentation caches.
  this contract makes that split normative for extension ui surfaces and transcript attachments too.
- `src/tui/interactive.zig`, `src/tui/overlay.zig`, `src/tui/tui.zig`, and `src/tui/editor_iface.zig` already own slot layout, overlay focus, and editor plumbing on the tui side.
  this contract keeps those seams host-private rather than extension-visible.

## explicit exclusions

zi does not expose these across the lua boundary:

- arbitrary component factories for widgets, header, footer, overlays, or transcript rows
- raw overlay handles
- raw terminal input listeners
- custom editor object replacement
- direct paint-time callbacks from tui into lua

if zi later wants richer extension ui, it should add richer **host-owned primitives** or richer **presentation-document nodes**.
it should not punch a new component-shaped hole through the owner boundary.

## relation to the existing docs

this doc does not replace the retained-object or lifecycle docs.
it specializes them for ui.

- [extensions-retained-objects.md](./extensions-retained-objects.md) stays authoritative for lease domains, cleanup edges, and family-scoped publication.
- [extensions-lifecycle.md](./extensions-lifecycle.md) stays authoritative for bind, `session_start`, `session_shutdown`, unbind, teardown, reload, and session replacement ordering.
- [runtime.md](./runtime.md) stays authoritative for the owner split: agent owns extension execution; tui owns presentation.
- [extensions-events.md](./extensions-events.md) stays authoritative for the rule that public contracts are semantic payloads, not internal mailbox or snapshot transport.

## non-goals

this contract still does not pin down:

- exact lua api names and call signatures for each primitive
- final snapshot wire format
- final presentation-document node schema
- exact host arbitration rules when multiple namespaces compete for one slot
- exact transcript attachment schema per attachment kind

those belong in follow-on api and schema docs.

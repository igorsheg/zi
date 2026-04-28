# extension ui: host-owned semantic presentation

## status

contract for extension-visible ui.

it follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions-retained-objects.md](./extensions-retained-objects.md), [extensions-events.md](./extensions-events.md), [extensions-ui-primitives.md](./extensions-ui-primitives.md), [extensions-ui-substrate-map.md](./extensions-ui-substrate-map.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

## decision

extension ui is a closed family of **host-owned semantic primitives**.

public lua publishes intent:

```lua
ctx.ui.message(text, opts?)
ctx.ui.status(spec)
ctx.ui.progress(spec)
ctx.ui.report(spec)
ctx.ui.prompt(spec)
ctx.ui.pick(spec)
ctx.ui.set_editor_text(text)
ctx.ui.paste_to_editor(text)
ctx.ui.clear_editor_text()
ctx.ui.get_editor_text()
```

public lua does not publish TUI components, overlay handles, slot claims, focus objects, geometry, renderer spans for reports, or editor implementations.

## owner model

```text
extension code
   │
   │ semantic ui intent
   │ prompt/pick requests
   │ report/message/status/progress publications
   │ editor actions
   ▼
┌──────────────────────────────────────────────────────────────┐
│ agent-owned extension runtime                               │
│  generation g                                               │
│  namespace n                                                │
│                                                              │
│  reports                  prompts / picks                    │
│  messages                 editor actions                     │
│  status records           renderer registrations             │
│  progress records         transcript semantic attachments    │
└───────────────┬──────────────────────────────────────────────┘
                │
                │ owned semantic publication
                │ revisioned, host-timed, owner-safe
                ▼
┌──────────────────────────────────────────────────────────────┐
│ tui thread                                                   │
│  text/markdown/list/editor/overlay materialization           │
│  transcript rows + renderer caches                           │
│  layout, focus, paint cadence, animation                     │
└──────────────────────────────────────────────────────────────┘
```

rules:

- if extension code wants to mutate ui, it publishes a semantic primitive.
- if the tui wants to render, it reads an already-published semantic view.
- if a capability needs a real component, the tui builds it from host-owned state.
- tui paint, layout, input, and overlay hot paths never call lua directly.
- cleanup is deterministic by `{ generation, namespace }` lease scope.

## primitive families

| family | public primitive | host-owned record | materialization policy |
| --- | --- | --- | --- |
| short feedback | `message` | message publication | footer/status/toast/log/rpc event; host may coalesce or suppress |
| compact state | `status` | keyed status publication | status line/title/rpc state; host owns order and truncation |
| work lifecycle | `progress` | keyed progress publication | compact status/progress view; future nested progress registry |
| readable document | `report` | report publication | text/markdown view, bottom sheet, modal, transcript artifact, or non-tui artifact |
| modal request | `prompt` | prompt request | overlay/editor/list/remote prompt; semantic result envelope |
| chooser/search | `pick` | picker request with serializable item metadata | list picker/select/search; semantic result envelope with `value` and selected `item` |
| composer mutation | `editor_*` | editor action | host-owned composer buffer action |
| transcript semantics | notes/labels/attachments | transcript/session semantic records | host-rendered badges, folds, rows, or summaries |

## public consistency grammar

all public `ctx.ui` primitives follow one grammar:

1. names describe intent, not destinations.
   - `report`, not panel.
   - `message`, not footer/notification.
   - `pick`, not select-list.
2. retained or complex operations take spec tables.
3. stable `id` is family-scoped replacement/dedupe state.
4. `kind` is semantic classification, not a component class or color token.
5. `lifetime` is a host hint, not a cleanup handle.
6. modal operations return result envelopes.
7. non-modal publications do not return component handles.
8. payloads crossing lua are serializable host data.
9. layout and fallback are host policy.
10. the same primitive should make sense in TUI, batch, and future RPC hosts.

## publication boundary

extension ui publication is not command-owned.

any extension execution boundary that can mutate host-owned ui must publish or schedule publication of the affected semantic families before the host considers that boundary quiescent. examples include:

- startup / `session_start`
- session replacement lifecycle (`new`, `resume`, `fork`, `reload`)
- extension commands
- observer events such as `model_select`
- future tool/event/job/subagent callbacks that expose `ctx.ui`

this publication is a boundary object, not store access:

- the agent-side extension runtime owns retained ui records, namespace/generation cleanup, dirty-family tracking, and pending action queues.
- the tui consumes semantic publications and materializes local components from them.
- the tui must not read an `ExtensionUiStore`, `ExtensionRunner`, lua registry, or mailbox internals to discover ui state.
- lua extensions call semantic capability functions; they never observe the store or transport shape.

## render-work contract

renderer hooks are the advanced custom-presentation seam.

they remain host-owned and pure.

### registration

renderer hooks are registered during load/register as namespace-scoped names. a ui or transcript object may later reference one by id.

a renderer registration is generation-scoped. it dies at teardown, even if no session was bound.

### inputs

a renderer hook receives host-approved inputs, such as:

- object family
- semantic payload for that object
- presentation context (`width`, `expanded`, host mode, theme roles, density class)
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

a presentation document is host data, not a component instance. it may contain host-approved nodes such as text runs, stacks, lists, tables, badges, markdown/code blocks, and future serializable presentation nodes.

the host may copy, cache, diff, or discard that document. the tui materializes its own render objects from it.

### scheduling

render work is host-scheduled.

the host may run a renderer when:

- an object is created
- semantic payload changes
- expansion state changes
- context changes
- theme or width invalidates the cached document

render work does **not** run from tui paint or input hot paths. the tui consumes the newest retained presentation document that already exists.

### purity

renderer hooks are side-effect free by contract:

- no mutation of retained objects
- no prompt creation
- no process/job scheduling
- no reliance on paint-time callback ordering
- no yielding or blocking

if a renderer acts like a controller, the host may reject the output and fall back to default presentation.

### failure and fallback

renderer failure is fail-open:

- the semantic object stays alive
- stale presentation cache is dropped
- family-default presentation is used

## transcript integration

transcript-facing ui stays semantic first.

extensions may attach semantic objects to transcript entries or tool results, or create session notes/labels tied to durable entry ids. renderer refs may influence presentation, but transcript ownership stays host-owned.

extensions may not:

- inject live transcript rows
- pass `TranscriptRenderable` objects
- retain cleanup callbacks for the tui to call later

## cleanup and rebind

this section applies [extensions-retained-objects.md](./extensions-retained-objects.md) and [extensions-lifecycle.md](./extensions-lifecycle.md) directly to ui.

### `session_shutdown`

`session_shutdown` is the last session-visible edge where a namespace may:

- finalize visible status/progress/message state
- publish terminal prompt outcomes if already resolved
- withdraw or mark transcript attachments terminal

it must not create new long-lived session-scoped ui records.

### unbind

after unbind:

- pending prompts/picks owned by that namespace are resolved or cancelled by host policy
- message records still pending display are dropped
- status/progress records for that namespace are withdrawn
- reports owned by that namespace are revoked
- editor actions from stale handles are rejected or ignored
- transcript attachments owned by the old binding are detached
- renderer caches derived from revoked session-scoped objects are invalidated

no stale ui handle silently reattaches to a later binding.

### reload

reload is same-session generation swap.

```text
old generation g
   │
   ├─ session_shutdown(reason=reload)
   ├─ unbind ui records for g
   ├─ discover + load generation g+1
   ├─ bind g+1 to same session
   ├─ session_start(reason=reload)
   └─ teardown g renderer registrations + remaining caches
```

rules:

- no prompt, pick, report, status, progress, message, editor action, attachment, or renderer ref from `g` is valid in `g+1`.
- the new generation must publish fresh ui state explicitly.
- identical-looking presentation may be rebuilt only from fresh `g+1` state.

### session replacement

new-session, resume, and fork replace both the session binding and the generation.

```text
session a / generation g
   │
   ├─ session_shutdown(reason=new|resume|fork)
   ├─ unbind ui records for g
   ├─ teardown g
   ├─ discover + load generation h for session b
   ├─ bind h to session b
   └─ session_start(reason=new|resume|fork)
```

rules:

- no ui state crosses the session replacement boundary implicitly.
- transcript attachments from session `a` do not rebind into session `b`.
- if the same extension id appears again, it still gets fresh namespace ownership and fresh ui records.

## explicit exclusions

zi does not expose these across the lua boundary:

- arbitrary component factories
- raw overlay handles or geometry
- slot claims such as header/footer/widget placement
- custom editor object replacement
- raw terminal input listeners
- direct paint-time callbacks from tui into lua
- compatibility aliases for removed ui api names

if zi later wants richer extension ui, it should add richer **host-owned primitives** or richer **presentation-document nodes**. it should not punch a component-shaped hole through the owner boundary.

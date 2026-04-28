# extension ui substrate map

## status

research and design map for the semantic `ctx.ui` api.

this doc complements [extensions-ui-primitives.md](./extensions-ui-primitives.md), [extensions-ui-contract.md](./extensions-ui-contract.md), [extensions-retained-objects.md](./extensions-retained-objects.md), and [tui.md](./tui.md).

## purpose

zi should not expose every TUI component to lua.

this map exists to separate three things that are easy to conflate:

1. **public extension intent** — the small lua api extension authors call.
2. **host-owned ui records** — retained semantic publications crossing the agent/TUI boundary.
3. **TUI substrate** — concrete components, slots, layout, focus, paint, and terminal behavior.

public lua gets the first layer. the host owns the second. the TUI owns the third.

## design stance

excellent extension ui should feel like a small set of powerful primitives, not a component factory.

neovim is the useful model, but not as a literal api clone:

- `vim.notify` works because it says "short feedback", not "draw a footer row".
- `vim.ui.input` and `vim.ui.select` work because they leave materialization to the host.
- telescope.nvim works because it is a **picker abstraction**: source, entries, scoring, preview, actions, and layout strategy are named concepts. authors do not start from raw floating-window geometry.
- quickfix/location lists work because they are durable navigable result sets, not transient strings.
- floating windows are powerful, but plugin authors use them best behind semantic abstractions. raw geometry is an implementation escape hatch, not the product vocabulary.

zi should follow that lesson:

- make `ctx.ui.report`, `ctx.ui.pick`, and `ctx.ui.prompt` strong enough that raw overlay access is rarely desired.
- improve text, markdown, picker, overlay, and status internals so every semantic primitive benefits.
- add new semantic families only when a real extension job cannot be expressed by the existing ones.

## current public surface

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

removed names remain removed. there are no compatibility aliases.

## mental model

| user intent | lua primitive | modal | retained | returns value | typical TUI substrate |
| --- | --- | ---: | ---: | ---: | --- |
| short feedback | `message` | no | ephemeral/host policy | no | footer, status primary, terminal notification, event stream |
| compact state | `status` | no | yes, keyed by `id` | no | `StatusData`, `StatusLine`, terminal title policy |
| work lifecycle | `progress` | no | yes, keyed by `id` | no | `StatusLine`, shimmer/working state, future progress registry |
| readable output | `report` | host policy | yes, keyed by `id` | no | `Text`, `Markdown`, boxed/report surface, overlay destination |
| ask for input | `prompt` | yes | temporary request | yes | `Overlay`, `Editor`, `ListPicker`, `SelectList` |
| choose/browse | `pick` | yes | temporary request | yes | `Overlay`, `ListPicker`, `SelectList`, future preview pane |
| mutate composer | `editor_*` | no | editor-owned | maybe | `EditorInterface`, composer `Editor` |

## public primitive design

### `ctx.ui.message(text, opts?)`

short feedback. analogous to `vim.notify`, but host-policy-first.

recommended contract:

```lua
ctx.ui.message("Saved note", {
  kind = "success",      -- info | warning | error | success
  id = "optional-key",   -- optional dedupe/update key
  lifetime = "until_input",
})
```

current materialization can be footer/status-like and/or terminal-native notification. future hosts may log, coalesce, suppress, or route messages elsewhere.

important properties:

- no placement option.
- no raw toast/window handle.
- `kind` is semantic severity, not a color token.
- `id` is for dedupe/replacement, not a component id.

### `ctx.ui.status(spec)`

compact retained state by stable `id`.

```lua
ctx.ui.status({ id = "model", text = "🤖 sonnet" })
ctx.ui.status({ id = "model" }) -- clear
```

status is not a widget slot. host owns order, truncation, styling, separators, density, and placement.

future fields worth reserving:

```lua
{
  id = "lsp",
  label = "lsp",
  text = "ready",
  kind = "success",      -- info | warning | error | success
  priority = 50,
  lifetime = "session",
}
```

avoid public `placement = "left"` / `placement = "right"` unless a real product case forces it. placement is where api entropy starts.

### `ctx.ui.progress(spec)`

retained work lifecycle. separate from status because progress has terminal states.

v1 materializes compactly, but the host transport preserves progress semantics:

```lua
ctx.ui.progress({
  id = "summary",
  status = "running",     -- running | done | error | cancelled
  title = "Generating summary",
  detail = "last 20 messages",
  current = 3,
  total = 10,
})
```

for indeterminate work:

```lua
ctx.ui.progress({
  id = "index",
  status = "running",
  title = "Indexing files",
  indeterminate = true,
})
```

clearing should be semantic rather than slot-shaped:

```lua
ctx.ui.progress({ id = "index", status = "done" })
```

or, if later needed:

```lua
ctx.ui.progress({ id = "index", clear = true })
```

### `ctx.ui.report(spec)`

readable document/report output. replacement for panel-shaped thinking.

```lua
ctx.ui.report({
  id = "git-status",
  title = "Git status",
  body = "M src/foo.zig\n?? notes.md\n",
  transient = true,
})
```

current public payload is plain text. this is deliberate.

future-compatible fields:

```lua
{
  id = "diff",
  title = "Diff summary",
  body = text,
  format = "text",        -- text now; markdown later when host-owned
  kind = "info",          -- optional report classification
  lifetime = "session",
  actions = {              -- later; host-owned commands/actions only
    { id = "copy", label = "Copy" },
    { id = "open", label = "Open in editor" },
  },
}
```

non-goals:

- no public `lines`/spans.
- no row/column geometry.
- no component constructors.
- no direct overlay handle.

substrate gaps that would make reports excellent:

- retained scroll position by report `id`.
- selectable/copyable body text.
- markdown as a host-owned `format`, not lua spans.
- empty/error states.
- action footer once host actions are formalized.
- destination policy: inline report, bottom panel, modal overlay, transcript attachment, or non-TUI event stream.

### `ctx.ui.prompt(spec)`

modal interaction envelope.

```lua
local result = ctx.ui.prompt({
  kind = "input",
  title = "Session name",
  message = "Enter a short name",
  prefill = ctx.session.name() or "",
  placeholder = "my task",
  timeout_ms = 10000,
})
```

result envelope stays semantic:

```lua
{ status = "submitted", value = "..." }
{ status = "cancelled" }
{ status = "timeout" }
```

supported kinds today: `confirm`, `select`, `input`, `editor`.

future prompt improvements should prefer declarative validation over lua callbacks from input hot paths:

```lua
validate = {
  required = true,
  min_len = 1,
  max_len = 80,
  pattern = "^[%w%-%s]+$",
}
```

### `ctx.ui.pick(spec)`

selection/search intent. this should be the telescope-inspired primitive.

current static picker:

```lua
local result = ctx.ui.pick({
  title = "Choose model",
  options = {
    { value = "anthropic/claude", label = "Claude", description = "fast" },
    { value = "openai/gpt", label = "GPT", description = "broad" },
  },
})
```

richer entries are still static and callback-free:

```lua
local result = ctx.ui.pick({
  title = "Find decision",
  placeholder = "decision> ",
  empty_text = "No decisions",
  items = {
    {
      value = "entry-123",
      label = "Use ctx.ui.report",
      description = "extension-ui · today",
      search = "ctx.ui.report panel extension ui decision",
      preview = "Full note body...",
    },
  },
})

-- result.item carries the selected metadata.
```

future host-owned sources, still no paint-time lua:

```lua
ctx.ui.pick({
  title = "Session decisions",
  source = "session.entries",
  query = { label = "decision" },
})
```

or command-backed source:

```lua
ctx.ui.pick({
  title = "Files",
  source = { system = { "fd", "--type", "f" }, cwd = ctx.cwd },
})
```

future telescope-like concepts to design carefully:

- entries: current `value`, `label`, `description`, `search`, `preview`; future `ordinal` if needed.
- preview: static text first; host-owned source previews later.
- actions: host-owned action ids, not arbitrary lua callbacks from keypresses.
- multi-select: result value list.
- source lifecycle: bounded, cancellable, owner-safe.
- sorting/filtering: host-owned fuzzy scoring.

### editor actions

editor actions target the composer buffer only.

```lua
ctx.ui.paste_to_editor("please review this diff")
ctx.ui.set_editor_text("new prompt")
ctx.ui.clear_editor_text()
local text = ctx.ui.get_editor_text()
```

extensions do not replace the editor component, intercept raw key input, or own editor focus. prompt/editor modal is represented by `ctx.ui.prompt({ kind = "editor" })`.

## current TUI substrate inventory

this section names implementation capabilities, not public lua api.

### layout destinations

current composition has several materialization destinations:

| destination | current role | public equivalent |
| --- | --- | --- |
| transcript container | conversation rows, tool results, future attachments | future transcript/session annotation primitives |
| pending container | queued/pending messages | host-owned queue state; not public ui |
| widget-above-editor container | compact extension text above composer | `status`/future host policy, not public slot |
| composer header/onboarding container | greeter or extension header-like text | `report`/`message`/host policy, not public header slot |
| editor container | composer input | `editor_*` actions only |
| status line | primary/working/status data | `message`, `status`, `progress` |
| footer | bottom help/status affordances | host-owned; `message` may land here |
| overlay stack | modals, pickers, prompts | `prompt`, `pick`, maybe report destination |
| terminal title/notification backend | terminal-native affordances | host policy for `status`/`message` |

public api should describe the left column only through semantic primitives.

### component capabilities

| component/subsystem | capabilities observed | good semantic consumers | gaps / design notes |
| --- | --- | --- | --- |
| `Text` | plain text, word wrapping, padding, scroll offset, cached wrapped lines | `report`, `message`, simple widgets, banners | needs selectable/copyable text, retained scroll per id, stronger unicode/ansi policy, excellent empty states |
| `Markdown` | parses/render markdown to styled spans, padding, scroll offset, cached rendered lines | future `report({ format = "markdown" })`, transcript/tool presentation | keep host-owned; public lua should pass markdown text, not spans |
| `SelectList` | item value/label/description, keyboard navigation, scrolling indicator | `prompt(select)`, `pick` | item metadata is thin; no preview/actions/multi-select |
| `ListPicker` | modal bordered picker, optional search, fuzzy filtering, status row, initial selection, callbacks | `pick`, model/settings/login pickers, select prompts | `MAX_ITEMS`/`MAX_QUERY` caps, no preview pane, no async source, callbacks are TUI-local not lua |
| `OverlayManager` / `TUI.showOverlay` | stack, focus capture/restore, anchors, width/height options, backdrop/surface policy | `prompt`, `pick`, modal report destination | do not expose raw geometry; add semantic destination policies instead |
| `StatusData` | model/thinking/context/streaming data, extension status map | `status`, model status, compact state | extension status values are string-only and sorted by key; future priority/kind may need richer records |
| `StatusLine` | primary message, working shimmer, extension statuses, one-row measurement | `message`, `progress`, `status` | progress lifecycle should become explicit; current working state is singleton-ish |
| `Editor` / `EditorInterface` | composer text mutation, paste, clear, get text, submit callbacks, autocomplete | `editor_*`, prompt editor | extension api should not expose cursor/focus/raw input until semantic editor actions require it |
| `Footer` | static/help footer style destination | host policy for messages/help | do not resurrect `set_footer`; use message/status/report intent |
| `terminal_notify` | OSC/tmux terminal notification strings | `message` | host policy should decide when terminal notifications fire |
| `Transcript` / tool display | retained conversation rows, tool rendering, selections, render caches | future annotations, notes/labels, renderer refs | should consume semantic session entries/attachments, not extension-owned row objects |
| `box_chrome` / `boxed_surface` | borders, boxed surfaces, line styling | reports, pickers, modals | substrate only; no public border/geometry api |

## current host-owned extension ui records

current implementation now uses semantic transport names for extension ui. these names are still internal records, not public lua objects.

| internal record/family | current use | semantic meaning |
| --- | --- | --- |
| `Report` | report body flattened into TUI-owned text materialization | `ctx.ui.report` transport |
| `UiPublication.message` | short feedback text | `ctx.ui.message` |
| `UiPublication.status` | keyed extension status in `StatusData` | `ctx.ui.status` |
| `UiPublication.progress` | compact progress text materialization | `ctx.ui.progress` |
| `PromptRequest` | confirm/select/input/editor prompt | `ctx.ui.prompt` and `ctx.ui.pick` |
| `EditorAction` | composer mutations | `ctx.ui.editor_*` |

follow-on implementation should add richer records only where the semantic primitive demands it. the current transport no longer exposes slot-shaped header/footer/widget/overlay variants.

## overlay policy

raw overlay is powerful but should remain host-private.

bad public direction:

```lua
ctx.ui.overlay({ row = 4, col = 10, width = 80, component = "markdown" })
```

better public directions:

```lua
ctx.ui.prompt({ kind = "input", title = "Name" })
ctx.ui.pick({ title = "Branch", options = branches })
ctx.ui.report({ title = "Diff", body = diff, display = "modal" }) -- maybe later
```

if a future extension asks for overlay access, first ask which semantic primitive is underpowered:

- needs readable output? improve `report`.
- needs choice/search? improve `pick`.
- needs input/form? improve `prompt` or add `form`.
- needs diagnostics/results navigation? add `list`/quickfix-like primitive.
- needs transcript context? add semantic annotations/attachments.

only after those fail should zi consider a constrained destination hint. even then, expose host-owned display policy, not geometry/focus handles.

## picker policy

`pick` deserves the most design investment.

neovim/telescope lesson: a great picker is not a list widget. it is a pipeline:

```text
source -> entries -> matcher/sorter -> preview -> actions -> result
```

zi-safe version:

- source is static data or host-owned async source.
- entries are serializable values.
- matcher/sorter runs in host/TUI, not lua per keystroke.
- preview is static text first; dynamic previews are host-owned requests later.
- actions are host actions or command dispatch, not TUI-hot-path lua callbacks.
- final result resumes lua once, on the owner thread, through the existing prompt/yieldable pattern.

recommended growth path:

1. `options`/`items` with `value`, `label`, `description`, `search`, and static `preview` is shipped.
2. selected item envelope is shipped.
3. add multi-select only when an extension needs it.
4. add host-owned source descriptors.
6. add action descriptors.

## report policy

reports should become zi's "read this output" primitive.

good report implementation qualities:

- plain text baseline always works.
- long text scrolls naturally.
- same `id` updates in place and preserves useful scroll state when possible.
- body can be copied or inserted into editor.
- optional markdown is parsed by host.
- report actions are host-owned action descriptors.
- destination is host policy: inline surface, bottom sheet, overlay, transcript attachment, or non-TUI event stream.

avoid adding public rich text spans early. once spans cross the lua boundary, every renderer detail becomes api.

## progress policy

progress should be a small retained registry rather than a single working label.

semantic records should include:

- `id`
- `status`: `running`, `done`, `error`, `cancelled`
- `title`
- `detail`
- optional `current` / `total`
- optional `indeterminate`
- optional `parent_id` later for nested work

TUI may collapse multiple progress records into one status-line segment. non-TUI hosts may expose them as events.

## transcript and annotations

not all extension ui belongs near the composer.

zi already has durable session primitives: message `entry_id`, notes, labels, entry lookup, and label queries. future transcript ui should build on those semantics.

possible future primitives:

```lua
ctx.ui.annotate(entry_id, {
  kind = "decision",
  text = "accepted",
})
```

or, more likely, no new ui api at first: notes and labels drive transcript affordances automatically through host policy.

rule: extensions should attach semantics to entries; TUI decides where markers, badges, folds, signs, or side summaries appear.

## non-TUI host fit

semantic ui must survive outside the interactive terminal.

| primitive | batch/headless/rpc interpretation |
| --- | --- |
| `message` | log/event record |
| `status` | latest state snapshot |
| `progress` | progress event/snapshot |
| `report` | artifact/document output |
| `prompt` | unsupported/cancel/default unless host supplies interaction |
| `pick` | unsupported/cancel/default unless host supplies interaction |
| `editor_*` | unsupported/no-op or request-specific input buffer policy |

this is another reason not to expose component/overlay APIs.

## api anti-patterns

avoid these unless deliberately adding a new semantic family:

```lua
ctx.ui.set_footer("...")
ctx.ui.set_header("...")
ctx.ui.set_widget("...")
ctx.ui.show_overlay({ ...geometry... })
ctx.ui.text({ spans = ... })
ctx.ui.component("Markdown", ...)
ctx.ui.on_key(function(key) ... end)
```

these make lua responsible for layout, focus, paint timing, or renderer internals.

## endgame vs current state

this table is the guardrail against the api becoming scattered.

| primitive | endgame contract | current public api | current materialization | consistency gaps to close |
| --- | --- | --- | --- | --- |
| `message` | ephemeral short feedback with `{ kind, id?, lifetime? }`; host routes to composer-adjacent text/status/toast/log | exists as `ctx.ui.message(text, opts?)`; `id` and `kind` are distinct | publishes `UiPublication.message` and materializes as TUI-owned short text | decide terminal-notification policy |
| `status` | compact retained state keyed by `id`; optional `label`, `kind`, `priority`, `lifetime`; no placement | exists as `ctx.ui.status({ id, text/value })` | publishes `UiPublication.status`, maps to `StatusData.extension_statuses` and `StatusLine` | internal storage is string-only and sorted by key; no severity/priority yet |
| `progress` | retained work lifecycle keyed by `id` with `status = running/done/error/cancelled`, `title`, `detail`, counts | exists as `ctx.ui.progress(spec)` with preserved semantic fields | publishes `UiPublication.progress` and materializes compactly near reports/messages | needs richer retained registry/materialization, not a new public shape |
| `report` | durable readable document by `id`; plain text baseline; future host-owned markdown/actions/destination policy | exists as `ctx.ui.report({ id?, title?, body, transient? })` | travels through internal `Report` transport and `Text` materialization | preserve scroll by id; add explicit `format = "text"` before markdown |
| `prompt` | modal request envelope with typed kind, declarative validation, timeout, semantic result | exists as `ctx.ui.prompt({ kind = confirm/select/input/editor, ... })` | uses `Overlay`, `ListPicker`, and `Editor` flows | add declarative validation; keep result shape aligned with `pick` |
| `pick` | telescope-like chooser: entries/source/search/preview/actions/multi-select over time; no hot-path lua callbacks | exists as `ctx.ui.pick({ title, options })` | currently prompt/select-shaped over `ListPicker`/`SelectList` | add richer item fields, selected item in result, placeholder/empty text, static preview; keep callbacks host-owned |
| `editor_*` | explicit composer buffer actions only | exists as set/paste/clear/get editor text | maps through `EditorAction` to composer `Editor` | naming is intentionally action-shaped; do not add raw cursor/focus/key APIs without semantic editor jobs |
| transcript annotations | semantic decorations derived from session entries/notes/labels/attachments | not yet a `ctx.ui` primitive | transcript already has retained row/render caches | prefer automatic rendering of notes/labels before adding a new lua ui method |

### consistency rules

all public `ctx.ui` primitives should obey the same grammar:

1. **intent names, not destinations**: `report`, not `panel`; `message`, not `footer`; `pick`, not `select_list`.
2. **tables for retained/complex specs**: `status`, `progress`, `report`, `prompt`, and `pick` take a spec table. `message` may keep string sugar because short feedback is the common path.
3. **stable `id` means replacement/dedupe within the primitive family**: an id in `status` does not collide with the same id in `report`.
4. **`kind` means semantic classification**: info/warning/error/success or domain-specific kind; it never means a component class.
5. **`status` means lifecycle state only where that is the domain**: use it for prompt/result/progress envelopes; avoid using `status` as arbitrary display text when `text`, `title`, or `detail` is clearer.
6. **`lifetime` is a host hint**: session/until_input/etc. never exposes cleanup handles or component ownership.
7. **modal primitives return envelopes**: `prompt` and `pick` return `{ status = ... }`; non-modal publications return nothing/use boolean success only if needed.
8. **payloads crossing lua are serializable data**: no component instances, raw handles, focus objects, or paint/input callbacks.
9. **host owns layout and fallback**: every primitive must make sense in TUI, batch, and future RPC hosts.
10. **internal names must reinforce public intent**: internal extension-ui records should speak report/message/status/progress/prompt/pick/editor-action vocabulary, not slot vocabulary.

### current internal cleanup backlog

these are implementation debts, not public api holes:

- add richer retained progress registry/materialization on top of the existing semantic progress record.
- keep `PromptRequest.SelectOption` metadata serializable; `description`, `search`, and static `preview` are host-owned data, not callbacks.
- define terminal notification policy as one possible host materialization of `message`, not a separate extension concept.

## research conclusions

1. current substrate is already rich enough for a good semantic api: text, markdown, overlay, picker, status, editor, transcript, and terminal notification all exist.
2. public api should remain small; the substrate should get better underneath it.
3. `report`, `prompt`, and `pick` are the high-leverage primitives. if they are excellent, most extensions never need raw UI.
4. the endgame surface is coherent if every primitive follows the same naming, id, lifetime, envelope, and owner-boundary rules above.
5. `pick` should grow toward telescope-like source/entry/preview/action concepts, but using serializable host-owned records rather than lua callbacks from input hot paths.
6. `report` should grow toward a durable readable document primitive, not a public panel/layout API.
7. `progress` should become an explicit retained lifecycle registry, not just a working string.
8. overlay should remain an implementation destination. expose semantic display policy only if required later.
9. transcript UI should be driven by semantic session annotations, notes, labels, and renderer refs — not injected rows.

## recommended next implementation slices

### slice 1: make `message` richer but still tiny

- accept `{ kind, id, lifetime }`.
- use `kind` for severity/dedupe routing.
- keep destination host-owned.

### slice 2: make `progress` semantic

- accept `status = "running" | "done" | "error" | "cancelled"`.
- keep compact materialization in status line for now.
- allow multiple keyed progress records internally even if TUI collapses them.

### slice 3: strengthen `pick` v1.5

- support item `description` in public lua.
- return selected item as well as value.
- support `placeholder` / `prompt` and `empty_text`.
- no lua callbacks during search.

### slice 4: improve report substrate

- preserve scroll by report `id`.
- use `Markdown` only behind `format = "markdown"`.
- add copy/insert actions once host actions are formalized.

### slice 5: transcript annotations

- render notes/labels near transcript entries through host policy.
- avoid new lua UI until session semantics prove insufficient.

# extension ui primitives

## status

public lua api contract for semantic extension ui.

this specializes [extensions-ui-contract.md](./extensions-ui-contract.md), [extensions-ui-substrate-map.md](./extensions-ui-substrate-map.md), [extensions-retained-objects.md](./extensions-retained-objects.md), and [extensions-lifecycle.md](./extensions-lifecycle.md).

## decision

extension ui is intent-shaped.

public lua does not expose component names, overlay geometry, slot placement, renderer spans, or terminal layout. extensions publish semantic requests; zi owns materialization.

## public surface

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

removed public shapes:

```lua
ctx.ui.show_panel(...)
ctx.ui.notify(...)
ctx.ui.set_status(...)
ctx.ui.set_title(...)
ctx.ui.set_widget(...)
ctx.ui.set_header(...)
ctx.ui.set_footer(...)
ctx.ui.set_working(...)
ctx.ui.set_hidden_thinking_label(...)
ctx.ui.show_overlay(...)
ctx.ui.confirm(...)
ctx.ui.select(...)
ctx.ui.input(...)
ctx.ui.editor(...)
```

there are no compatibility aliases.

## primitives

### message

short feedback.

```lua
ctx.ui.message("Saved note", {
  id = "save-status",
  kind = "success",
  lifetime = "until_input",
})
```

`id` is the family-scoped dedupe/update key. `kind` is a semantic hint (`info`, `warning`, `error`, `success`). hosts may render messages near the composer, in a status line, as a toast, notification backend, log entry, or non-tui event stream.

### status

compact retained state by stable id.

```lua
ctx.ui.status({ id = "git", text = "clean" })
ctx.ui.status({ id = "git", value = "dirty" })
ctx.ui.status({ id = "git" }) -- clear
```

status is not a widget slot. host owns ordering, truncation, style, and placement.

### progress

retained progress lifecycle state.

```lua
ctx.ui.progress({
  id = "index",
  status = "running", -- running | done | error | cancelled
  title = "Indexing",
  current = 42,
  total = 120,
  detail = "src/tui/interactive.zig",
})
```

zi preserves the semantic fields even when v1 materialization is compact. future hosts may add child progress, richer progress views, or non-tui progress events without changing the lua intent.

### report

readable document/report output.

```lua
ctx.ui.report({
  id = "git-status",
  title = "Git status",
  body = "M src/foo.zig\n?? notes.md\n",
  transient = true,
})
```

`body` is plain text. zi owns splitting, wrapping, scrolling, markdown support, and final destination. a report is not a panel command.

### prompt

modal interaction envelope.

```lua
local result = ctx.ui.prompt({
  kind = "confirm",
  title = "Run command?",
  message = "git clean -fd",
  timeout_ms = 10000,
})

if result.status == "submitted" and result.value then
  -- user confirmed
end
```

supported kinds: `confirm`, `select`, `input`, `editor`.

### pick

selection intent, inspired by `vim.ui.select` but result-envelope shaped.

```lua
local result = ctx.ui.pick({
  title = "Choose model",
  placeholder = "model> ",
  empty_text = "No models",
  options = {
    {
      value = "anthropic/claude",
      label = "Claude",
      description = "fast, strong coding",
      search = "claude anthropic sonnet coding",
      preview = "Claude\nProvider: Anthropic\nGood for coding.",
    },
    { value = "openai/gpt", label = "GPT", description = "broad" },
  },
})

if result.status == "submitted" then
  -- convenience value
  print(result.value)

  -- selected item metadata, when supplied by the option
  print(result.item.label)
  print(result.item.description)
end
```

`options` may also be spelled `items`. each item is serializable host-owned data: `value`, `label`, `description`, `search`, and `preview`. `search` influences host-owned matching without calling lua from the input hot path. `preview` is static metadata for host materialization; dynamic preview callbacks are intentionally not part of this surface.

`pick` is for choosing from bounded options. broader durable browsable lists/search results should become a separate list/quickfix-like primitive.

### editor actions

editor actions target the host-owned composer buffer.

```lua
ctx.ui.paste_to_editor("please review this diff")
ctx.ui.set_editor_text("new prompt")
ctx.ui.clear_editor_text()
local text = ctx.ui.get_editor_text()
```

extensions never replace the editor component.

## consistency grammar

all public primitives follow one grammar:

- names describe intent, not destinations: `report`, `message`, `pick`.
- retained or complex operations take spec tables.
- stable `id` is family-scoped replacement/dedupe state.
- `kind` is semantic classification, not a component or color token.
- `lifetime` is a host hint, not a cleanup handle.
- modal operations return result envelopes; non-modal publications do not return UI handles.
- payloads are serializable host data; no component instances, focus handles, geometry handles, or paint/input callbacks cross lua.

see [extensions-ui-substrate-map.md](./extensions-ui-substrate-map.md) for the endgame-vs-current comparison and implementation backlog.

## neovim inspiration

- `vim.notify` inspires `ctx.ui.message`.
- `vim.ui.input` inspires `ctx.ui.prompt({ kind = "input" })`.
- `vim.ui.select` inspires `ctx.ui.pick`.
- quickfix/location lists inspire a future `ctx.ui.list` primitive.
- floating windows inspire reports/prompts as host-owned destinations, not raw geometry.
- extmarks/signs inspire future transcript/session annotations, likely backed by semantic notes/labels.

## non-goals

no public:

- component factories.
- raw overlay handles or placement geometry.
- slot claims such as header/footer/widget.
- line/span renderer payloads for reports.
- terminal input listeners.
- lua callbacks from TUI paint/input paths.
- compatibility aliases for retired names.

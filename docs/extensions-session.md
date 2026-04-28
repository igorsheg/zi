# extension session api

## status

contract for extension-visible session context helpers.

this follows [extensions.md](./extensions.md), [extensions-events.md](./extensions-events.md), [extensions-state-rebinding.md](./extensions-state-rebinding.md), and [runtime.md](./runtime.md).

## decision

extension session APIs expose host-owned semantic session objects, not raw jsonl rows, transcript render rows, or storage internals.

rules:

- session reads use the current visible branch: persisted branch plus buffered tail.
- durable ids are session entry ids, not UI row ids.
- extension-visible mutation appends semantic entries; it does not rewrite prior transcript content.
- helper payloads are JSON-compatible tables owned by the host boundary.
- missing data returns `nil`, `false`, or an empty list according to the helper family; it does not expose storage errors as raw exceptions.

## durable entry ids

`zi.on("message", ...)` publishes semantic message events after session persistence and includes `event.message.entry_id`.

that id can be used with:

- `ctx.session.entry(entry_id)` to dereference the entry.
- `ctx.session.append_note({ source_entry_id = entry_id, ... })` to attach prose/artifacts.
- `ctx.session.label(entry_id, label)` to attach a lightweight marker.
- `ctx.session.notes({ source_entry_id = entry_id })` and `ctx.session.labels({ target_entry_id = entry_id })` to follow backlinks.

raw `message_end` remains an agent lifecycle observer. semantic `message` is the durable/session-aware message event.

## context surface

### session info

`ctx.session.info()` returns session metadata such as id, cwd, file, and name.

`ctx.session.name()` returns the visible session name or `nil`.

`ctx.session.rename(name)` appends session metadata and returns boolean success. `nil` clears the name.

### messages and tool results

`ctx.session.messages({ limit?, include_tools? })` returns recent semantic message envelopes from the visible branch.

message shapes include:

```lua
{ entry_id = "...", role = "user", text = "..." }
{ entry_id = "...", role = "assistant", text = "..." }
{ entry_id = "...", role = "tool_call", tool_call_id = "...", tool_name = "...", args = {...} }
{ entry_id = "...", role = "tool_result", tool_call_id = "...", tool_name = "...", is_error = false, content = {...}, details = {...} }
```

`include_tools` defaults to true. `limit` defaults to 50 and is capped by the host.

`ctx.session.tool_results(tool_name)` returns recorded tool result envelopes for one tool.

### notes

notes are extension-owned custom session artifacts. they are durable, but they are not transcript mutation and are not automatically injected into model context.

```lua
ctx.session.append_note({
  kind = "observation",
  title = "optional title",
  body = "what to remember",
  source_entry_id = event.message.entry_id,
})
```

`sourceEntryId` is accepted as a Lua-side alias for `source_entry_id` where supported.

`ctx.session.notes({ kind?, source_entry_id?, limit? })` returns notes, newest window capped by `limit` after filtering.

returned notes include their own durable `entry_id` plus the stored note fields.

### labels

labels are lightweight durable markers attached to another session entry.

they are intentionally not a taxonomy system: no built-in meanings, colors, priorities, registry, or rendering policy.

```lua
ctx.session.label(entry_id, "decision")
ctx.session.label(entry_id, nil) -- clear
ctx.session.label(entry_id, "")  -- clear
```

`ctx.session.labels({ target_entry_id?, limit? })` returns label entries:

```lua
{
  entry_id = "label-entry-id",
  type = "label",
  target_entry_id = "message-entry-id",
  label = "decision", -- or nil for a clear entry
}
```

### entry lookup

`ctx.session.entry(entry_id)` returns a semantic entry envelope or `nil`.

message entries flatten to the same semantic shape used by `ctx.session.messages()` when the entry maps to one semantic message:

```lua
{ entry_id = "...", type = "message", role = "user", text = "..." }
```

assistant entries with multiple semantic parts may return:

```lua
{ entry_id = "...", type = "message", messages = { ... } }
```

extension notes return:

```lua
{ entry_id = "...", type = "extension_note", kind = "...", title = "...", body = "...", source_entry_id = "..." }
```

labels return the label envelope above.

other session entry families may return a minimal typed envelope:

```lua
{ entry_id = "...", type = "compaction" }
```

### entry queries

`ctx.session.entries({ label?, limit? })` returns semantic target entries for simple host-owned predicates.

currently the only predicate is `label`.

label query semantics:

- scans label entries in the current visible branch.
- latest label wins per target entry.
- clear labels (`nil` / empty-string label writes) exclude the target.
- returns target entries, not label entries.
- preserves visible branch order of the target entries before applying the final limit window.

example:

```lua
for _, entry in ipairs(ctx.session.entries({ label = "decision", limit = 20 })) do
  print(entry.text or entry.entry_id)
end
```

## composition pattern

```lua
zi.on("message", function(event, ctx)
  local message = event.message or {}
  if message.role == "user" and message.text and message.text:match("decision") then
    ctx.session.label(message.entry_id, "decision")
    ctx.session.append_note({
      kind = "observation",
      body = "decision candidate",
      source_entry_id = message.entry_id,
    })
  end
end)
```

later:

```lua
for _, entry in ipairs(ctx.session.entries({ label = "decision" })) do
  local notes = ctx.session.notes({ source_entry_id = entry.entry_id })
  -- compose the entry and notes into a handoff or report.
end
```

## non-goals

this api does not expose:

- raw jsonl mutation.
- transcript render rows or TUI component ids.
- a general search/query language.
- label meanings, colors, priorities, or builtin category semantics.
- provider/model context mutation.

extensions should build workflow-specific behavior by composing messages, notes, labels, entry lookup, and side-channel AI completion.

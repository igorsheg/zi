Issue tracking: `bd prime`

## Reference Code

pi-mono is cloned locally at `.references/pi-mono/`. When you need to reference pi-mono source (types, implementations, patterns), always use local reads/greps against `.references/pi-mono/` - never the github tools. The code is on disk.

opentui is cloned locally at `.references/opentui/`. When you need to reference opentui source (zig TUI patterns, buffer/renderer/utf8), always use local reads/greps against `.references/opentui/` - never the github tools. The code is on disk.

## Doctrine

zi must never be less capable than pi-mono at the architecture, design, or product layer. minimum bar: parity with pi-mono. maximum bar: extend pi-mono while preserving its contracts. zig is an implementation advantage, not a reason to collapse product surfaces, remove composition seams, or replace dedicated flows with narrower shortcuts.

when a zi surface drifts from pi-mono, default assumption is to close the drift, not defend it. if we simplify, that simplification must still preserve pi-mono-level capability and extensibility.

- no compatibility theater if a bad api blocks the right architecture
- no "quick fix" shim that papers over drift instead of removing it

## JSON Serialization

**do NOT hand-roll JSON.** use `std.json.Stringify` for writing and `std.json.parseFromSlice` for reading.

- **writing**: create a `std.io.Writer.Allocating`, wrap in `std.json.Stringify`, use `jw.beginObject()` / `jw.objectField("camelCase")` / `jw.write(value)` / `jw.endObject()`. this handles escaping, commas, and nesting correctly. get output via `out.toOwnedSlice()`.
- **reading**: parse into `std.json.Value` with `std.json.parseFromSlice`, extract fields by camelCase name. for struct-based parsing, use `std.json.parseFromSlice(MyStruct, ...)` when field names match.
- **shared utils**: `packages/ai/src/json_util.zig` — `cloneJsonValue`, `jsonToFloat`, enum↔string converters (`providerToString`/`parseProvider`, `parseApi`, `stopReasonToString`/`parseStopReason`). use these instead of writing local copies.
- **camelCase wire format**: zig structs use snake_case but pi-mono's JSON uses camelCase. we handle this with explicit `jw.objectField("camelCase")` calls — NOT by renaming struct fields.

## Implementation Process

two failure modes, opposite directions:

**don't approximate the protocol.** before writing any function that emits events or builds protocol objects, find the exact pi-mono function, read it fully, trace every event emitted and every field set. the pi-mono source is at `.references/pi-mono/` on disk. the WHAT must match — same events, same order, same fields.

**don't port the syntax.** never translate typescript line-by-line into zig. `async/await` → blocking calls, `Promise.all` → sequential or threads, `Array.map` → explicit loops, `try/catch` → error unions or result fields. the HOW should be idiomatic zig.

the process:
1. find the pi-mono function (e.g., `streamAssistantResponse`, `emitToolCallOutcome`)
2. list the observable behavior: events emitted, fields set, ordering, edge cases
3. write zig that produces the same observable behavior using zig idioms
4. oracle audit verifies parity after, not instead of tracing

## Testing Doctrine

**NO test spray.** we do not generate tests per-function. we test behavior at boundaries.

- **max 3-5 tests per task.** if you need more, the task is too big or you're testing implementation.
- **every test name states the behavior it verifies.** `test "session round-trips all 9 entry types"` not `test "parseEntry works"`.
- **no mocks unless crossing a network boundary.** use real modules.
- **conformance fixtures come from pi-mono** (real session files, provider responses, event transcripts). generate by running pi-mono, not by hand-writing JSON.
- **a test that can't break when behavior changes shouldn't exist.**

test types, in priority order:

1. **conformance** - golden fixtures proving our output matches pi-mono byte-for-byte.
2. **boundary** - exercise the contract between two modules (e.g., session write → read → buildSessionContext round-trip).
3. **behavior** - test what a module DOES, not how (e.g., "compaction keeps recent messages and produces summary" not "findCutPoint returns index 7").

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**

- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

## TUI Architecture

zi's TUI is a reusable component framework, not ad-hoc rendering. understand these patterns before making changes.

### Component model
- `Component` (component.zig): vtable interface — `render(Region)`, `handleInput(Key) → bool`, `measure(width) → Measurement`, `cursorState() → ?CursorState`, `setFocused(bool)`. every visible element implements this.
- `Container` (container.zig): vertical stack layout. one child can be `flex` (fills remaining space). one child is `focused` (receives input, provides cursor offset).
- components are borrowed, not owned. containers don't manage lifetimes.

### Layout tree
Interactive (composition root) owns the tree:
```
root Container (flex=transcript)
  [0] header_container
  [1] transcript (flex child — fills remaining space)
  [2] pending_container
  [3] status_container
  [4] widget_above_container
  [5] editor_container (focused — cursor comes from here)
  [6] widget_below_container
  [7] footer
```
when the editor's autocomplete picker is active, `editor.measure()` grows → transcript shrinks → picker appears inline below the editor border. this is NOT an overlay — it's the container re-laying out.

### Overlay system
- `OverlayManager` (overlay.zig): z-ordered stack. overlays render on top of the root tree into the same cell buffer.
- `TUI.showOverlay(component, options) → OverlayHandle`: pushes overlay, captures focus. `hideOverlay()` pops, restores focus.
- `OverlayPresets` (overlay.zig): generic presets (`centerDialog`, `topToast`). app-specific presets live in interactive.zig (`bottomPanelOptions` — accounts for header/footer height).
- input priority: when overlay is active, keys route to overlay first. Esc/Ctrl+C dismiss overlay before reaching app-level handlers.

### Reusable picker infrastructure
three composable pieces:
1. **`SelectList`** (components/select_list.zig): dumb renderer/navigator. receives pre-filtered items, handles ↑↓/Enter/Esc, reports `InputResult { consumed, selected, cancelled, unhandled }`. NOT a Component — no vtable.
2. **`ListPicker`** (components/list_picker.zig): wraps SelectList as a Component for overlay use. bordered box with title. opt-in fuzzy search input (`setSearchableItems`). owns query buffer + filtered scratch. reports cursor for search input.
3. **`fuzzy.zig`**: pure algorithm — `fuzzyMatch(query, text) → {matches, score}`, `fuzzyFilter(query, texts, out_indices) → count`. deterministic sort (alphabetical tiebreaker). empty query returns alphabetical order.

to build a new picker overlay:
```zig
var picker = ListPicker.init(self.theme);
picker.setSearchableItems(items, null);  // null = search on .label
picker.on_select = &callback;
picker.callback_ctx = @ptrCast(self);
self.handle = self.tui.showOverlay(picker.component(), self.bottomPanelOptions());
```

### Autocomplete (inline, not overlay)
slash command autocomplete uses a different path — it's inline in the editor, not an overlay:
- `AutocompleteProvider` (autocomplete.zig): vtable with `request(snapshot, sink)`, `cancel()`, `apply()`. `SuggestionSink` allows sync or async delivery.
- `SlashCommandProvider`: reads from `CommandRegistry`, runs `fuzzyFilter`, publishes via sink synchronously.
- editor owns the `SelectList` instance and renders it below the bottom border. `measure()` grows when active.
- `autocomplete_prefix_len: u32` — stored as length, NOT a borrowed slice (buffer can reallocate).

### Slash commands
- `CommandRegistry` (slash_commands.zig): static builtins + dynamic list. `SlashCommand` has `CommandAction` tagged union (builtin/extension/prompt_template/skill).
- dispatch in `interactive.zig`: `/quit`, `/clear`, `/resume` have real handlers. others fall through to `stubHandler` or action-based dispatch.
- extension seam: `registry.register(SlashCommand{ .action = .{ .extension = ... } })` — no TUI changes needed.

### Persistence
all paths go through `storage.zig`:
- `getAgentDir()` → `~/.zi/agent` (or `ZI_CODING_AGENT_DIR`)
- `getProjectDir(cwd)` → `<cwd>/.zi`
- `getSessionDirForCwd()` → `~/.zi/agent/sessions/<encoded-cwd>`
- `SessionStore` (session/store.zig): facade over writer/reader/context. `create()`, `open()`, `findMostRecent()`, `listSessions()`, `buildContext()`, all 9 entry type appenders.

### Key anti-patterns to avoid
- do NOT make SelectList a Component — it returns InputResult, not bool. ListPicker is the adapter.
- do NOT store borrowed slices into editor.buf across input events — use lengths/indices instead.
- do NOT add overlay dismiss logic to individual components — the composition root handles it via input priority chain.
- do NOT hardcode paths — use storage.zig helpers.
- do NOT run `zig build test` — it times out. use `zig build` for compilation checks, `zig test src/file.zig` for standalone files.

pi-mono is 5 products stacked:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │ PRODUCT: terminal coding agent you talk to                      │
  │                                                                 │
  │  L5  COMPOSITION ROOT (coding_agent)                            │
  │      - wires everything below into a working app                │
  │      - session persistence (JSONL tree)                         │
  │      - compaction (auto-summarize long contexts)                │
  │      - extension system (TS modules that add tools/UI/hooks)    │
  │      - resource discovery (skills, prompts, themes, packages)   │
  │      - CLI modes (interactive/print/json/rpc)                   │
  │                                                                 │
  │  L4  STATEFUL AGENT (agent)                                     │
  │      - dual-loop: inner=tools+steering, outer=follow-ups        │
  │      - tool lifecycle: prepare(validate) → execute → finalize   │
  │      - cancellation threading through all boundaries            │
  │      - AgentState with streaming/pending/error tracking         │
  │      - queue semantics for steering vs follow-up messages       │
  │      - public api: prompt/continue/steer/followUp/abort/wait    │
  │                                                                 │
  │  L3  TERMINAL UI (tui)                                          │
  │      - differential line renderer (compare prev vs new)         │
  │      - component model: render(width) → string[]                │
  │      - container/focus/overlay stack                             │
  │      - keyboard: kitty protocol + xterm fallback                │
  │      - synchronized output (CSI 2026)                           │
  │                                                                 │
  │  L2  LLM SUBSTRATE (ai)                                         │
  │      - message types (user/assistant/toolResult)                │
  │      - streaming event protocol (12 event variants)             │
  │      - provider interface + registry                            │
  │      - 18+ provider implementations                             │
  │      - model catalog with cost tracking                         │
  │      - transport (HTTP+SSE)                                     │
  │                                                                 │
  │  L1  DATA FORMATS (shared types across all layers)              │
  │      - ContentBlock = text|thinking|image|toolCall              │
  │      - Message = user|assistant|toolResult                      │
  │      - Usage, Cost, StopReason                                  │
  │      - Model (id, api, provider, cost, context window)          │
  │      - Session entry types (9 variants)                         │
  │      - AgentEvent (10 variants)                                 │
  │      - AssistantMessageEvent (12 variants)                      │
  └─────────────────────────────────────────────────────────────────┘
```

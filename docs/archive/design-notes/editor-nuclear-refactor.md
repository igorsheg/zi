# Editor nuclear refactor spec

## status

design proposed. implementation not started.

## intent

Refactor zi's prompt editor into a real editor architecture with explicit buffer/view/chrome seams.

This is a **nuclear refactor**:

- no backward-compat wrapper layer
- no compatibility shim that preserves the current monolith behind a new API
- no "temporary" bridge that keeps both old and new editor layouts alive in production code
- any upstream caller that breaks must be updated to the new seams immediately

The editor is not a stable external API. We should fix the architecture now, not build debt-preserving adapters around the current shape.

## why now

We already applied the right OpenTUI lesson to transcript rendering:

- retained semantic state
- width/state layout cache
- visible-slice rendering only
- no full-surface fallback in the viewport hot path

The prompt editor still carries the old shape:

- text storage, wrapping, viewport, cursor mapping, chrome, autocomplete composition, and input handling live in one component
- many code paths independently rebuild wrapped-line scratch state
- visual navigation and cursor visibility are derived ad hoc from recomputed wrap data

Today this is acceptable only because the prompt editor is smaller than the transcript. It is **not** a good platform for:

- wrapped-line-aware navigation parity
- sticky visual column behavior
- grapheme-correct movement/deletion
- undo/coalescing
- richer autocomplete
- selection
- future extension UI input surfaces

If we keep the monolith, every feature adds more recomputation and more hidden coupling. We should split the seams before feature work deepens the wrong architecture.

## doctrine

### 1. buffer, view, and chrome are different products

They have different responsibilities and must not collapse into one object.

- **buffer** owns text + edit semantics
- **view** owns width-dependent visual layout + viewport semantics
- **chrome/component** owns borders, prompt prefix, status text, autocomplete composition, and TUI integration

### 2. paint is not allowed to discover layout

Rendering must consume cached visual state. It may not build wrapped-line scratch structures on demand.

### 3. visual navigation is first-class

A wrapped editor is not a single-line text field with extra newlines. It needs explicit visual-line semantics:

- logical cursor vs visual cursor
- desired visual column for up/down movement
- viewport-relative cursor reporting
- scroll margins

### 4. the editor is TUI-thread owned

Per threading doctrine:

- editor component, editor view, editor buffer, autocomplete UI state, transcript widgets, overlays: **TUI thread only**
- no editor method may call back into agent-thread or Lua-owned state on the hot path
- frequent reads must come from local state or published snapshots
- any request that mutates agent-owned state still goes through `AgentRequest`

### 5. flow-owned transient data still applies

The editor may borrow stable snapshot data, but transient derived UI data must have a clear owner.

Examples:

- slash-command candidate list from a published snapshot: may be borrowed if the snapshot contract is stable
- filtered autocomplete rows / preview strings / path display strings: owned by the editor flow or provider response owner, not by ephemeral scratch slices with unclear teardown

### 6. no shim policy

The refactor is complete only when:

- old wrapped-line scratch helpers are gone from the editor hot path
- old monolithic responsibilities are physically moved into dedicated modules
- upstream callers use the new seams directly

## reference lessons from OpenTUI

Relevant local references:

- `.references/opentui/packages/core/src/zig/edit-buffer.zig`
- `.references/opentui/packages/core/src/zig/text-buffer-view.zig`
- `.references/opentui/packages/core/src/zig/editor-view.zig`
- `.references/opentui/packages/core/src/zig/buffer.zig`

What we are borrowing:

1. **edit buffer as source of truth** for text + cursor mutation
2. **text/view layer** that owns wrap/virtual-line caches and invalidation
3. **editor view layer** that owns viewport and cursor-visibility semantics
4. **render only visible virtual lines**
5. **logical cursor != visual cursor** as an explicit model
6. **desired visual column** for wrapped up/down navigation
7. **scroll margin** so the cursor is not glued to viewport edges

What we are **not** blindly porting:

- OpenTUI's full general-purpose editor surface area
- multicursor if zi does not need it yet
- a compatibility facade preserving the current zi editor internals
- feature scope that outruns the new seams

## current anti-patterns to remove

The following shapes are specifically in scope to delete:

1. repeated `buildWrappedLinesScratch(...)` calls from unrelated editor methods
2. layout discovery inside `render()`, `measure()`, `cursorState()`, visual motion, and ensure-visible logic
3. one component owning text mutation, view layout, viewport management, and chrome simultaneously
4. cursor movement semantics defined in terms of ad hoc re-wrapping rather than cached visual structure
5. autocomplete composition coupled tightly to raw text buffer details instead of a buffer/view seam

## target architecture

```text
src/tui/editor/
  buffer.zig          // prompt text source of truth + edit operations
  view.zig            // width-dependent visual model + viewport + cursor mapping
  layout.zig          // wrapped/virtual line data structures and invalidation helpers
  navigation.zig      // visual/logical motion helpers, desired column, word motions later
  autocomplete.zig    // editor-local autocomplete session/composition state
  render.zig          // paints editor viewport/chrome-facing content rows from cached view
  types.zig           // shared structs: VisualCursor, WrappedLine, Viewport, etc
  root.zig            // public module exports

src/tui/components/
  editor.zig          // thin TUI Component shell using tui/editor/* modules
```

This split is intentionally opinionated:

- **buffer** must not know terminal width
- **view** must not own chrome or keybinding policy
- **render** must not mutate text or recompute layout semantics
- **component shell** must not hide the architecture by inlining everything again

## seam definitions

### A. `PromptBuffer`

Owns:

- text storage
- cursor byte offset and logical position
- insertion/deletion/newline operations
- history application hooks only if they are true text replacement operations
- future undo stack
- future grapheme-correct deletion/movement primitives

Must not own:

- viewport state
- wrap cache
- screen-relative cursor position
- chrome/borders
- autocomplete overlay rendering

Contract sketch:

```zig
pub const PromptBuffer = struct {
    pub fn init(allocator: Allocator) PromptBuffer;
    pub fn deinit(self: *PromptBuffer) void;

    pub fn text(self: *const PromptBuffer) []const u8;
    pub fn setText(self: *PromptBuffer, text: []const u8) void;
    pub fn clear(self: *PromptBuffer) void;

    pub fn insertAtCursor(self: *PromptBuffer, text: []const u8) void;
    pub fn backspace(self: *PromptBuffer) void;
    pub fn deleteForward(self: *PromptBuffer) void;
    pub fn insertNewline(self: *PromptBuffer) void;

    pub fn moveLeft(self: *PromptBuffer) void;
    pub fn moveRight(self: *PromptBuffer) void;
    pub fn moveLogicalLineStart(self: *PromptBuffer) void;
    pub fn moveLogicalLineEnd(self: *PromptBuffer) void;

    pub fn cursor(self: *const PromptBuffer) LogicalCursor;
    pub fn version(self: *const PromptBuffer) u64;
};
```

Notes:

- `version()` is the invalidation input for the view cache
- avoid exposing mutable internals to callers
- text lifetime is buffer-owned and TUI-thread confined

### B. `PromptView`

Owns:

- viewport (`scroll_x`, `scroll_y`, visible width/height)
- wrapped / virtual line cache
- logical↔visual cursor mapping
- desired visual column
- ensureCursorVisible behavior
- scroll margin policy
- width-dependent layout invalidation

Must not own:

- text mutation semantics
- border chrome
- prompt prefix strings
- status formatting
- submit policy

Contract sketch:

```zig
pub const PromptView = struct {
    pub fn init(allocator: Allocator, buffer: *PromptBuffer) PromptView;
    pub fn deinit(self: *PromptView) void;

    pub fn setViewportSize(self: *PromptView, width: u32, height: u32) void;
    pub fn setScrollMargin(self: *PromptView, margin: f32) void;

    pub fn ensureLayout(self: *PromptView) void;
    pub fn invalidateAll(self: *PromptView) void;

    pub fn visibleLines(self: *PromptView) []const VirtualLine;
    pub fn totalVisualLineCount(self: *PromptView) u32;
    pub fn visualCursor(self: *PromptView) VisualCursor;
    pub fn logicalToVisual(self: *PromptView, logical: LogicalCursor) VisualCursor;
    pub fn visualToLogical(self: *PromptView, row: u32, col: u32) ?LogicalCursor;

    pub fn moveUpVisual(self: *PromptView) void;
    pub fn moveDownVisual(self: *PromptView) void;
    pub fn ensureCursorVisible(self: *PromptView) void;
};
```

Notes:

- `ensureLayout()` is the single choke point for wrap/virtual-line recomputation
- all consumers reuse the same cached layout
- visual movement methods consult cached virtual lines, not scratch builders

### C. editor autocomplete session

Owns:

- active/inactive state
- selected suggestion index
- prefix length or replacement range
- provider response ownership / borrowed snapshot contract
- picker measurement and visible slice for inline rendering

Must not own:

- source text semantics beyond replace/apply contract
- ad hoc references into buffer slices that can dangle across reallocations

The key invariant remains:

- store **indices/lengths**, not borrowed slices into mutable editor buffers

### D. component shell (`src/tui/components/editor.zig`)

Owns:

- `Component` interface implementation
- keybinding dispatch
- prompt/status/chrome formatting
- composition of text viewport + inline autocomplete picker
- submit callback plumbing

Must delegate to buffer/view/autocomplete modules for real logic.

The shell should become thin enough that a reader can immediately see where responsibilities live.

## data model

### logical vs visual cursor

We should make this explicit in shared editor types.

```zig
pub const LogicalCursor = struct {
    byte: u32,
    line: u32,
    col: u32,
};

pub const VisualCursor = struct {
    visual_row: u32,   // viewport-relative when returned to component layer
    visual_col: u32,
    logical_line: u32,
    logical_col: u32,
    byte: u32,
};
```

### virtual lines

A virtual line is a width-dependent visual slice of the logical buffer. It is the editor analogue of transcript slice rendering.

Possible shape:

```zig
pub const VirtualLine = struct {
    byte_start: u32,
    byte_end: u32,
    logical_line: u32,
    logical_col_start: u32,
    width_cols: u32,
    kind: enum { prompt_first, wrapped_continuation, empty_line },
};
```

Exact fields can change, but the architecture requirement is fixed:

- wrapped visual structure must be cached and reusable
- render, measure, and cursor math all consume the same structure

## viewport rules

The editor view owns viewport semantics.

### horizontal scroll

Only applies when wrap mode is disabled for a given surface. For the current prompt editor, if wrapping remains enabled, horizontal scroll may stay inactive.

### vertical scroll

The viewport is in **visual-line space**, not logical-line count.

### scroll margin

Default margin should be explicitly chosen and documented. OpenTUI uses a fractional margin. zi should adopt the same idea.

Recommended initial default:

- `0.15` of viewport height
- clamped so tiny viewports do not over-constrain movement

### resize

On width change:

- invalidate visual layout
- rebuild virtual lines once
- clamp viewport
- ensure cursor remains visible

No caller should manually re-derive wrapped lines after resize.

## performance rules

### hot-path rules

These operations must be allocation-light and deterministic:

- `render()`
- `measure()`
- `cursorState()`
- visual up/down
- ensure-cursor-visible after cursor motion

### forbidden hot-path work

- rebuilding wrapped lines scratch arrays on every call
- re-scanning full text independently in multiple methods for the same frame
- layout work hidden inside cursor reporting
- unstable borrowing from `buf.items` across operations that may reallocate

### target invariant

For stable width and unchanged text:

- render cost is proportional to visible editor rows
- cursor state query cost is O(1) or amortized O(1) after layout
- visual movement cost is bounded by cached layout lookups, not full rewrap

## memory ownership

### thread ownership

Everything in the editor stack is TUI-thread owned:

- `PromptBuffer`
- `PromptView`
- editor-local autocomplete state
- component shell
- any render scratch used strictly on the TUI thread

Nothing in this stack may cross threads by borrowed slice.

### allocator ownership

Recommended split:

- durable editor state: TUI/state allocator
- cached layout scratch with stable reuse: editor-owned allocator or arena with `retain_capacity`
- ephemeral per-frame paint scratch: avoid where possible; if unavoidable, TUI-only scratch allocator

### no half-owned slices

Do not store borrowed slices into the mutable text buffer across mutations. Existing doctrine still applies:

- lengths/indices are okay
- direct slice storage is not okay when the underlying array can reallocate

## integration with surrounding subsystems

### Interactive / TUI root

`Interactive` should continue to treat the editor as a single `Component`, but it must not reach into editor internals to reproduce buffer/view logic.

Allowed integration points:

- `setOnSubmit`
- `setOnChange`
- status/cwd/branch setters
- autocomplete provider setter
- focus and measurement through component interface

Not allowed:

- external code rebuilding editor wrap/layout state
- external code patching cursor/scroll internals directly

### autocomplete provider seam

The provider contract can remain a TUI-facing interface, but the editor-local session/application logic should move out of the raw text/chrome code path.

Important doctrine carryover:

- slash-command data comes from TUI-owned snapshots
- no per-keystroke Lua calls
- async provider delivery must target editor-owned state only

### history

History browsing is conceptually buffer replacement plus view stabilization. It should not remain a side-effect maze inside the component shell.

## proposed folder structure

```text
src/tui/
  editor/
    root.zig
    types.zig
    buffer.zig
    view.zig
    layout.zig
    navigation.zig
    autocomplete.zig
    render.zig

  components/
    editor.zig        // thin shell, imports tui/editor/root.zig
```

### module responsibilities

- `types.zig`
  - shared editor structs/enums only
- `buffer.zig`
  - text ownership and edit operations
- `layout.zig`
  - virtual-line building, wrap caches, invalidation helpers
- `navigation.zig`
  - visual/logical movement helpers, sticky column behavior
- `view.zig`
  - viewport + cursor visibility + cache coordination
- `autocomplete.zig`
  - inline picker session state and apply logic
- `render.zig`
  - paint cached visible content into TUI regions
- `root.zig`
  - re-exports and top-level assembly

This structure is not about aesthetics. It is there to prevent the monolith from re-forming.

## UX bar

The new editor must feel better, not just be better layered.

Minimum UX outcomes:

1. wrapped multiline input remains responsive as text grows
2. up/down navigation across wrapped lines preserves visual intent
3. cursor does not thrash against viewport edges during navigation
4. resize preserves sane cursor visibility without jumpy behavior
5. autocomplete remains inline and composes cleanly with editor measurement
6. future grapheme-correct movement and undo can be added without reopening core seams

## migration plan

## phase 1 — split buffer, view, and shell

### goal

Break the monolith into real modules with hard responsibilities.

### do

- create `src/tui/editor/`
- move text ownership and edit operations into `buffer.zig`
- move wrap/viewport/cursor-visibility logic into `view.zig` + supporting modules
- keep `src/tui/components/editor.zig` as the `Component` shell only

### must be true at end

- editor component no longer owns the whole world
- text mutation can be understood without reading render code
- viewport/layout logic can be understood without reading chrome code

### forbidden

- a "legacy editor internals" struct wrapped by the new modules
- forwarding every old method through a compatibility layer that preserves the monolith internally

## phase 2 — replace scratch wrapping with cached virtual lines

### goal

Remove repeated wrapped-line scratch construction from the hot path.

### do

- create a reusable virtual-line cache keyed by buffer version + width + relevant mode bits
- introduce explicit invalidation rules
- update render, measure, cursorState, ensureCursorVisible, and visual navigation to share cached layout

### must be true at end

- `buildWrappedLinesScratch`-style architecture no longer exists in the hot path
- there is one layout authority for wrapped lines
- stable-width repeated frames do not rebuild wrap state

### forbidden

- leaving one caller on the old scratch path “temporarily”
- duplicate caches in multiple editor submodules

## phase 3 — make visual cursor semantics first-class

### goal

Adopt real wrapped-editor navigation semantics.

### do

- define logical and visual cursor types explicitly
- add logical↔visual mapping on the view layer
- add desired visual column behavior for up/down motion
- make viewport-relative cursor reporting come from the view

### must be true at end

- wrapped navigation behavior no longer depends on ad hoc calculations in component code
- sticky visual column is encoded in the view/navigation seam

### forbidden

- hiding desired-column logic in key handling
- recomputing visual cursor position independently in multiple places

## phase 4 — add scroll margin and deterministic viewport policy

### goal

Make navigation and resize behavior feel deliberate and stable.

### do

- move all ensure-visible logic into the view layer
- add documented scroll margin policy
- clamp viewport deterministically on resize and content shrink/grow

### must be true at end

- cursor visibility policy lives in exactly one place
- editor does not feel edge-glued during multiline navigation

### forbidden

- shell-level scroll hacks after movement
- special cases in render to compensate for bad viewport math

## phase 5 — harden autocomplete as a peer subsystem, not an editor sidecar

### goal

Make inline autocomplete compose cleanly with the new editor seams.

### do

- move inline autocomplete session state into `src/tui/editor/autocomplete.zig`
- preserve the inline-not-overlay behavior
- keep replacement application expressed as indices/ranges against the buffer
- ensure measurement and cursor reporting integrate through the view/shell boundary cleanly

### must be true at end

- autocomplete does not poke raw mutable buffer slices across events
- editor measurement composes text viewport + picker height deterministically

### forbidden

- storing borrowed slices into mutable editor storage across mutations
- provider-specific hacks baked into core buffer/view logic

## breaking changes policy

This refactor is allowed to break internal upstream callers.

Rule:

- if a caller relied on the old monolithic editor API shape, update the caller
- do not preserve the old surface via adapters unless it is the final intended architecture

Examples of acceptable breakage:

- helper methods removed from `components/editor.zig`
- internal tests updated to new module seams
- `Interactive` updated to call new buffer/view-backed methods indirectly through the shell

Examples of unacceptable breakage handling:

- `legacy_buildWrappedLinesScratch()` kept around for old call sites
- a hidden compatibility struct carrying old and new editor states simultaneously
- duplicate cursor/scroll state in both old and new layers

## testing doctrine for this refactor

No test spray. Focus on boundary and behavior tests.

Recommended max 5 tests for the implementation task:

1. `test "editor reuses cached virtual lines across repeated render and cursor queries"`
2. `test "wrapped visual up/down preserves desired visual column"`
3. `test "ensureCursorVisible keeps cursor inside scroll margins after multiline edits"`
4. `test "resize reflows once and preserves sane viewport anchor"`
5. `test "inline autocomplete applies replacement without borrowing mutable buffer slices"`

If more are needed, the task is too big or the tests are too implementation-shaped.

## implementation notes

### keep render thin

`render.zig` should not become a second editor brain. It paints cached visible state.

### keep shell thin

`components/editor.zig` should mostly be:

- routing input to buffer/view/autocomplete
- painting chrome and delegating content draw
- exposing `Component` hooks

### do not overfit to current prompt-only scope

The new architecture should remain prompt-editor-focused, but the seams should be good enough that future features are additive rather than architectural rewrites.

## acceptance criteria

The refactor is complete when all of the following are true:

- editor code is physically split into buffer/view/chrome-oriented modules
- wrapped-line layout is cached and reused, not scratch-built across hot-path calls
- visual cursor semantics are explicit and shared by render/navigation/cursor reporting
- scroll margin and ensure-visible policy live in the view layer
- inline autocomplete composes through the new seams without borrowed mutable slices
- no backward-compat shim preserves the old monolith internally
- `zig build` passes
- the editor remains entirely TUI-thread owned and respects allocator/lifetime doctrine

## cross-refs

Current zi files:

- `src/tui/components/editor.zig`
- `src/tui/autocomplete.zig`
- `src/tui/components/select_list.zig`
- `src/tui/interactive.zig`
- `src/tui/component.zig`

Doctrine:

- `SPEC.md`
- `.zi/design-notes/threading-doctrine.md`
- `.zi/design-notes/flow-owned-transient-data.md`

OpenTUI references:

- `.references/opentui/packages/core/src/zig/edit-buffer.zig`
- `.references/opentui/packages/core/src/zig/text-buffer-view.zig`
- `.references/opentui/packages/core/src/zig/editor-view.zig`
- `.references/opentui/packages/core/src/zig/buffer.zig`

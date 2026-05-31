# adr 0003: define the tui world as transcript, composer, slots, and surfaces

status: accepted

date: 2026-05-30

## context

zi's tui is an agent workspace, not a generic terminal component library. the terminal substrate is libvaxis, and the semantic ui runtime is zi-owned.

the target ux has:

- a main shell with a header, transcript area, status area, and composer/editor at the bottom.
- transcript items for user messages, assistant messages, tool calls, system/status entries, and custom extension entries.
- custom transcript items that can be ephemeral for the current session or persistent in session jsonl, similar in behavior to pi-mono's `appendEntry`.
- a composer/editor with file autocomplete, command dispatch, future attachment/input affordances, and header/footer chip slots.
- a status area between transcript and composer for stream failures, retry, compaction, model/context notices, and extension state.
- future extension support that can deeply augment the ui without mutating renderer internals directly.
- popovers, modals, autocomplete menus, command palettes, confirmations, notifications, and other z-indexed surfaces.

the design must avoid encoding the built-in shell as the architecture. the built-in shell should be one composition over generic tui primitives.

## decision

zi will model the tui world with these domain concepts:

```text
TuiRuntime
  TranscriptStore
  BufferStore
  ViewStore
  SurfaceTree
  SlotRegistry
  ActionRegistry
  KeymapRegistry
  CommandDispatcher
  EventBus
  InputComposer
```

the built-in shell is a default composition:

```text
RootSurface
  HeaderSlot
  TranscriptView
  StatusSlot
  ComposerSurface
    ComposerHeaderSlot
    EditorView
    ComposerFooterSlot
```

this shell is not hardcoded as the only possible layout. it is a zi-provided arrangement of buffers, views, surfaces, and slots.

## substrate versus domain

libvaxis owns terminal mechanism:

```text
raw terminal setup/restore
alternate screen
key/mouse/focus/resize input
terminal capabilities
screen/cell model
styles/colors
unicode width helpers
window clipping and child windows
terminal rendering
```

opentui is a design reference for rich text and editing:

```text
content epochs
dirty views
segmented/rope-backed text storage
edit buffer over text storage
grapheme and width tests
style spans, highlights, links
borrowed backing memory for large text
```

zi owns product semantics:

```text
transcript
transcript item kinds
persistent versus ephemeral custom items
session jsonl persistence rules
agent event mapping
tool call lifecycle presentation
composer semantics
@file autocomplete
slash/command dispatch
model/context/status chips
extension capabilities
slots
actions
keymaps
surface placement and modality
```

## transcript

transcript is domain data first and rendering second.

```zig
pub const TranscriptItem = struct {
    id: TranscriptItemId,
    kind: Kind,
    durability: Durability,
    revision: u64,
    created_ns: i128,
    payload: Payload,

    pub const Kind = enum {
        system,
        user_message,
        assistant_message,
        tool_call,
        custom,
    };

    pub const Durability = enum {
        ephemeral,
        persistent,
    };
};
```

a custom item is not a rendered line array. it is a typed transcript item with payload, durability, and an optional renderer. persistent custom items go through the same session-owner persistence path as other durable session facts. ephemeral items live only in the current process/session view.

extensions will eventually request custom transcript items through commands:

```text
append_transcript_item(ephemeral)
append_persistent_transcript_item
```

the owner path decides whether an item is live-only or also written to session jsonl.

## renderers

transcript rendering is a registry boundary:

```text
TranscriptItem -> TranscriptRenderer -> virtualized TranscriptView output
```

built-ins provide renderers for user, assistant, tool call, system, and known internal items. extensions may register renderers for custom item kinds later.

renderers produce structured view content, not raw terminal mutation. terminal-cell ownership remains in the compositor/substrate layer.

adr 0004 tightens this boundary: transcript render work must be `O(viewport)`, while durable history lives in session jsonl and the in-memory transcript window stays bounded. `Buffer.chat` is a projection/cache, not durable transcript truth.

## composer

the composer is its own subsystem, not a text field hardcoded at the bottom of the screen.

```text
InputComposer
  input_buffer
  cursor/selection
  autocomplete_state
  command_mode
  file_reference_state
  header slots
  footer slots
```

the composer supports:

```text
prompt editing
@file autocomplete
slash/command dispatch
future attachments
mode/status chips
extension-provided composer slot content
```

completion is modeled as sources and actions:

```text
CompletionSource
  trigger
  query
  results
  apply_result

ComposerAction
  insert_text
  delete_range
  accept_completion
  invoke_command
  submit_prompt
```

the future `InputBuffer` should be an editable layer over text storage, separate from chat/history buffers.

## slots

slots are named composition points. they allow built-ins and future extensions to contribute ui without owning layout or terminal cells.

initial slot ids:

```zig
pub const SlotId = enum {
    shell_header,
    transcript_status,
    composer_header,
    composer_footer,
};
```

slot contributions are bounded and owned:

```text
SlotContribution
  id
  owner
  priority
  lifetime
  render model
```

examples:

```text
current model chip
context count chip
active tools chip
stream failure notice
retry warning
extension status
todo/progress widget
auth warning
```

slot mutation goes through `TuiCommand`. there is no callback subscription path that mutates layout directly.

## buffers, views, and surfaces

the core split is:

```text
Buffer != View != Surface
```

```text
Buffer
  content
  kind
  revision

View
  buffer_id
  scroll/cursor/selection
  presentation state
  revision_seen

Surface
  view_id
  rect
  z_index
  layer
  modality
  focus_policy
  dismiss_policy
```

a popover, modal, autocomplete menu, or command palette is not a special buffer type. it is a surface placement/modality policy over a view of a buffer.

## surface tree

zi will have a z-indexed `SurfaceTree` or `SurfaceStack` rather than a flat hardcoded layout.

surface layers:

```zig
pub const SurfaceLayer = enum(u8) {
    base = 0,
    panel = 10,
    popover = 20,
    modal = 30,
    tooltip = 40,
    notification = 50,
};
```

surface modality:

```zig
pub const Modality = enum {
    modeless,
    focus_trap,
    blocks_below,
};
```

dismiss policy:

```zig
pub const DismissPolicy = union(enum) {
    none,
    escape,
    outside_click,
    escape_or_outside_click,
    action: ActionId,
};
```

example z-order:

```text
z=0   transcript
z=10  status strip
z=20  composer
z=40  autocomplete popover
z=50  command palette
z=60  confirm modal
z=70  notifications/toasts
```

surface invariants:

```text
z-order is deterministic.
at most one active modal stack top receives trapped input.
every surface references an existing view.
every view references an existing buffer.
closing a buffer closes dependent views/surfaces or is rejected.
surface count is bounded.
popover lifetime has an explicit owner and dismiss policy.
modal open/close emits typed events.
```

## extension boundary

future lua extensions must use the same semantic contract as built-in tui code.

extension-facing operations lower to:

```text
TuiCommand
TuiEvent subscription
Action registration
Keymap registration
Renderer registration
Slot contribution
Transcript item append
Completion source registration
```

extensions request; owners mutate.

allowed examples:

```text
create/write/open buffer
append custom transcript item
register transcript renderer
register command/action
register keymap
contribute to a named slot
register completion source
open view as popover/modal
show picker/confirm/input/toast
subscribe to typed tui events
```

rejected examples:

```text
draw raw terminal cells
mutate surfaces directly
replace the layout root directly
touch AgentSession internals
own vaxis windows
subscribe with callback reentrancy into owner mutation
```

## command and event protocol

all public mutation should eventually pass through `TuiCommand`.

```text
keyboard input
agent events
built-in ui code
future lua extensions
```

become bounded commands and owner-applied mutations.

`TuiEvent` carries observable typed facts:

```text
buffer_changed
view_focused
surface_opened
surface_closed
transcript_item_appended
composer_changed
completion_opened
completion_closed
action_invoked
slot_changed
```

this is the same shape future lua receives. the zig implementation is not a private shortcut that lua later has to retrofit around.

## consequences

accepted:

- the built-in shell is a composition, not the architecture.
- transcript items are domain data with durability, payload, and renderer boundaries.
- custom persistent transcript items belong to session-owner persistence, not renderer state.
- composer is its own subsystem with an editable input buffer and completion/action hooks.
- slots are named, bounded contribution points.
- popovers and modals are surface policies, not buffer kinds.
- surface z-order, modality, focus, and dismiss behavior are explicit.
- future lua extensions use the same commands/events/actions/slots/renderers as built-in code.

rejected:

- hardcoding header/transcript/status/composer as one-off layout branches.
- exposing terminal cells as the extension ui api.
- making custom transcript entries just rendered strings.
- letting extensions mutate session, layout, surfaces, or vaxis windows directly.
- building the command palette, autocomplete, modal, and status systems as unrelated widgets.

## next implementation slices

```text
src/tui/primitive/transcript.zig
src/tui/primitive/slot.zig
src/tui/primitive/command.zig
src/tui/primitive/event.zig
src/tui/product/composer.zig
```

after those exist, update `App` so agent events become transcript items, transcript renderers write buffers, and buffers/views/surfaces render through the bridge-owned vaxis frame renderer.

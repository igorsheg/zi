# adr 0006: reset the tui to one small owner and one render path

status: accepted

date: 2026-05-31

supersedes:

- adr 0002 for the next implementation slice. The extension capability survey
  remains reference material, but it is not the current architecture.
- adr 0003. Buffers, views, surfaces, slots, and read models are deferred until
  a second real owner or layout pressure proves them.
- adr 0005. The broad layering vocabulary was too large for the current TUI.

## context

The first TUI implementation jumped ahead of the product. It introduced generic
stores for buffers, views, surfaces, slots, events, read models, composition, and
agent adaptation before Zi had enough terminal behavior to justify those seams.

That made several failure modes possible:

- a command can mutate state and then fail while emitting a bounded event.
- transcript deltas can rebuild all history instead of only the visible tail.
- a generic layer can hide which owner is allowed to mutate state.
- future extension concepts can shape today's code before an extension exists.

TigerBeetle-style design starts from the smallest correct system:

```text
one owner
one mutation path
one render path
bounded state
obvious failure mode
```

Zi still wants a powerful TUI later, but the immediate job is a reliable coding
agent terminal frontend over libvaxis.

## decision

The next TUI architecture is deliberately small:

```text
coding_agent/tui_mode.zig
  owns AgentSessionRuntimeHost stepping and terminal frame loop
      |
      v
src/tui/App.zig
  owns all TUI product state and mutation
      |
      v
src/tui/render.zig
  paints one full frame from App state into libvaxis windows
      |
      v
src/tui/terminal.zig
  owns libvaxis lifecycle, input loop, resize, alternate screen, flush
```

The source shape is:

```text
src/tui/
  App.zig          app state, commands, agent-event application, dirty flag
  composer.zig     bounded single-line prompt editor
  transcript.zig   bounded resident transcript and active assistant item
  input.zig        vaxis key events -> App.Command
  render.zig       App snapshot -> libvaxis cells, full-frame repaint
  terminal.zig     libvaxis lifecycle wrapper
  root.zig         tiny public imports
```

Do not add folders until they make the system smaller to understand.

## owner model

`App` is the only owner of TUI product state:

```text
App
  terminal_width
  terminal_height
  mode
  run_status
  composer
  transcript
  dirty
```

All mutation goes through:

```zig
pub fn apply(self: *App, command: Command) Error!Effect
pub fn applyAgentEvent(self: *App, event: AgentEventView) Error!Effect
pub fn resize(self: *App, width: u16, height: u16) void
```

`Effect` is returned data. It is not a second mutation path.

The first slice does not have a public TUI event queue. If another owner needs
to observe TUI changes later, add a queue only after answering:

```text
who drains it?
what bounded capacity?
what happens when it is full?
can the command fail before mutation instead of after mutation?
```

## command semantics

Commands are atomic from the caller's perspective:

```text
validate capacity -> allocate owned bytes -> mutate App -> mark dirty -> return effect
```

No command may mutate `App` and then return an error for a derived event,
projection, notification, or render cache. If a command can fail, it fails before
the state transition.

The initial command set is intentionally small:

```zig
pub const Command = union(enum) {
    insert_text: []const u8,
    backspace,
    move_left,
    move_right,
    clear_composer,
    submit_composer,
    cancel_or_quit,
    scroll_up,
    scroll_down,
};
```

`submit_composer` returns an owned prompt effect. `coding_agent/tui_mode.zig`
starts the prompt run. `App` does not own sessions, tools, providers, settings,
auth, persistence, retries, or compaction.

## transcript

The transcript is domain state, not a generic text buffer:

```zig
pub const Item = struct {
    id: ItemId,
    kind: Kind,
    text: []u8,
    revision: u64,

    pub const Kind = enum {
        system,
        user,
        assistant,
        tool,
    };
};
```

The first resident transcript is bounded:

```text
items_max: explicit small constant
bytes_max: explicit small constant
item_text_max: explicit small constant
```

When the resident window is full, the policy is explicit:

```text
drop oldest resident item that is safe to drop
or fail before mutation with error.TranscriptFull
```

There is no projection buffer as source of truth. The renderer asks the
transcript for visible rows for the current viewport.

Streaming assistant text mutates one active assistant item:

```text
message_start/delta -> append to active assistant item
message_end         -> clear active assistant item
```

If a final assistant message disagrees with the accumulated item, the adapter
chooses one explicit policy: replace the active item or append a correction.
It must not silently duplicate text.

## composer

The first composer is single-line.

Rules:

- inserted bytes must be valid UTF-8.
- newlines are rejected or normalized before mutation.
- input bytes are bounded.
- cursor movement is grapheme-aware enough not to split UTF-8.
- submitting returns an owned prompt and clears the composer in one command.

Multi-line editing, autocomplete, command palette, attachments, and slots are
future features. They do not enter the first architecture as empty seams.

## rendering

The first renderer repaints the full frame.

This is intentional. libvaxis already keeps a screen model and renders terminal
diffs. Zi should not add dirty rectangles, retained views, or z-ordered surfaces
until full-frame repaint is proven too slow.

Render shape:

```text
clear root window
draw header/status from App state
draw visible transcript rows
draw composer line and cursor
flush via libvaxis
```

Rendering cannot allocate in the steady-state path except through an explicit
scratch buffer owned by the caller. Allocation may fail during layout only before
terminal cells are mutated.

Wrapping and tailing are display-row based, not newline based. Long wrapped
lines must still show the latest visible tail.

## libvaxis usage

libvaxis owns terminal mechanics:

```text
Tty
Vaxis
Loop
Winsize
Window
Key
Style
unicode width/grapheme helpers
screen diff/flush
```

Zi owns product state. Therefore:

- do not store `vaxis.Window` in retained state.
- do not let transcript/composer modules import terminal lifecycle types.
- do not expose raw terminal cells as the default extension surface.
- create child windows only inside `render.zig`.
- keep alternate-screen enter/exit paired in `terminal.zig`.
- input decoding uses libvaxis events, then immediately converts to `Command`.

## Zig 0.16 rules

Use the local Zig 0.16 toolchain as the source of truth. `zigdoc std.Io`
describes the process I/O boundary, and vendored zio is Zi's runtime substrate
for interactive waits, channels, select, and cancellation. TUI integration
follows that shape:

- pass `std.Io` and Zi's `*runtime.Runtime` explicitly at the
  process/runtime boundary.
- do not hide I/O in global state.
- drain ready terminal/session events at owner apply sites, then block on
  zio-selectable wake sources.
- use `std.mem.Allocator` explicitly for owned memory.
- use `errdefer` for partially initialized owners.
- every `deinit` releases all owned memory and then poisons `self` when practical.
- prefer fixed arrays or bounded owned buffers over unbounded lists.
- expose borrowed slices only for the lifetime of the owner call.
- owned text fields are named by domain, not by `owned_*` prefixes everywhere.

If a Zig or libvaxis API is unfamiliar, check `zigdoc` or the vendored source
before designing around memory of older Zig releases.

## tests

The first TUI is complete only when these behavior tests exist:

- app init/deinit has no leaks.
- resize accepts valid terminal sizes and clamps tiny sizes.
- composer insert/delete/move/submit is bounded and UTF-8 safe.
- composer newline policy is explicit.
- transcript append and assistant streaming update one resident item.
- transcript capacity failure leaves state unchanged.
- command failure leaves state unchanged.
- long wrapped transcript text renders the newest visible rows.
- full-frame render is deterministic in a virtual screen.
- `coding_agent/tui_mode.zig` can submit a prompt and drain public session events
  without reaching into session internals.

## future features

These are valid future Zi concepts, but they require new pressure:

- buffers and views: add when there are at least two real buffer kinds with
  shared behavior.
- surfaces: add when a second z-ordered UI element must coexist with the shell.
- slots: add when a built-in or extension contribution needs bounded placement.
- read models: add when a caller outside `App` must observe stable snapshots.
- extension commands/keymaps: add with a concrete owner, capacity, and failure
  policy.

One adapter is a hypothetical seam. Two adapters make a real seam.

## rejected alternatives

- Continue the current generic primitive stack. It preserves future options but
  hides today's owner and failure invariants.
- Keep the public TUI event queue. Without a real draining owner, it makes
  command failure non-atomic.
- Implement dirty rectangles now. Full-frame repaint is simpler and uses
  libvaxis' own screen diffing.
- Design the Lua extension surface now. Pi-mono is a behavioral reference, not a
  port target, and Zi does not yet have enough product behavior to freeze that
  interface.

# command catalog snapshot (zi-wub.19)

## status

design frozen, implementation deferred. zi has two CommandRegistry
types and the autocomplete consumer reads only the TUI-owned one
(`src/slash_commands.zig`). today its `dynamic` arm is empty — no
extension yet registers a slash command — so the TUI-thread read
in `SlashCommandProvider.requestImpl` is structurally safe. when the
first extension command lands, the rule below kicks in.

## why a snapshot

extension slash commands originate inside lua. the registry that
backs them lives on the agent thread (`ExtensionRunner.command_registry`
in `src/extensions/registries/command_registry.zig`). the autocomplete
provider runs on the TUI thread and is invoked on **every keystroke**
inside the editor. doctrine R5 + the "snapshot vs request" rule:

- snapshot the producer-side state once per mutation
- consumer reads its own copy without locks, without rpc, without
  reaching into lua

never call into lua from `requestImpl`. never grab a mutex on the
hot path. fuzzy filter runs against a frozen slice owned by the
TUI thread.

## shape

```zig
// owned by the TUI thread; lives in Interactive.
pub const CommandSnapshot = struct {
    // backing storage for all string fields below.
    arena: std.heap.ArenaAllocator,

    // entries are name-sorted (or insertion-ordered — pick one and
    // freeze it). includes BOTH builtins and extension commands so
    // the TUI has a single list to fuzzy-filter.
    entries: []const Entry,

    pub const Entry = struct {
        name:        []const u8,  // arena-owned
        description: ?[]const u8, // arena-owned
        source:      slash_commands.Source,
        // NO action field. dispatch goes through name → registry
        // lookup at execute time, not via the snapshot. snapshot is
        // display data only.
    };

    pub fn deinit(self: *CommandSnapshot) void { self.arena.deinit(); }
};
```

key invariants:

1. **arena-per-snapshot**. publishing a new snapshot deinits the
   previous arena in one shot. no per-entry frees.
2. **no function pointers**. snapshots cross threads as inert data.
   dispatch happens later via `command_registry.findCommand(name)`
   which routes through the `AgentRequest.run_slash_command` queue
   variant — the same path doctrine already names for extension
   handlers.
3. **immutable after publish**. the TUI thread's pointer to the
   active snapshot is swapped atomically; readers either see the
   old snapshot or the new one, never a half-built one.

## publish hook

agent thread side, in `ExtensionRunner`:

```zig
fn publishCommandSnapshot(self: *ExtensionRunner) void {
    // build a fresh snapshot from runner.command_registry +
    // builtins, into a new arena, then atomically swap into
    // self.published_command_snapshot.
}
```

call sites:

- after extension load (`runner.load`)
- after extension reload (the generation swap from D7 / zi-gxr)
- after `zi.register_command` if we ever add a runtime register call
- on shutdown: TUI side stops reading; agent side deinits the last
  snapshot during runner.deinit

TUI side, in `Interactive`:

- holds an `?*const CommandSnapshot` field
- `SlashCommandProvider` is rewritten to take that pointer instead
  of `*const CommandRegistry`
- on snapshot swap (delivered via a `UiEvent.command_snapshot_updated`
  carrying the new pointer + old pointer for the agent thread to
  reclaim), TUI updates its field; the dispatch loop already runs on
  the right thread

## what the doctrine forbids

- TUI thread reaching into `runner.command_registry` directly (would
  race with extension load)
- TUI thread holding the lua mutex during keystroke dispatch
- per-keystroke rebuild of the entry list (snapshot must be
  pre-built)
- function pointers in snapshot entries that close over agent-thread
  state

## migration trigger

implement when the first extension lands `zi.register_command` and
the TUI starts seeing extension entries in autocomplete. until then,
the existing `SlashCommandProvider` reads a TUI-owned registry whose
dynamic arm stays empty, and the design above is the only thing that
needs to exist.

cross-ref:
- `src/slash_commands.zig` — TUI-owned registry; `register` is the
  current placeholder for the publish path
- `src/extensions/registries/command_registry.zig` — agent-owned
  registry; the future producer
- `src/tui/autocomplete.zig` — `SlashCommandProvider.requestImpl`
  — the consumer that must NEVER touch lua
- `.zi/design-notes/threading-doctrine.md` — R5, snapshot vs request

verified-as-clean: 5538d2b. no extension registers a slash command
today, so no live cross-thread read exists.

# tui ephemeral notifications (fidget.nvim-shaped)

status: implemented (small v1)

date: 2026-06-20

## goal

Split the status area. The "Working" shimmer and the other *persistent* working
indicators (recovery, completion, queue) stay exactly where they are, in the
existing `status.Store` `status_line` slot, id-keyed, cleared explicitly.

All *ephemeral* notifications/statuses move to a new fidget.nvim-shaped model:
stacked, TTL-expiring, in-place-updatable by key, deduplicated with a count,
grouped. Behavior and internal API mirror
[j-hui/fidget.nvim](https://github.com/j-hui/fidget.nvim) `notification.model`,
adapted to Zi's bounded / allocation-free / one-owner rules.

This is a design note. Code names and shapes below are the intended contract.

## what stays vs what splits

| concern | owner | model |
|---|---|---|
| "Working" shimmer, recovery, completion, queue | `status.Store`, slot `.status_line` | id-keyed, priority-ordered, no TTL, explicit clear. **unchanged.** |
| composer border labels (`composer_left/right/bottom_*`) | `status.Store` | unchanged |
| ephemeral notices ("warning: input truncated", "cancel requested", errors, "resumed session") | **new `notify.Store`** | fidget model: group+key, TTL, dedup+count, annote, prune-on-tick |

The split is logical and physical:

- **Persistent status row:** working status renders exactly as today
  (`status.ordered(.status_line)`, priority-desc, separator-joined, shimmer/shuffle
  per entry). It reserves one row only when persistent status exists.
- **Notification overlay:** ephemeral notifications render as a bounded floating
  stack, right-aligned above the composer. The newest/highest-priority item sits
  on the bottom row, visually matching the right end of the old status row; older
  items stack upward. It does not reserve transcript layout rows.

## the model (`src/tui/notify.zig`)

Allocation-free, bounded, inline text — same discipline as `status.zig`. No
`deinit`. One owner (`App`), mutated only through `App.apply(Command)`.

### constants

```zig
pub const item_count_max: usize = 16;   // ponytail: fidget is unbounded; zi caps resident
pub const group_count_max: usize = 8;
pub const text_bytes_max: usize = 160;  // reuse status.text_bytes_max
pub const annote_bytes_max: usize = 16; // "INFO"/"WARN"/"ERROR"/short custom
pub const count_max: u16 = 9999;
pub const default_ttl_ms: i64 = 5_000;  // fidget default ttl = 5s
pub const never_expires: i64 = std.math.maxInt(i64);
```

Each bound has a named overflow policy: `reject` at `item_count_max`
(`SetResult.dropped_full`); dedup count saturates at `count_max` in the view;
`text_bytes_max`/`annote_bytes_max` truncate via the existing
`text.sanitizeInto` path.

### types

```zig
pub const Key = u32;          // item identity within a group; 0 = none (anonymous)
pub const GroupKey = u8;      // group identity; 0 = default group

pub const Level = enum { debug, info, warn, err };   // vim.log.levels subset

pub const Tone = status.Tone; // reuse: secondary/accent/canceled/warning/err

pub const Item = struct {
    group: GroupKey,
    key: Key,
    message_len: u8,
    message: [text_bytes_max]u8,
    annote_len: u8,
    annote: [annote_bytes_max]u8,
    tone: Tone,
    expires_at: i64,        // ms; never_expires for sticky
    last_updated: i64,      // ms
    hidden: bool,
    skip_dedup: bool,
};

pub const Group = struct {
    key: GroupKey,
    priority: i16 = 50,     // fidget default 50
    ttl_ms: i64 = default_ttl_ms,
    render_limit: u8 = 0,   // 0 = no limit
    // name/icon skipped in v1 render (see render); stored for identity only.
};

pub const Notify = struct {
    group: GroupKey = 0,
    key: Key = 0,           // 0 = anonymous, always creates a new item
    message: []const u8,
    level: Level = .info,
    annote: ?[]const u8 = null,
    ttl_ms: ?i64 = null,    // null = group default; 0 = group default (fidget semantics)
    hidden: bool = false,
    update_only: bool = false,
    skip_dedup: bool = false,
};

pub const Clear = union(enum) {
    item: struct { group: GroupKey = 0, key: Key },
    group: GroupKey,
    all,
};

pub const SetResult = enum { ok, dropped_full, update_only_miss };

pub const View = struct {
    message: []const u8,    // borrows store
    annote: []const u8,     // borrows store; empty if none
    tone: Tone,
    count: u16,             // >=1; >1 means deduped
    started_ms: i64,        // last_updated, used for shuffle animation
};
```

### the store

```zig
pub const Store = struct {
    items: [item_count_max]Item = undefined,
    item_len: usize = 0,
    groups: [group_count_max]Group = undefined,
    group_len: usize = 0,

    pub fn ensureGroup(self, g: Group) void;          // upsert group config
    pub fn notify(self, n: Notify, now: i64) SetResult;
    pub fn remove(self, group: GroupKey, key: Key) bool;
    pub fn clear(self, request: Clear) bool;
    pub fn tick(self, now: i64) bool;                 // prune expired; returns true if changed
    pub fn ordered(self, now: i64, out: []View) usize;// render views, deduped+counted, priority-then-recency
    pub fn hasAnimated(self, now: i64) bool;          // shuffle running on any visible item
    pub fn count(self) usize;
};
```

`notify` semantics (matches fidget `model.update`):

1. resolve group by `n.group` (default group config if absent).
2. find item by `(group, key)`. `key=0` never matches → always creates.
3. if found: update message (if non-empty), annote, tone, `last_updated=now`;
   recompute `expires_at` only if `ttl_ms` supplied.
4. if not found and `n.message` empty or `update_only`: return `update_only_miss`
   (and drop a just-created empty group, like fidget).
5. if not found: create item, `count=1`, `expires_at = now + (ttl_ms orelse
   group.ttl_ms)`, and remember whether `skip_dedup` is set.
6. Dedup happens in `ordered`: visible items in the same group with equal
   message+annote are folded into one `View.count`, matching fidget's view-time
   `dedup_items`. The cap is 16 items, so the O(n²) scan is simpler than hashes
   and has no collision behavior.

`tick` walks items, drops any with `expires_at <= now`, compacts. Returns
`changed` so `App.tick` can mark dirty only when something actually expired.

`ordered` emits visible (`!hidden`, not expired) items as `View`s, deduped (count
folded in), ordered by group priority desc then `last_updated` desc. Render puts
the first view on the bottom row and stacks later views upward, matching fidget's
bottom-aligned stack. Text is sanitized/truncated inline at insert, so views
borrow stable store bytes.

## level / annote / tone mapping

fidget derives annote + style from `vim.log.levels`. zi maps:

```zig
fn levelDefaults(level: Level) struct { annote: []const u8, tone: Tone } {
    return switch (level) {
        .debug => .{ .annote = "DEBUG", .tone = .secondary },
        .info  => .{ .annote = "INFO",  .tone = .accent },
        .warn  => .{ .annote = "WARN",  .tone = .warning },
        .err   => .{ .annote = "ERROR", .tone = .err },
    };
}
```

An explicit `n.annote` overrides the level default. The frontend's current
`"warning: {text}"` / `"error: {text}"` prefixing disappears — the annote carries
the level, the message is the bare text. Render joins `message` + separator + `annote` (fidget `annote_separator`,
default `" "`).

## animation

New/updated notifications get `effect = .shuffle` keyed off `last_updated`, reusing
the existing `shuffle_text` machinery. `shuffle_text.isRunning(now, started_ms,
.{})` drives `hasAnimated` so the frame timer animates the appear/update shimmer
and then settles (shuffle has a finite run; after it ends the text is static).
No fidget-style spinner here — the "Working" shimmer is the persistent spinner
and stays in `status.Store`.

`ponytail: shuffle-on-appear only; no fade-out at expiry. Add a fade when a second
render owner proves the need.`

## render

Render has two independent paths:

1. **Persistent status row** (unchanged): `status.ordered(.status_line)` →
   priority-desc, separator-joined, shimmer/shuffle per view, advancing `x` from
   0.
2. **Notification overlay**: `notify.ordered(now)` renders newest/highest first,
   right-aligned. The first item lands on the row immediately above the composer
   (the same visual baseline as the old right status slot); subsequent items
   stack upward one row at a time. Each view renders as `message annote`, or
   `(Nx) message annote` for deduped items, truncated by `fitToWidth`.

`statusRows` only tracks persistent `status.Store` entries. Notifications are
painted by `drawNotifyOverlay` after transcript/status drawing and before the
composer, so they float over transcript content like fidget's window without
moving the composer.

Group headers (name + icon) and group separators are **not rendered in v1**.
`ponytail: group header/separator rendering is deferred until a real caller needs
it. The model stores group_key/priority/ttl/render_limit so render can grow
without an API change.`

## App integration

`App` gains one field and two command variants:

```zig
notify: notify.Store = .{},

// Command
notify: notify.Notify,        // -> self.notify.notify(update, now); dirty
clear_notify: notify.Clear,   // -> self.notify.clear/group-clear
// tick already exists; extend its handler:
//   self.now_ms = tick.now_ms;
//   const expired = self.notify.tick(self.now_ms);
//   if (expired or self.statusHasAnimated() or self.notify.hasAnimated(now)) self.dirty = true;
```

`statusHasAnimated` (or a renamed `productHasAnimated`) also checks
`self.notify.hasAnimated(now)`. The existing `status.set_status`/`clear_status`
commands are unchanged and remain the path for persistent working status.

`apply` stays total over operational input: oversized/invalid-UTF-8 notify
payloads are sanitized/truncated into the inline buffers before mutation, and
`dropped_full` degrades to a notice (or no-op) — never a fatal error out of the
owner loop, matching the AGENTS.md streamed-text rule.

## frontend migration (`src/frontends/tui/interactive.zig`)

The ephemeral helpers stop touching `status_line` and use `notify`:

- `appendStatus(level, text)` / `appendStatusWithTone(level, text, tone)` →
  `applyCommand(.{ .notify = .{ .message = text, .level = mappedLevel(level),
  .tone = tone, .ttl_ms = default_ttl_ms } })`. Drop the `"warning: "/"error: "`
  prefixing — annote carries the level.
- Persistent helpers stay on `set_status`: `setWorkingStatus`, `setRecoveryStatus`,
  `setCompletionStatus`, queue status. Their `clearStatus(id)` calls stay.
- `status_id_notice` (id=5) is removed from the `status_line` set; notices no
  longer occupy a fixed id. A notice with no `key` creates a fresh item each
  call, so they stack and TTL-expire rather than overwriting. A notice that
  should replace-in-place (e.g. a repeating "cancel requested") passes a fixed
  `key`.

The `status_id_*` constants for working/recovery/completion/queue remain.

## what is deliberately NOT built (ponytail)

- **history ring buffer** (fidget `removed`/`make_history`/`clear_history`):
  skipped. The model is bounded and TTL-pruned; history is a separate owner.
  Add when a history viewer (e.g. a command/notice log) is requested.
- **group header/icon/separator rendering**: skipped in v1 (see render).
  `group` exists in the model for identity, dedup scoping, and `clear(group)`.
- **reserved layout for notifications**: notifications float over transcript
  rows instead of moving composer/status layout.
- **spinner patterns**: the "Working" shimmer already covers spinner semantics
  and lives in `status.Store`. notify only shuffles-on-appear.
- **redirect/suppress window toggles, poll_rate config, override_vim_notify**:
  neovim-specific; zi's frame timer is already the poller.
- **per-group `name`/`icon` callable Display**: zi has no dynamic group naming
  need yet.

## bounds and failure modes (from AGENTS.md "before adding a boundary")

- *what can go wrong?* flood of notices; oversized/invalid-UTF-8 streamed text;
  hash collision; clock going backwards.
- *maximum bound?* `item_count_max` items, `group_count_max` groups, inline
  `text_bytes_max`/`annote_bytes_max`; `count_max` saturates. All resident, no
  allocation, no unbounded growth.
- *who owns each resource?* `App` owns `notify.Store`. Frontend reaches it only
  via `Command`. Views borrow the store for the duration of the render call.
- *where is mutation allowed?* `App.apply` drain site only.
- *which errors handled?* `dropped_full` and `update_only_miss` are operational →
  degrade (drop or no-op). Programmer error (assert): `key != 0` invariant is
  not asserted (0 is legal = anonymous); group config upsert is total.
- *invariants?* views report `count >= 1`; visible duplicate messages are folded
  at view time; `expires_at` changes only when re-notified with a TTL.
- *slowest resource?* none — pure in-memory, O(items) per tick/render.
- *future maintainer must not remember?* the inline-buffer + sanitize-at-insert
  discipline (enforced by reusing `text.sanitizeInto`), and that `tick` must run
  every frame for expiry (enforced by the `App.tick` handler calling it).

## tests (behavior, not helpers)

- `notify` creates an item; `tick` before ttl keeps it, after ttl drops it.
- same `(group, key)` `notify` twice updates in place (count stays 1, message
  replaces).
- two anonymous notifies with same message text+annote dedup to one item with
  `count=2`; render view reports `count=2`.
- `clear(group)` removes only that group's items; `clear(0)`-as-all clears
  everything (the `clear` with `key=0` clears a group; an explicit "clear all"
  path is a separate method or sentinel — TBD: pick one, avoid overload by
  `group` value).
- `ordered` is priority-desc then recency-desc.
- oversized/invalid-UTF-8 message is sanitized+truncated, never fatal.
- `dropped_full` after `item_count_max` inserts.
- `hasAnimated` true only while shuffle is running post-update.

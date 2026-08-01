# Notifications

Zi's interactive client provides a Fidget-style notification surface through each `InteractiveMode` instance.

```ts
const mode = new InteractiveMode({ renderer, session, onExit })

mode.notify("Indexing workspace", 2, { key: "index", ttl: Infinity })
mode.notify("Indexed 24 files", 2, { key: "index", annote: "DONE", ttl: 3 })
```

`mode.notify(message, level?, options?)` is an alias for `mode.notifications.notify(...)`. A `null` message updates an existing keyed notification without replacing its text:

```ts
mode.notify(null, 3, { key: "index", annote: "RETRYING", ttl: 5 })
```

## Placement and presentation

The surface follows Fidget's default geometry and rhythm:

- bottom-right of the transcript region, above Zi's composer;
- one column of edge padding;
- new chunks stack upward;
- the group header remains at the bottom;
- no border, focus, selection, fade, or slide animation;
- duplicate message/annotation pairs collapse to `(Nx) message`;
- numeric levels use Neovim's conventional values: `1` debug, `2` info, `3` warn, and `4` error.

The default group renders as `Notifications ❰❰`. Named groups render their key as the title. The surface is one retained OpenTUI text node and only receives a new content value when its visible presentation changes.

## Notification options

The call shape preserves Fidget's option names:

| Option         | Meaning                                                                    |
| -------------- | -------------------------------------------------------------------------- |
| `key`          | Update the item with this key within its group.                            |
| `group`        | Select a notification group; defaults to `"default"`.                      |
| `annote`       | Single-line annotation. `null` clears it on update.                        |
| `hidden`       | Retain the item without rendering it.                                      |
| `ttl`          | Lifetime in seconds. `0` uses the group default; `Infinity` is persistent. |
| `update_only`  | Refuse to create a missing keyed item.                                     |
| `skip_history` | Do not retain the item after removal.                                      |
| `data`         | Bounded immutable JSON attached to the item.                               |

Updates preserve the existing message and expiry unless the corresponding field is supplied. Unlike Fidget's accidental truthiness behavior, explicit `false` can unhide an item or re-enable history.

Numeric notifications below the default info filter are ignored. Configure the filter and bounds when constructing the client:

```ts
new InteractiveMode({
  renderer,
  session,
  onExit,
  notificationOptions: { filter: 1, history_size: 128, max_active: 128, max_visible: 32, max_visible_lines: 64 }
})
```

## Lifecycle API

`mode.notifications` owns the Fidget-equivalent lifecycle operations:

- `notify(message, level?, options?)`
- `close()`
- `clear(groupKey?)`
- `remove(groupKey, itemKey)`
- `suppress(value?)`
- `reset()`
- `set_config(groupKey, config, overwrite?)`
- `group_keys()`
- `get_history(filterOrGroup?)`
- `clear_history(filterOrGroup?)`

`reset()` clears caller-owned active items and history but preserves suppression and internally claimed groups.

History filters support `group_key`, `before`, `since`, `include_removed`, and `include_active`. `last_updated` is Unix time in seconds; `before` and `since` are item ages in seconds. Public `clear()` and `reset()` affect caller-owned groups only; targeting an internally claimed group through a mutating API is rejected. `max_active` bounds caller-owned items. Internal group claims carry explicit capacities whose sum cannot exceed 128, so caller and producer partitions together retain at most 256 active items. Removed history remains separately bounded. Attached JSON is also bounded during traversal to 32 levels and 4,096 values before its 16 KiB serialized limit is checked. A `history_size` of `0` disables removed history rather than creating an unbounded collection.

`close()` records an owner-held surface transition: history queries, expiry frames, resizing, and screen replacement cannot reopen it. The next successful active-notification mutation may reopen it. `suppress()` remains the durable policy switch.

Fidget's Neovim-specific `show_history()` echo integration is intentionally not copied. Clients consume `get_history()` and choose their own history screen.

## System notices

`SystemNotificationPresenter` exclusively claims the bounded `zi.system` group, displayed as `System ❰❰`. It receives narrow typed operations rather than exposing the unrestricted public notification API to prompt components. The group currently owns:

- persistent bootstrap, extension, and project-trust diagnostics;
- persistent automatic-compaction failures, removed after the next successful compaction;
- finite selection-copy failures, removed immediately after a successful copy;
- finite background-shell capacity refusals;
- keyed `/reload` success, warning, and failure outcomes.

Session replacement clears every system key before the new session's authoritative diagnostics are projected. `Reloading…` remains foreground prompt status; only its settled outcome becomes a notice. Authentication ceremonies, picker errors, draft validation, and other focused workflows remain prompt feedback. System notices never submit input, wake the model, or copy transcript content.

## Ownership

`InteractiveMode` creates and disposes one notification owner plus its system presenter. It temporarily detaches the surface while replacing a session screen, preserving active notifications and history without allowing the destroyed screen to dispose a resource it did not create. Internal producers claim one group through a private center capability and release that claim on disposal; unscoped public lifecycle operations affect only unclaimed groups. Finite TTLs hold one renderer live request and expire from renderer frames; the owner releases that request when no finite items remain or on disposal.

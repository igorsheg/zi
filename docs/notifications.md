---
slug: notifications
title: Terminal notifications
order: 120
---

# Terminal notifications

You are embedding or extending Zi's reference terminal client and you need to surface transient status: a workspace index running, background progress, a failure the user should see. You want it without inventing a second status system, stealing focus from the composer, or leaking status text into the transcript.

Each `InteractiveMode` instance provides a Fidget-style notification surface for exactly that.

```ts
const mode = new InteractiveMode({ renderer, session, onExit })

mode.notify("Indexing workspace", 2, { key: "index", ttl: Infinity })
mode.notify("Indexed 24 files", 2, { key: "index", annote: "DONE", ttl: 3 })
```

This is the terminal client's own API, reachable from the code that constructs or composes `InteractiveMode`. A prompt, a skill, or an extension cannot reach it.

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

The default numeric filter admits info and above. Configure the filter and bounds when constructing the client:

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

History filters support `group_key`, `before`, `since`, `include_removed`, and `include_active`. `last_updated` is Unix time in seconds; `before` and `since` are item ages in seconds.

Public `clear()` and `reset()` affect caller-owned groups only. A client cannot clear an internal producer's diagnostics by clearing its own, because the two live in separately claimed groups.

`max_active` bounds caller-owned items. Internal group claims carry explicit capacities whose sum cannot exceed 128, so caller and producer partitions together retain at most 256 active items. Removed history remains separately bounded, and a `history_size` of `0` disables removed history rather than creating an unbounded collection.

Attached JSON is bounded during traversal to 32 levels and 4,096 values before its 16 KiB serialized limit is checked, so a deeply nested or wide object is refused without first paying for a full serialization.

`close()` records an owner-held surface transition. The next successful active-notification mutation may reopen it. `suppress()` remains the durable policy switch.

Fidget's Neovim-specific `show_history()` echo integration is intentionally not copied. Clients consume `get_history()` and choose their own history screen.

## Built-in notices

`BuiltInNotificationPresenter` exclusively claims the bounded, headerless `zi.system` group. It receives narrow typed operations rather than exposing the unrestricted public notification API to prompt components. The group currently owns:

- persistent bootstrap, extension, and project-trust diagnostics;
- persistent automatic-compaction failures, removed after the next successful compaction;
- finite selection-copy failures, removed immediately after a successful copy;
- finite background-shell capacity refusals;
- keyed `/reload` success, warning, and failure outcomes;
- one stable `prompt` key for one-line prompt-workflow progress and outcomes.

Prompt progress and errors persist until an admitted transition replaces or removes them. Prompt information and warnings are finite. In-flight progress skips removed history; settled information, warnings, and errors remain history-eligible. `/reload` replaces `Reloading…` on the `prompt` key with its separately keyed settled outcome. Session replacement clears every built-in key before the new session's authoritative diagnostics are projected.

The composed transcript status row remains above the composer. It owns the animated `Working…`, retry/compaction/cancellation lifecycle text, detached-transcript `New output` attention, background command/agent counts, and work-plan progress. Authentication ceremonies, picker guidance and errors, inline tool state, queued inputs, and composer metadata remain with their contextual owners. Built-in notices never submit input, wake the model, or copy transcript content.

## Ownership

Every retained resource on this surface has one [owner](vocabulary.md), and that owner releases it.

`InteractiveMode` creates and disposes one `NotificationCenter` plus its built-in presenter. It temporarily detaches the surface while replacing a session screen, preserving active notifications and history without allowing the destroyed screen to dispose a resource it did not create.

Internal producers claim one group through a private center capability and release that claim on disposal; unscoped public lifecycle operations affect only unclaimed groups.

Finite TTLs hold one renderer live request and expire from renderer frames. After expiry removes the last finite item, the owner requests the final cleared paint and releases that live request. Disposal releases it immediately.

## What this does not do

- The surface takes no border, focus, or selection, and has no fade or slide animation.
- Notifications below the active filter level are ignored.
- Mutating an internally claimed group through a public API is rejected.
- History queries, expiry frames, resizing, and screen replacement cannot reopen a closed surface.
- The composed transcript status row is not a notification item.

There is no extension-facing `zi.notify(...)` API. Adding one requires a separate client-independent event contract; extensions do not receive `NotificationCenter` or the presenter's private producer capability. See [Extensions](extensions.md) for the capabilities an extension does receive.

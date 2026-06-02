# adr 0011: keep libvaxis terminal IO behind a zio-selectable bridge

status: superseded by adr 0013

date: 2026-06-01

## supersession note

ADR 0013 replaces this ADR. Zi no longer uses libvaxis. The surviving runtime
principle is still owner-drained terminal input through explicit bounded
runtime completions, without callbacks, hidden task spawning, unbounded queues,
or sleep polling.

## context

Zi has chosen libvaxis as its terminal infrastructure and zio as its runtime.
Before reconnecting `coding_agent.tui_mode`, the TUI loop must prove that
terminal input, agent progress, frame ticks, cancellation, and shutdown can be
coordinated without sleep polling or hidden callback mutation.

libvaxis is already `std.Io`-aware:

- `vaxis.Tty.init` opens `/dev/tty` with `std.Io`.
- libvaxis tty reads use streaming reads.
- libvaxis tty writers use streaming writers.
- `vaxis.Loop` starts its tty reader with `std.Io.concurrent`.
- `vaxis.Loop` uses a fixed-size internal queue of 512 events.

That makes libvaxis compatible with Zi's zio-native process boundary. The
pressure point is ownership: libvaxis owns terminal parsing and terminal feature
handling, but Zi must own event selection, app mutation, effects, rendering
phase, and shutdown.

## decision

Zi keeps libvaxis terminal IO behind a zio-selectable bridge:

```text
libvaxis tty reader
  -> libvaxis fixed queue
  -> Zi TerminalEvents bridge
  -> zio Channel
  -> owner select/drain
  -> ProductApp.apply()
  -> build frame
  -> libvaxis render/flush
```

The bridge owns `vaxis.Loop.start()` and `vaxis.Loop.stop()` for the loop it
bridges. Callers do not separately start the libvaxis loop.

The bridge exposes `asyncNext()` so the eventual TUI owner can select terminal
events alongside agent/session progress and cancellation:

```text
select {
  terminal_event,
  agent_event,
  cancel,
  frame_tick,
}
```

Coding-agent to TUI communication does not get a second private channel at this
boundary. The session host already exposes public events and owned snapshots.
The TUI owner drains those public events, mirrors them into read models, and
adapts transcript-relevant events into product commands. If the real loop needs
an async wake for that drain, Zi should add a zio-selectable event pipe at the
host boundary, not let callbacks mutate TUI state.

## invariants

- libvaxis owns raw terminal lifecycle, input parsing, terminal capability
  detection, resize parsing, and cell rendering.
- Zi owns command application, effects, frame construction, and public event
  draining.
- terminal events enter Zi through a bounded queue.
- terminal input is never polled with sleeps.
- product state is mutated only by the TUI owner drain/apply path.
- coding-agent events mutate TUI state only after the TUI owner drains public
  session events and applies explicit product commands.
- rendering consumes product state and does not mutate it.
- resize is translated to a product command.
- shutdown is explicit: request shutdown, stop libvaxis loop, close Zi event
  bridge, cancel bridge task, restore terminal, deinit product state.

## current shape

`src/tui/substrate/terminal.zig` owns:

```text
vaxis.Tty
vaxis.Vaxis
alternate screen lifecycle
resize call-through
event loop construction
```

`src/tui/substrate/event_pump.zig` owns:

```text
vaxis.Loop.start()
vaxis.Loop.stop()
fixed Zi channel capacity: 512 events
zio-selectable async terminal receive
bridge task cancellation on deinit
```

`src/coding_agent/tui_owner.zig` owns the current TUI loop:

```text
terminal event + active prompt progress -> zio.select
terminal event without active prompt     -> zio.select
host public-event wake                   -> zio.ResetEvent
selected event                           -> owner apply site
public session events                    -> owner drain after wake
dirty product state                      -> frame projection -> libvaxis render
```

The loop has at most one active prompt run. Starting a second prompt while one
is active is an error. Cancellation cancels the active prompt; cancellation with
no active prompt requests shutdown.

Public session events remain in the bounded session queue. The host wake is only
a coalesced signal that tells the owner to drain the queue; it does not carry
event authority. The wake uses `zio.ResetEvent` instead of an event pipe because
enqueueing a public session event must never block when the wake is already set.

This is intentionally a bridge, not a new terminal framework. It exists because
Zi needs terminal events to participate in zio `select` with agent/session
events.

## known pressure points

- There are currently two bounded queues in the terminal path: libvaxis's
  internal queue and Zi's bridge channel. This is acceptable for the first real
  loop because both are fixed at 512 events, but the owner drain must prevent
  long-term accumulation.
- The bridge forwards one event at a time. If key-repeat or mouse motion becomes
  hot, the owner should coalesce at the command boundary, not make the queues
  unbounded.
- `vaxis.Loop.stop()` wakes the tty reader through a terminal query. The bridge
  still cancels its forwarding task during deinit, so shutdown does not rely on
  input arriving naturally.
- Zi should not use libvaxis `vxfw.App` as the application loop. It contains its
  own frame timing and event command model, which would compete with Zi's
  command/effect/runtime owner.

## rejected alternatives

- make zio read the tty fd directly and bypass libvaxis parsing. This duplicates
  libvaxis terminal logic and loses capability handling.
- use libvaxis `vxfw.App` as Zi's app loop. That would put app mutation and
  frame policy outside Zi's owner model.
- sleep-poll libvaxis `tryEvent`. Sleep polling violates Zi's runtime
  discipline and wastes latency budget.
- let agent/session callbacks mutate TUI state directly. Terminal and agent
  events must meet at the owner drain.

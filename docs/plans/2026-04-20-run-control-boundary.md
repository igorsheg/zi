# Run-control boundary refactor

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make queued steering/follow-up a first-class cross-thread run-control surface instead of routing it through the blocking agent request inbox. This also fixes the steering regression (submitting during streaming only appears after idle) as a natural consequence.

**Architecture:**
Today, `AgentRequest.enqueue_queued_input` is an inbox message that the agent thread can only dispatch *between* `runUserContent` calls. During streaming, the agent thread is blocked inside `runUserContent`, so the TUI's steering submit sits in the inbox until the run ends. Additionally, queue state is mirrored inside `AgentSession.steering_mirror`/`follow_up_mirror` (mutex-protected) and re-published through `SessionEvent.queue_update`, which triggers a full `PublishedConversationState` publish. That couples a tiny queue mutation to the in-flight streaming view.

The right shape, already documented in `docs/runtime.md:23-42` and `docs/architecture.md:36-46`:

- `run_control` on `Agent` is **the** authoritative queued-message boundary (enqueue + snapshot/clear). It is already implemented on top of a thread-safe `Mailbox`.
- The TUI calls run-control directly from the TUI thread — no inbox hop. (`run_control.enqueue` is safe under the mailbox mutex, same guarantee as `abort`.)
- Published cross-thread snapshots split into two independent payloads: `ConversationViewSnapshot` (committed + in_flight, published on agent-event boundaries) and a **versioned** `QueuedMessageSnapshot` (published on queued-message boundaries). The TUI merges them at projection time and ignores stale queued snapshots by version.
- Queued snapshots must be published for every UI-visible run-control mutation: enqueue, drain, clear/restore, and session replacement/reset. Drain publication cannot rely on the deleted `queue_update` session event.
- `AgentSession.steering_mirror`/`follow_up_mirror`, `queue_mutex`, `queueMutationCallback`, `QueueObserver`, `setQueueObserver`, `notifyQueueMutation`, `notifyPendingQueueCleared`, and `SessionEvent.queue_update` all go away. They are duplication of state that already lives in `run_control`.

**Tech stack:** Zig 0.15+, the project's custom `Mailbox` primitive (`src/runtime/mailbox.zig`), the existing `agent3/control.zig` `RunControl` type, and the TUI's existing `ProjectionState` / `conversation_projection.zig` pipeline.

---

## Scope, at a glance

**Delete:**
- `AgentRequest.enqueue_queued_input` and `AgentRequest.restore_queued_inputs` (`src/coding_agent/request.zig`)
- Their dispatch arms in `Interactive.processAgentRequests` and the handlers `handleEnqueueQueuedInput` / `handleRestoreQueuedInputs` (`src/tui/interactive.zig`)
- `queueMutationCallback` + `applyQueueMutation` + `clearQueueMirror` + `cloneQueuedEntries` + `freeQueuedEntries` (`src/coding_agent/agent_session.zig`)
- `AgentSession.steering_mirror`, `AgentSession.follow_up_mirror`, `AgentSession.queue_mutex` (same file)
- `SessionEvent.queue_update` variant + all its consumers (`src/coding_agent/session_event.zig`, `src/tui/interactive.zig:2791-2793`)
- `Agent.queue_observer`, `QueueObserver`, `QueueMutationAction`, `setQueueObserver`, `notifyQueueMutation`, `notifyPendingQueueCleared` (`src/agent3/agent.zig`)
- The `agent.setQueueObserver(...)` call in `AgentSession.wireSubscription` (`src/coding_agent/agent_session.zig`)

**Change:**
- Split `PublishedConversationState` into `ConversationViewSnapshot` (view only) and use a **versioned** `QueuedMessageSnapshot` as the second independent payload (`src/agent3/conversation_state.zig`, `src/agent3/control.zig`)
- `RuntimeHost.publishConversationState` now publishes `ConversationViewSnapshot` only. Add `RuntimeHost.publishQueuedSnapshot` that publishes a `QueuedMessageSnapshot` independently, via a second publisher fn (`src/coding_agent/runtime_host.zig`)
- `AgentSession.cloneQueuedMessageSnapshot` reads directly from `agent.run_control.snapshot(allocator)` instead of the mirror
- `AgentSession.restoreQueuedMessagesOnAgentThread` uses an **atomic** `agent.run_control.clearAndSnapshot(...)` path via an `Agent` helper (see Tasks 3 and 3a)
- `UiEvent.conversation_state` carries `ConversationViewSnapshot`; add a new `UiEvent.queued_snapshot` carrying `QueuedMessageSnapshot` (`src/tui/ui_event.zig`)
- `ProjectionState` stores the last `ConversationViewSnapshot` and the last `QueuedMessageSnapshot` separately, merges them when building desired items, and drops stale queued snapshots by version (`src/tui/conversation_projection.zig`)
- `queueMessageWhileStreaming`, `restoreQueuedInputsToEditor` call run-control directly on the TUI thread, not via `request_queue` (`src/tui/interactive.zig`)

**Add:**
- `Agent.snapshotQueuedMessages(allocator)`, `Agent.takeQueuedMessagesAndClear(allocator)`, and `Agent.currentQueuedVersion()` — thin wrappers over `run_control` (`src/agent3/agent.zig`)
- An atomic queued-message snapshot+clear path inside `RunControl` / `MessageQueue` (likely in `src/agent3/control.zig`, with mailbox support if needed)
- `RuntimeHost.enqueueQueuedText(kind, text)` → calls `session.agent.steer(...)` or `.followUp(...)` with an owned `AgentMessage` (`src/coding_agent/runtime_host.zig`)
- `RuntimeHost.snapshotQueuedMessages(allocator)`, `RuntimeHost.takeQueuedMessagesAndClear(allocator)`, and `RuntimeHost.currentQueuedVersion()` (same file)
- `Interactive.publishQueuedSnapshot` plus `publishQueuedSnapshotIfChanged` on the TUI side so queued rows update immediately on TUI-thread enqueue/restore and also disappear when the agent drains the queue (`src/tui/interactive.zig`)

---

## Ordering & commit cadence

The delete/add edits touch four compilation units (`agent3`, `coding_agent`, `tui`, tests). To keep every checkpoint green, introduce the new surface **before** deleting the old, then rewire callers, then delete.

Commit after every task. Conventional-commit scope is `agent3`, `coding_agent`, or `tui` as appropriate. No "generated by claude" footnote (per user's global CLAUDE.md).

Per repo doctrine, use `zig build` for compilation and targeted `zig test src/<touched-file>.zig` checks for tests. Do **not** use `zig build test` while following this plan.

---

## Preconditions

- Git tree clean on `main` (already true per session start).
- Decide worktree vs in-place: see "Execution handoff" at the end.
- Keep every checkpoint green. Do **not** add a placeholder failing test before the public run-control surface exists.
- The user-facing bug will still be observable until Task 9; earlier tasks are staging only. Don't bisect from intermediate commits expecting the behavior fix before then.

---

### Task 1: Pin the regression-test shape without breaking the tree

**Files:**
- No code changes yet.

**Why here:** the final regression test belongs in `src/coding_agent/runtime_host.zig`, but the public run-control surface does not exist until later tasks. Adding `expect(false)` now would contradict the plan's own "keep every checkpoint green" rule.

**Step 1: Read the existing faux-provider tests in `src/coding_agent/runtime_host.zig` and identify the insertion point for the final regression test.**

**Step 2: Lock the intended assertion shape now:** start with the simpler guard in Task 10 — `host.enqueueQueuedText(...)` followed immediately by `host.snapshotQueuedMessages(...)` must observe the queued message without any inbox drain. If that lands cleanly, optionally extend to the threaded mid-stream variant in the same task.

**Step 3: No commit. This task is planning-only scaffolding.**

---

### Task 2: Split PublishedConversationState into view + queued

**Files:**
- Modify: `src/agent3/conversation_state.zig:27-36`

**Step 1: Rename and narrow**

Replace `PublishedConversationState` with `ConversationViewSnapshot`:

```zig
pub const ConversationViewSnapshot = struct {
    view: ConversationView,

    pub fn deinit(self: *ConversationViewSnapshot, allocator: std.mem.Allocator) void {
        self.view.deinit(allocator);
        self.* = undefined;
    }
};
```

Delete the old `PublishedConversationState`. `QueuedMessageSnapshot` continues to live in `control.zig` unchanged — it's the second payload.

**Step 2: Update all imports**

```bash
zig build 2>&1 | head -60
```

Expected: compile errors pointing at all call sites (`coding_agent/runtime_host.zig`, `tui/interactive.zig`, `tui/conversation_projection.zig`, `tui/ui_event.zig`, the `rebuildFromState`/`reconcileFromState` signatures). Fix each by substituting `ConversationViewSnapshot` where the payload is the view only, and add a separate `QueuedMessageSnapshot` parameter where queued is actually used.

Key sites to update:
- `src/coding_agent/runtime_host.zig:35-41` — `ConversationStatePublisher.publish` now takes `ConversationViewSnapshot`. Add a new `QueuedSnapshotPublisher` struct mirroring the same shape but carrying `QueuedMessageSnapshot`.
- `src/coding_agent/runtime_host.zig:211-241` — `publishConversationState` drops the queued-snapshot build. Add `publishQueuedSnapshot(publisher)` that calls `session.cloneQueuedMessageSnapshot` and publishes.
- `src/tui/ui_event.zig:15, 121-...` — `UiEvent.conversation_state` holds `ConversationViewSnapshot`. Add new variant `UiEvent.queued_snapshot: QueuedMessageSnapshot` plus its `take...`/`deinit` handling (mirror `queued_inputs_restored`).
- `src/tui/conversation_projection.zig:99-140, 142-222, 256-...` — `ProjectionState.state` becomes `view_snapshot: ?ConversationViewSnapshot`. Add `queued_snapshot: ?QueuedMessageSnapshot` as a separate field. `rebuildFromState` / `reconcileFromState` accept both, merge them in `buildDesiredItems`. The `ownedConversationStateFromMessages` helper splits in two: one returns a view snapshot, one returns an empty queued snapshot.

**Step 3: Build**

```bash
zig build 2>&1 | tail -20
```

Expected: compiles clean.

**Step 4: Run tests to confirm no regression from the rename**

```bash
zig test src/tui/conversation_projection.zig 2>&1 | tail -10
```

Expected: pass.

**Step 5: Commit**

```bash
git add -A src/agent3/conversation_state.zig src/coding_agent/runtime_host.zig src/tui/ui_event.zig src/tui/conversation_projection.zig src/tui/interactive.zig
git commit -m "refactor(agent3): split PublishedConversationState into view and queued snapshots"
```

---

### Task 3: Add Agent-level queued-message snapshot helpers

**Files:**
- Modify: `src/agent3/agent.zig` (alongside `steer`/`followUp`/`hasQueuedMessages`)

**Step 1: Add the helpers**

Insert after `clearAllQueues` (~line 250):

```zig
pub fn snapshotQueuedMessages(self: *Agent, allocator: std.mem.Allocator) control_mod.QueuedMessageSnapshot {
    return self.run_control.snapshot(allocator);
}

pub fn takeQueuedMessagesAndClear(self: *Agent, allocator: std.mem.Allocator) control_mod.QueuedMessageSnapshot {
    return self.run_control.clearAndSnapshot(allocator);
}
```

**Step 2: Build & test**

```bash
zig test src/agent3/agent.zig 2>&1 | tail -10
```

Expected: pass.

**Step 3: Commit**

```bash
git add src/agent3/agent.zig
git commit -m "feat(agent3): expose run-control snapshot helpers on Agent"
```

---

### Task 3a: Make queued snapshots atomic and versioned

**Files:**
- Modify: `src/agent3/control.zig`
- Modify: `src/runtime/mailbox.zig` **if** the cleanest implementation needs a mailbox helper to hold one lock across snapshot+clear
- Modify: `src/agent3/agent.zig` **if** you need a thin version accessor after the `RunControl` change

**Why here:** once queued snapshots can be published from both the TUI thread and the agent thread, ordering has to be explicit. Also, direct `restoreQueuedInputsToEditor` turns snapshot+clear into a live concurrent path, so the current two-lock `snapshotTexts(); clear();` sequence is no longer acceptable.

**Step 1: Add a monotonic queued-state version.**

Extend `QueuedMessageSnapshot` with `version: u64`. Bump that version on every run-control mutation the UI can observe: enqueue, drain, clear, and atomic take+clear. Expose a `currentQueuedVersion()` helper on `RunControl`, then a thin `Agent.currentQueuedVersion()` wrapper if Task 6/8 wants it.

**Step 2: Make `takeSnapshotAndClear` atomic at the queue boundary.**

Do **not** keep the current `snapshotTexts(); clear();` shape. Move the implementation to a single-lock path: either add a mailbox helper that clones pending items and clears them while holding the mutex once, or move `MessageQueue.takeSnapshotAndClear` down onto mailbox internals so it can do the same.

**Step 3: Thread the version through all snapshot builders.**

`RunControl.snapshot(...)` and `RunControl.clearAndSnapshot(...)` should now return snapshots with the current version filled in.

**Step 4: Build & test**

```bash
zig build 2>&1 | tail -20
zig test src/agent3/control.zig 2>&1 | tail -20
```

Expected: pass.

**Step 5: Commit**

```bash
git add src/agent3/control.zig src/runtime/mailbox.zig src/agent3/agent.zig
git commit -m "feat(agent3): make queued snapshots atomic and versioned"
```

---

### Task 4: Route AgentSession queue reads through Agent's RunControl directly

**Files:**
- Modify: `src/coding_agent/agent_session.zig:546-567`

**Step 1: Rewrite `cloneQueuedMessageSnapshot` and `restoreQueuedMessagesOnAgentThread`**

Replace both functions with:

```zig
pub fn cloneQueuedMessageSnapshot(self: *AgentSession, allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
    return self.agent.snapshotQueuedMessages(allocator);
}

pub fn restoreQueuedMessagesOnAgentThread(self: *AgentSession, allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
    return self.agent.takeQueuedMessagesAndClear(allocator);
}
```

Leave the mirror fields and `applyQueueMutation` for now — Task 5 removes them. This step reroutes reads only.

**Step 2: Build & test**

```bash
zig test src/coding_agent/runtime_host.zig 2>&1 | tail -20
```

Expected: pass. Snapshot paths now consult `run_control` directly; the mirror is dead-read but still wired on the write side.

**Step 3: Commit**

```bash
git add src/coding_agent/agent_session.zig
git commit -m "refactor(coding_agent): read queued-message snapshots from RunControl directly"
```

---

### Task 5: Delete the queue mirror and its observer plumbing

**Files:**
- Modify: `src/coding_agent/agent_session.zig` (fields, `wireSubscription`, callbacks, helpers)
- Modify: `src/agent3/agent.zig` (`queue_observer`, `QueueObserver`, `QueueMutationAction`, `setQueueObserver`, `notifyQueueMutation`, `notifyPendingQueueCleared`, the call site in `drainQueuedMessages` and `clearSteeringQueue`/`clearFollowUpQueue`)
- Modify: `src/coding_agent/session_event.zig` (remove `queue_update` variant)
- Modify: `src/tui/interactive.zig:2791-2793` (remove `.queue_update` arm)

**Step 1: Remove from `AgentSession`**

In `src/coding_agent/agent_session.zig`:
- Delete fields `queue_mutex`, `steering_mirror`, `follow_up_mirror` (lines 93-95).
- Delete helpers `queueMutationCallback`, `applyQueueMutation`, `clearQueueMirror`, `cloneQueuedEntries`, `freeQueuedEntries` (lines 898-979).
- In `wireSubscription`, delete the `self.agent.setQueueObserver(...)` block (around lines 582-585).
- In `deinit` (find it; it calls `clearQueueMirror`), remove that call.
- In `emitSessionEvent` callers, remove any emission of `.{ .queue_update = {} }` — should be zero references after Task 5.

**Step 2: Remove from `Agent`**

In `src/agent3/agent.zig`:
- Delete the `QueueMutationAction` enum (~line 26-30) and `QueueObserver` struct (~line 32-35).
- Delete the `queue_observer` field (~line 53).
- Delete `setQueueObserver`, `notifyQueueMutation`, `notifyPendingQueueCleared`.
- In `drainQueuedMessages` (lines 613-620), drop the `notifyQueueMutation(.drained, ...)` loop.
- In `clearSteeringQueue`/`clearFollowUpQueue` (lines 237-245), drop the `notifyPendingQueueCleared(...)` calls.
- In `steer`/`followUp` (lines 221-231), drop the `notifyQueueMutation(.enqueued, ...)` calls.

**Step 3: Remove the session event variant**

In `src/coding_agent/session_event.zig`, delete `queue_update: void,` from the `SessionEvent` union (line 31).

**Step 4: Remove the TUI consumer**

In `src/tui/interactive.zig`, delete the `.queue_update => { ... }` arm in `sessionEventCallback` (lines 2791-2793).

**Step 5: Fix the test at `runtime_host.zig:437-467`**

That test asserts `queue_updates` observed via `SessionEvent.queue_update` after a `followUp`. After this task, `queue_update` is gone. Replace the assertion with a direct check that the session's queued snapshot reflects the enqueued message:

```zig
var snap = host.currentSession().cloneQueuedMessageSnapshot(testing.allocator) catch unreachable;
defer snap.deinit(testing.allocator);
try testing.expectEqual(@as(usize, 1), snap.follow_up.len);
try testing.expectEqualStrings("queued after replace", snap.follow_up[0].text);
```

**Step 6: Build**

```bash
zig build 2>&1 | tail -40
```

Expected: clean. Any remaining compile errors indicate a missed reference — grep the codebase for `queue_update`, `QueueObserver`, `steering_mirror`, `follow_up_mirror`, `queue_mutex` and delete.

**Step 7: Run tests**

```bash
zig test src/coding_agent/runtime_host.zig 2>&1 | tail -20
```

Expected: pass.

**Step 8: Commit**

```bash
git add -A src/agent3/agent.zig src/coding_agent/agent_session.zig src/coding_agent/session_event.zig src/coding_agent/runtime_host.zig src/tui/interactive.zig
git commit -m "refactor(agent3): delete queue mirror and queue_update session event"
```

---

### Task 6: Add the RuntimeHost run-control public surface

**Files:**
- Modify: `src/coding_agent/runtime_host.zig`

**Step 1: Add the methods**

Insert near `restoreQueuedMessagesOnAgentThread` (around line 139):

```zig
/// TUI-thread-safe enqueue. Wraps `Agent.steer`/`followUp`; owned text is
/// cloned into a fresh `AgentMessage`, so the caller owns `text` for the
/// duration of this call only.
pub fn enqueueQueuedText(
    self: *RuntimeHost,
    kind: control_mod.QueueKind,
    text: []const u8,
) control_mod.EnqueueResult {
    const message: agent_mod.protocol.AgentMessage = .{ .user = .{
        .content = .{ .text = text },
        .timestamp = std.time.milliTimestamp(),
    } };
    return switch (kind) {
        .steering => self.session.agent.steer(message),
        .follow_up => self.session.agent.followUp(message),
    };
}

/// TUI-thread-safe read. Returns an owned, versioned snapshot.
pub fn snapshotQueuedMessages(self: *RuntimeHost, allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
    return self.session.cloneQueuedMessageSnapshot(allocator);
}

/// TUI-thread-safe drain. Returns an owned snapshot of what was cleared.
/// This path must already be atomic because Task 3a landed first.
pub fn takeQueuedMessagesAndClear(self: *RuntimeHost, allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
    return self.session.restoreQueuedMessagesOnAgentThread(allocator);
}

pub fn currentQueuedVersion(self: *const RuntimeHost) u64 {
    return self.session.agent.currentQueuedVersion();
}
```

(Keep the `restoreQueuedMessagesOnAgentThread` name of the AgentSession helper as-is; it's now misleadingly named but renaming it is churn. The *public* RuntimeHost name is `takeQueuedMessagesAndClear`.)

Also add `publishQueuedSnapshot` that mirrors `publishConversationState` but carries a `QueuedMessageSnapshot`:

```zig
pub const QueuedSnapshotPublisher = struct {
    func: *const fn (snapshot: control_mod.QueuedMessageSnapshot, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,

    pub fn publish(self: QueuedSnapshotPublisher, snapshot: control_mod.QueuedMessageSnapshot) void {
        self.func(snapshot, self.ctx);
    }
};

pub fn publishQueuedSnapshot(self: *RuntimeHost, publisher: QueuedSnapshotPublisher) bool {
    var snapshot = self.session.cloneQueuedMessageSnapshot(self.msg_allocator) catch return false;
    errdefer snapshot.deinit(self.msg_allocator);
    publisher.publish(snapshot);
    return true;
}
```

**Step 2: Build**

```bash
zig build 2>&1 | tail -10
```

**Step 3: Commit**

```bash
git add src/coding_agent/runtime_host.zig
git commit -m "feat(coding_agent): expose run-control as a public RuntimeHost surface"
```

---

### Task 7: Teach the TUI projection to merge two snapshots locally

**Files:**
- Modify: `src/tui/conversation_projection.zig`

**Step 1: Change `ProjectionState`**

Replace `state: ?PublishedConversationState` with:

```zig
pub const ProjectionState = struct {
    allocator: std.mem.Allocator,
    view_snapshot: ?conversation_state_mod.ConversationViewSnapshot = null,
    queued_snapshot: ?control_mod.QueuedMessageSnapshot = null,

    pub fn init(allocator: std.mem.Allocator) ProjectionState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProjectionState) void {
        if (self.view_snapshot) |*s| s.deinit(self.allocator);
        if (self.queued_snapshot) |*s| s.deinit(self.allocator);
        self.view_snapshot = null;
        self.queued_snapshot = null;
    }

    pub fn replaceViewSnapshot(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        snapshot: *conversation_state_mod.ConversationViewSnapshot,
        options: RebuildOptions,
    ) void {
        const owned = snapshot.*;
        snapshot.* = undefined;
        const must_reset_history = if (self.view_snapshot) |previous|
            !committedUserHistoryIsPrefix(previous.view.committed.flat, owned.view.committed.flat)
        else
            false;
        if (self.view_snapshot) |*s| s.deinit(self.allocator);
        self.view_snapshot = owned;
        self.reconcile(transcript, editor, resolver, options);
        if (must_reset_history) {
            editor.clearHistory();
            seedHistoryFromCommittedMessages(editor, self.view_snapshot.?.view.committed.flat);
        }
    }

    pub fn replaceQueuedSnapshot(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        snapshot: *control_mod.QueuedMessageSnapshot,
        options: RebuildOptions,
    ) void {
        const owned = snapshot.*;
        snapshot.* = undefined;
        if (self.queued_snapshot) |current| {
            if (owned.version <= current.version) {
                var stale = owned;
                stale.deinit(self.allocator);
                return;
            }
        }
        if (self.queued_snapshot) |*s| s.deinit(self.allocator);
        self.queued_snapshot = owned;
        self.reconcile(transcript, editor, resolver, options);
    }

    fn reconcile(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        options: RebuildOptions,
    ) void {
        reconcileFromSnapshots(transcript, editor, resolver, self.view_snapshot, self.queued_snapshot, options);
    }
};
```

**Step 2: Adapt `rebuildFromState` / `reconcileFromState` signatures**

Rename to `rebuildFromSnapshots` / `reconcileFromSnapshots`, take `view: ?ConversationViewSnapshot` and `queued: ?QueuedMessageSnapshot`. Inside `buildDesiredItems`, source the committed + in_flight slices from the view snapshot (or default to empty if null) and source queued rows from the queued snapshot (or empty if null). Queued rows render as pending user rows after all committed/in_flight items. Keep the queued snapshot version on the transport type only — `buildDesiredItems` just consumes the latest accepted snapshot.

There is already queued-message rendering logic near `QueuedUserMessageKind` (line 224). Keep it — just source the input slices from two separate snapshots.

**Step 3: Build**

```bash
zig build 2>&1 | tail -40
```

Expected: compile errors in `interactive.zig` at every `replaceAllOwnedState`/`rebuildFromState`/`reconcileFromState` call — those become `replaceViewSnapshot` or `replaceQueuedSnapshot`. Fix them in Task 8.

**Step 4: Do not commit yet — held for Task 8.**

---

### Task 8: Wire the TUI to publish and consume two independent snapshots

**Files:**
- Modify: `src/tui/interactive.zig`
- Modify: `src/tui/ui_event.zig`

**Step 1: Add the `queued_snapshot` UiEvent variant**

In `src/tui/ui_event.zig`:

```zig
queued_snapshot: control_mod.QueuedMessageSnapshot,
```

Add the matching arm to `deinit` and `takeQueuedSnapshot` helper. Pattern is already there for `queued_inputs_restored`.

**Step 2: In `interactive.zig`, split the publisher**

- Rename `publishConversationStateToUi` to `publishViewSnapshotToUi`; it pushes `UiEvent.conversation_state` carrying a `ConversationViewSnapshot`.
- Add `publishQueuedSnapshotToUi` that pushes `UiEvent.queued_snapshot`.
- Add `publishQueuedSnapshot(self)` for unconditional publication and `publishQueuedSnapshotIfChanged(self)` for the agent-thread path.
- Track `last_published_queued_version: u64 = 0` as an **agent-thread-owned** field on `Interactive`. `publishQueuedSnapshotIfChanged(self)` compares `self.runtime_host.currentQueuedVersion()` with `last_published_queued_version`, publishes only when newer, then remembers the published version. The unconditional TUI-thread publish path does not mutate this field; stale-or-duplicate delivery is handled by queued snapshot versioning in `ProjectionState`.
- Callsites that currently call `publishConversationState()` on the agent thread now call `publishConversationState()` (view only) plus `publishQueuedSnapshotIfChanged()` anywhere queued state may have changed or been consumed — at minimum `publishConversationStateForAgentEvent`, `handleNewSession`, and `handleResumeSession`. This is how pending rows disappear after the agent drains steering/follow-up during the run.

**Step 3: Consume both events**

In the UI event dispatch loop (search for `.conversation_state` consumer, around `transcript_mod` reconcile):
- `.conversation_state` → `projection_state.replaceViewSnapshot(...)`.
- `.queued_snapshot` → `projection_state.replaceQueuedSnapshot(...)`.

**Step 4: Build & run tests**

```bash
zig test src/tui/conversation_projection.zig 2>&1 | tail -20
```

Expected: pass.

**Step 5: Commit together with Task 7's changes**

```bash
git add -A src/tui/conversation_projection.zig src/tui/interactive.zig src/tui/ui_event.zig
git commit -m "refactor(tui): project view and queued snapshots independently"
```

---

### Task 9: Remove the inbox hop for run-control (**this fixes the bug**)

**Files:**
- Modify: `src/tui/interactive.zig`
- Modify: `src/coding_agent/request.zig`

**Step 1: Rewrite `queueMessageWhileStreaming`**

Replace the `request_queue.trySend(.enqueue_queued_input ...)` path with a direct call on the TUI thread:

```zig
fn queueMessageWhileStreaming(self: *Interactive, kind: QueuedInputKind, text: []const u8) void {
    const queue_kind: control_mod.QueueKind = switch (kind) {
        .steering => .steering,
        .follow_up => .follow_up,
    };
    switch (self.runtime_host.enqueueQueuedText(queue_kind, text)) {
        .ok => {},
        .closed, .oom => {
            self.status_text.setContent("agent unavailable");
            self.status_text.fg = self.theme.fg(.@"error");
            self.tui.dirty = true;
            return;
        },
    }

    // Publish a fresh queued snapshot so the transcript picks up the new row
    // without waiting for the agent thread to surface from runUserContent.
    _ = self.publishQueuedSnapshot();

    self.active_editor.clear();
    self.refreshGreeterVisibility();
    self.tui.dirty = true;
}
```

Note: `runtime_host.enqueueQueuedText` is safe from the TUI thread because `Agent.steer`/`followUp` → `RunControl.enqueue` → `Mailbox.trySend`, all serialized under the mailbox's own mutex. `publishQueuedSnapshot` reads via the same mailbox, so it observes the enqueue we just performed. If an older agent-thread queued snapshot arrives later, `ProjectionState.replaceQueuedSnapshot(...)` drops it by version.

**Step 2: Rewrite `restoreQueuedInputsToEditor`**

Replace the `request_queue.trySend(.restore_queued_inputs ...)` path with direct drain + publish:

```zig
fn restoreQueuedInputsToEditor(self: *Interactive) void {
    var snapshot = self.runtime_host.takeQueuedMessagesAndClear(self.msg_allocator) catch {
        self.status_text.setContent("failed to restore queued messages");
        self.status_text.fg = self.theme.fg(.@"error");
        self.tui.dirty = true;
        return;
    };

    self.applyRestoredQueuedInputs(&snapshot);
    snapshot.deinit(self.msg_allocator);

    // Queued messages were cleared; refresh the transcript's queued rows.
    _ = self.publishQueuedSnapshot();
}
```

Update `applyRestoredQueuedInputs` to take a `*const QueuedMessageSnapshot` (no ownership change) instead of consuming the snapshot.

**Step 3: Delete the `AgentRequest` variants and handlers**

In `src/coding_agent/request.zig`:
- Delete `enqueue_queued_input` and `restore_queued_inputs` cases from the union and the `deinit` switch.
- Delete their test blocks (`RequestQueue queued-input payload round-trips ...`) or rewrite as a test for the remaining variants.

In `src/tui/interactive.zig`:
- Delete the `.enqueue_queued_input` and `.restore_queued_inputs` arms from `processAgentRequests`.
- Delete `handleEnqueueQueuedInput` and `handleRestoreQueuedInputs`.
- Delete the `UiEvent.queued_inputs_restored` variant if nothing else drives it — the TUI-thread direct path no longer needs a UI event for restore.
  - Check `src/tui/ui_event.zig:88, 157, 222` and `interactive.zig:1177-1179` — if those are the only consumers, delete them.

**Step 4: Build**

```bash
zig build 2>&1 | tail -20
```

Expected: clean.

**Step 5: Run all tests**

```bash
zig test src/coding_agent/runtime_host.zig 2>&1 | tail -20
zig test src/tui/ui_event.zig 2>&1 | tail -20
```

Expected: pass.

**Step 6: Commit**

```bash
git add -A
git commit -m "fix(tui): route steering through run-control directly, not the agent inbox

Steering submits and queued-input restores no longer wait for
runUserContent to return; they hit the agent's run-control mailbox
from the TUI thread and re-publish the queued snapshot immediately.
Closes the regression where pending messages and Alt+Up restore
only appeared after the LLM finished streaming."
```

---

### Task 10: Add the real regression test once the surface exists

**Files:**
- Modify: `src/coding_agent/runtime_host.zig`

**Step 1: Add the real test.**

Start with the simpler guard first: `host.enqueueQueuedText(.steering, "hi")` followed immediately by `host.snapshotQueuedMessages(...)` must show the queued message without any request-inbox drain. That proves the new public run-control path is immediately observable.

If that lands cleanly and the fixture cost is reasonable, extend the same test or add a second one with a `StreamHook` / `ResetEvent` pause so the enqueue happens while streaming is actually in progress. In that threaded variant, resume the stream after the enqueue and verify the loop later consumes the queued steering message at its steering poll point.

**Step 2: Run the targeted test**

```bash
zig test src/coding_agent/runtime_host.zig 2>&1 | tail -20
```

Expected: pass.

**Step 3: Commit**

```bash
git add src/coding_agent/runtime_host.zig
git commit -m "test(coding_agent): assert run-control enqueue is observable without draining the inbox"
```

---

### Task 11: Manual verification

**Step 1: Build the interactive binary**

```bash
zig build 2>&1 | tail -5
```

**Step 2: Run it against a real model (user does this)**

Exercise:
1. Start a prompt that streams for >5s.
2. While streaming, type a new message and press Enter.
3. **Expected:** the message appears immediately in the transcript as a pending/queued row. No waiting for streaming to finish.
4. During the same stream, type another message, press `Alt+Up`.
5. **Expected:** the queued message is restored to the editor immediately, and its row disappears from the transcript immediately.

**Step 3: Run the targeted regression checks one more time**

```bash
zig test src/coding_agent/runtime_host.zig 2>&1 | tail -20
zig test src/tui/conversation_projection.zig 2>&1 | tail -20
```

Expected: all pass.

**Step 4: No commit — this is a verification gate.**

---

## Out of scope / future follow-ups

These are *not* in this plan — call them out separately if you want them.

- Renaming `AgentSession.restoreQueuedMessagesOnAgentThread` to `takeQueuedMessagesAndClear` inside `agent_session.zig`. The public `RuntimeHost` surface already has the right name; renaming the private helper is churn.
- Collapsing `UiEvent.queued_snapshot` into `UiEvent.conversation_state` as a tagged variant. They publish at different boundaries and have different cadence, so two events is the correct shape.
- Moving queued-snapshot publication to a single producer. This plan keeps dual producers (TUI-thread immediate publishes, agent-thread drain/session publishes) and relies on queued snapshot versioning to resolve ordering.

# Inspect agent transcripts without leaving the root session

## Status

Implemented on 2026-08-17.

This plan adds one focused, read-only agent transcript inspector to `/agents`. It does not change AgentTeam orchestration, the six collaboration operations, or agent lifecycle semantics.

## Product decision

Selecting an agent from `/agents` opens its transcript at full terminal width. Zi temporarily replaces the visible root workspace with a focused inspector, hides the composer, and keeps the root `AgentSession` authoritative and running underneath.

The inspector is navigation, not another interactive session. It never accepts direct child input, starts a turn, changes residency, acknowledges completion, or switches the root session.

`Esc` returns to the exact root view: same draft, transcript viewport, active workspace layout, and focused composer. The agent transcript may update while it is visible. The hidden root session continues receiving authoritative updates, while its presentation is suspended and reconciles once when restored.

## Why this is not a pane

Agent transcripts contain prose, code, diffs, and tool output that need columns. A default side pane narrows that content, competes with the work-plan pane, adds focus chrome, and creates pressure for tabs, direct child input, arbitrary splits, and a multi-agent cockpit.

Zi's binary-tree workspace remains the right owner for persistent secondary views. Agent inspection is temporary and focused, so entering it suspends the presented workspace without mutating its layout tree. Returning restores that tree unchanged.

A side-by-side `Pin to pane` action is deliberately excluded. It may be reconsidered only after repeated dogfood evidence that users need simultaneous parent/child comparison.

## Interaction contract

### Open the picker

`/agents` keeps its existing root-wide durable list and running/all scope toggle.

```text
 Agents · All

   owner_map         [completed #1]  /root/owner_map
 > recursive_probe   [working #2]    /root/recursive_probe
   journal_probe     [completed #1]  /root/recursive_probe/journal_probe

 Enter inspect · Tab show running · Esc close
```

Rows keep task name, lifecycle, turn number, and canonical path searchable. Status remains textual; color may reinforce it but never carries the state alone.

### Open an agent

`Enter` closes the picker and immediately enters the inspector. The first frame does not wait for journal I/O.

```text
 root › recursive_probe                         explorer · loading
──────────────────────────────────────────────────────────────────────────────

 Loading agent transcript…

──────────────────────────────────────────────────────────────────────────────
 Read-only agent transcript                                  Esc cancel
```

Once loaded, Zi renders the child through the same transcript presentation used by the root:

```text
 root › recursive_probe                  explorer · working · turn 2
──────────────────────────────────────────────────────────────────────────────

 Inspecting restoration tests

 ◆ Read packages/coding-agent/test/agent-team-integration.test.ts
   lines 103–169

 ◆ Search "agent_completion_delivered" in packages/coding-agent
   14 matches

 The recursive restoration test rebuilds both durable records from the root
 journal and keeps the nested child addressed to its direct parent.

 ● Working…

──────────────────────────────────────────────────────────────────────────────
 Read-only agent transcript                         Esc return to root
```

There is no enclosing pane border and no disabled composer. The breadcrumb establishes location, the existing transcript renderer preserves familiar tool presentation, and one footer explains the mode and exit.

For a nested path, the breadcrumb preserves lineage:

```text
 root › recursive_probe › journal_probe       worker · completed · turn 1
```

Long task names truncate only in the header. The complete canonical path remains available in `/agents`; transcript content is never narrowed to preserve header metadata.

### Return

`Esc` from loading, viewing, or failure returns to the root. It cancels an unsettled load, disposes the transcript observation, restores the suspended workspace presentation, and focuses the existing root composer.

The first version has no second exit chord, next/previous agent navigation, or direct operation shortcuts. Existing transcript scrolling and tool expansion keys continue to work while viewing.

### Loading failure

A failed load becomes a focused, bounded error rather than a blank transcript or silent return:

```text
 root › recursive_probe                         explorer · unavailable
──────────────────────────────────────────────────────────────────────────────

 Unable to load this agent transcript.
 The durable child journal is unavailable.

──────────────────────────────────────────────────────────────────────────────
 Esc return to root
```

The error is calm, source-attributed where useful, and clipped to the existing diagnostic bound. Recovery is returning to the root and reopening `/agents`; the inspector does not retry automatically.

## States and transitions

`InteractiveMode` owns one inspector controller. Its state is explicit and separate from the root session, picker workflow, and workspace layout.

```ts
type AgentTranscriptInspectorState =
  | { readonly type: "root" }
  | {
      readonly type: "loading"
      readonly operationId: number
      readonly path: AgentPath
      readonly controller: AbortController
    }
  | {
      readonly type: "viewing"
      readonly operationId: number
      readonly path: AgentPath
      readonly transcript: AgentTranscriptLease
    }
  | { readonly type: "failed"; readonly operationId: number; readonly path: AgentPath; readonly message: string }
  | { readonly type: "disposed" }
```

Allowed transitions:

```text
root --select(path)------------------------> loading
loading --load succeeds for operation-----> viewing
loading --load fails for operation--------> failed
loading --Esc/session replacement---------> root
viewing --Esc/session replacement----------> root
failed --Esc/session replacement----------> root
any live state --InteractiveMode disposal--> disposed
```

A completion whose `operationId` is stale is disposed immediately and cannot replace the current screen. Only the controller that creates the load abort controller and transcript lease releases them.

The picker owns selection and filtering only. It reports the selected canonical path through one typed intent; it does not load journals, create transcript sources, or alter the workspace.

## Authoritative transcript source

The child `SessionManager` remains authoritative for committed messages. A resident child `AgentSession` additionally owns streaming text, active tools, retries, compaction, shell tasks, and work-plan state.

The root `AgentSession` exposes one client-independent operation backed by AgentTeam:

```ts
openAgentTranscript(path: AgentPath, signal: AbortSignal): Promise<AgentTranscriptLease>
```

The exact public export boundary is not part of this plan; this is an internal coding-agent/client contract until another client proves a need for it.

```ts
interface AgentTranscriptLease {
  readonly path: AgentPath
  snapshot(): AgentTranscriptSnapshot
  subscribe(listener: () => void): () => void
  dispose(): void
}

interface AgentTranscriptSnapshot {
  readonly agent: AgentSnapshot
  readonly messages: readonly AgentMessage[]
  readonly streamingMessage?: AgentMessage
  readonly isStreaming: boolean
  readonly isAborting: boolean
  readonly retryStatus: AgentSession["retryStatus"]
  readonly compactionStatus: AgentSession["compactionStatus"]
  readonly workPlan: AgentSession["workPlan"]
  readonly shellTasks: readonly ShellTaskSnapshot[]
}
```

Final names may follow the existing exported projection types, but the contract must retain concrete fields rather than erase them behind `unknown` or a generic event envelope.

### Unloaded agent

Opening an unloaded agent reads its exact child journal through the AgentTeam/session-storage owner and returns the session manager's bounded authoritative message references. `TranscriptView` retains only its existing 200-message projection and derives the omission count from that authoritative array. The operation does not construct an `AgentSession`, extension host, shell, Code Mode worker, or model client, and it does not consume residency or active-turn capacity.

The operation starts after the inspector's first draw, is cancellable, and is single-flight for the selected path. The session-file, session-entry, message, and render-projection limits remain hard bounds; the TUI does not copy the child history into another store or add pagination in this version.

### Resident agent

Opening a resident agent observes its existing `AgentSession`. The lease adapts semantic session notifications into one revision stream consumed by the existing `TranscriptView`; it does not add an independent timer, polling loop, or frame scheduler.

### Residency transitions while viewing

Inspection never pins residency.

If a viewed resident agent settles and unloads, AgentTeam publishes the settled durable projection to the lease before releasing the child session. The inspector remains visible and becomes a static durable transcript.

If a viewed unloaded agent receives a follow-up elsewhere and becomes resident, the lease rebinds to the new live session without replacing the TUI root or losing viewport state. Stale callbacks from the prior source generation are rejected.

If the root shuts down or switches sessions, the inspector closes before AgentTeam disposal. No lease or scheduled render callback may outlive its owning root generation.

## TUI composition

`AgentTranscriptInspector` is a concrete imperative component composed by `InteractiveMode` above `SessionWorkspace`.

```text
InteractiveMode
  AgentTranscriptInspector controller
    root state    -> SessionWorkspace visible
    loading       -> focused loading surface
    viewing       -> focused TranscriptView
    failed        -> focused error surface
```

Entering inspection hides but does not destroy `SessionWorkspace`. Its binary layout, work-plan pane, transcript viewport, prompt draft, and native renderable identities remain intact. `SessionWorkspace` suspends presentation reconciliation while hidden, records only a dirty generation, and performs one normal sync when restored; authoritative root state is never mirrored into the inspector. Returning makes the workspace visible and restores prompt focus.

The inspector creates one `TranscriptView` with an `AgentTranscriptSource` adapter over the lease. It reuses existing message, Markdown, tool, status, selection, and scrolling presentation. It does not fork a second transcript renderer or copy message text into a presentation store.

The inspector owns at most:

- one active load;
- one transcript lease;
- one transcript source adapter;
- one `TranscriptView`;
- one loading or error surface.

Selecting another agent requires returning to `/agents` in the first version, so there is no retained agent-source cache or list of hidden transcript views.

## Presentation rules

- Use `agent`, `agent transcript`, and canonical agent paths. Do not restore `subagent` product vocabulary.
- Use the existing theme's semantic text, muted, accent, success, warning, and error roles. Do not add an inspector palette.
- Show lifecycle with text or a text-plus-glyph pair. Never use color alone.
- Keep chrome to the header separator and footer separator already shown in the specification.
- Do not animate entry, exit, status, or streaming indicators beyond existing transcript behavior.
- Preserve full-width transcript wrapping at every terminal size.
- Keep changing turn numbers aligned through the terminal's fixed-width cell grid; do not add decorative columns.
- Do not synthesize a separate task card if the task already appears in the authoritative child transcript.

## Bounds and performance

- Reuse `TranscriptView`'s 200-message and tool-view projection bounds.
- The coding-agent transcript operation returns authoritative message references under existing session bounds; `TranscriptView` retains 200 and renders its existing omission marker.
- Loading one unloaded journal is cancellable and single-flight; a second selection cannot join stale work.
- Live updates use the renderer-owned transcript reconciliation path and semantic notification stream.
- Unchanged committed message renderables retain identity during streaming and lifecycle changes.
- Hiding the root workspace suspends transcript and work-plan presentation work without destroying retained renderables; restoration admits one coalesced sync from authoritative state.
- Closing the inspector clears native selection before destroying selectable nodes and cancels pending frame requests.
- Tests assert structural counts, stable identity, stale-completion rejection, and cleanup rather than wall-clock thresholds.

## Accessibility and keyboard contract

- The complete flow is keyboard-only: `/agents`, arrows, `Tab`, `Enter`, `Esc`.
- The selected picker row remains visibly distinct without relying only on color.
- `Enter` always has the advertised action when a row is selected.
- The inspector has one focus target: its transcript scroll surface, loading surface, or failure surface.
- Returning restores focus to the root composer and preserves its draft.
- Status is repeated in text for terminals or assistive tooling that cannot distinguish theme colors.
- Resize cannot make the exit instruction or transcript unreachable; header and footer remain stable chrome while the transcript scrolls.

Terminal screen-reader behavior depends on the emulator and OpenTUI. This plan does not claim browser ARIA semantics, but it preserves deterministic keyboard order, textual state, and focus restoration.

## Deliberate non-goals

- No direct user input to an agent.
- No composer in the inspector.
- No follow-up, send, interrupt, or delete buttons.
- No `/agent` alias; `/agents` remains the collection command.
- No agent transcript panes, tabs, arbitrary tiling, or `Pin to pane` action.
- No next/previous agent shortcuts.
- No transcript search, full-history pagination, or cross-agent query cache.
- No change to completion delivery, direct-parent routing, residency, or AgentTeam journals.
- No new frontend-wide projection schema or generic pane/overlay registry.

## Vertical implementation slices

### Slice 1: Bounded durable transcript lease

Behavior:

- root `AgentSession` opens one known agent transcript by canonical path;
- unloaded persistent and in-memory agents return bounded committed transcript state;
- opening does not make the agent resident;
- unknown paths, missing journals, cancellation, and stale completion fail explicitly;
- disposal releases every listener and loaded projection.

Tests:

- completed unloaded agent after normal settlement;
- interrupted unloaded agent;
- recursive descendant path;
- root restart followed by transcript open;
- no residency or active-turn change before and after inspection;
- cancellation and missing-journal failure.

Verification:

```text
coding-agent AgentTeam, AgentSession, session-storage, and production integration suites
workspace typecheck and lint
```

### Slice 2: Focused completed-transcript inspector

Behavior:

- `/agents` footer advertises `Enter inspect`;
- selecting a completed agent shows loading on the next frame and then a full-width transcript;
- the composer and tiled workspace are absent from the visible inspection surface;
- `Esc` restores the exact root draft, viewport, workspace layout, and prompt focus;
- load failure shows the bounded focused error state;
- session replacement and shutdown close the inspector.

Tests:

- picker activation emits the canonical path;
- explicit inspector state transitions and stale-load rejection;
- loading, viewing, and failed render snapshots at wide and narrow sizes;
- root native renderable identity and draft survive round-trip;
- hidden root notifications coalesce without transcript reconciliation and restore through one sync;
- only one transcript view exists and cleanup returns listener/renderable counts to baseline.

Verification:

```text
TUI prompt, interactive store, transcript, workspace, and keybinding suites
structural renderer diagnostics
manual keyboard walkthrough
```

### Slice 3: Live transcript handoff

Behavior:

- a running agent streams through the focused inspector;
- settlement changes the header and hands the lease to durable state without pinning residency;
- a follow-up can make a viewed unloaded agent live without replacing the inspector;
- root work and completion delivery continue while hidden;
- returning reveals the root's accumulated authoritative updates.

Tests:

- streaming tail reconciliation without rebuilding committed siblings;
- resident-to-unloaded and unloaded-to-resident source generations;
- interrupted and failed terminal states;
- stale child events after unload, session replacement, and inspector disposal;
- bounded message/tool projections under repeated agent turns.

Verification:

```text
coding-agent/TUI integration suites
TUI structural performance tests
compiled release acceptance with one live and one restored agent transcript
```

### Slice 4: Documentation and dogfood acceptance

Update `docs/subagents.md` with the exact `/agents` inspection behavior, read-only boundary, restart behavior, and keyboard controls. Keep the page's existing explanation that AgentTeam identity and lifecycle are authoritative.

Dogfood one persistent root through:

1. spawn a running direct child and inspect it live;
2. return to the root with its draft intact;
3. inspect an interrupted unloaded child;
4. inspect a recursive descendant;
5. exit Zi, resume the exact root session, and inspect the same durable child;
6. force an unavailable child journal and verify the focused error path.

Run `better-interface full` on `/agents → inspect transcript → return to root`, covering accessibility, layout, writing, typography, colors, and UI restraint across empty, loading, live, settled, interrupted, failed, unavailable, restart, wide, and narrow states.

## Acceptance criteria

- Selecting an agent has one obvious outcome: inspect its transcript.
- The transcript uses full terminal width and the existing root transcript presentation.
- The root remains authoritative; inspection cannot accept input or mutate agent lifecycle.
- Viewing never pins or loads agent runtime residency.
- Live and durable sources hand off without duplicate messages, viewport loss, polling, or stale callbacks.
- `Esc` restores the exact root interaction state.
- The picker, inspector, transcript projection, listeners, renderables, and async work remain bounded.
- No second collaboration substrate, generic pane system, compatibility alias, or direct-agent interaction model is introduced.

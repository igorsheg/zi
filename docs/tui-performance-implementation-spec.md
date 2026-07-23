# TUI hot-path and scaling implementation spec

Status: implemented baseline and active constraints

This specification governs the next performance and scaling work in `packages/tui`. It applies the useful framework-independent patterns inspected in OpenCode's `v2` branch at `4678bd104` while preserving Zi's imperative `@opentui/core` architecture, Pi-compatible terminal behavior, and existing owner boundaries.

## Outcomes

The work must deliver:

1. transcript updates whose cost depends on the changed tail, not the full session;
2. stable native renderable identity during streaming and tool progress;
3. at most one transcript reconciliation per visible frame;
4. a hard bound on retained transcript message renderables;
5. development instrumentation for first draw, native frame cost, transcript reconciliation, and retained nodes;
6. a defined migration to framework-neutral `@opentui/keymap` before independently focused modes or extension shortcuts multiply;
7. owner-driven asynchronous loading for every future terminal catalog or history page;
8. an evidence threshold that must be met before introducing custom framebuffer renderables.

## Non-goals

This work does not:

- move authoritative messages out of `AgentSession`;
- introduce a frontend-wide message cache, event bus, root store, or generic projection framework;
- adopt Solid, React, or their provider/context architecture;
- change the composer-owned picker interaction;
- add transcript history paging before coding-agent exposes a concrete paging operation;
- add a plugin or modal framework speculatively;
- replace Markdown, text, box, or scrollbox renderables with custom drawing code;
- change alternate-screen behavior or move completed output into native terminal scrollback.

## Reference patterns

The relevant OpenCode `v2` sources are:

- `packages/tui/src/context/data.tsx`: typed event application, bounded hydration, message indexes, and owner-driven synchronization;
- `packages/tui/src/routes/session/rows.ts`: stable presentation rows separated from authoritative message data;
- `packages/tui/src/keymap.tsx` and `packages/tui/src/context/keymap.tsx`: one instance-scoped framework-neutral keymap with layers and modes;
- `packages/cli/src/mini/runtime.ts`: first-paint gating, lazy imports, and work started after renderer idle;
- `packages/tui/src/component/bg-pulse-render.ts`: measured custom drawing with geometry and frame caches;
- `packages/tui/src/plugin/context.tsx`: host-owned registration and reverse-order cleanup.

These are pattern references, not modules to port. OpenCode's client/server projection, large context graph, and Solid component structure do not belong in Zi.

## Existing owners remain authoritative

| Data or resource                                               | Owner                         |
| -------------------------------------------------------------- | ----------------------------- |
| Durable and streaming messages                                 | `AgentSession`                |
| Session replacement and stale-event rejection                  | `InteractiveStore`            |
| Bounded transient tool state                                   | `InteractiveStore`            |
| Retained transcript renderables and presentation indexes       | `TranscriptView`              |
| Follow/detached/unseen navigation                              | `TranscriptStore`             |
| Scroll offsets, viewport, selection, and sticky-tail mechanics | OpenTUI renderables           |
| Renderer statistics and first-draw diagnostics                 | `runTui` / `SessionScreen`    |
| Semantic binding catalog and overrides                         | `InteractiveKeybindings`      |
| Active key layers and command dispatch, once adopted           | one mode-owned OpenTUI keymap |

A transcript projection may retain message indexes, tool-call IDs, renderable references, and omission counts. It may not copy message text, model state, queues, or another mutable message timeline.

# 1. Transcript hot path

## Replaced path

The original hot path was:

```text
AgentSession message/tool event
  -> InteractiveStore increments transcriptRevision
  -> TranscriptView.#syncContent()
      -> scan all messages for tool calls
      -> append newly committed messages
      -> destroy and rebuild the streaming message
      -> destroy and rebuild every active tool
```

`message_update` can execute this path for every provider delta. `TranscriptView` also subscribes to both `$transcriptRevision` and `$activeTools`, although every active-tool transition already increments `transcriptRevision`.

## Target retained shape

`TranscriptView` remains the one owner, with these private resources:

```ts
interface CommittedMessageView {
  readonly messageIndex: number
  readonly root: Renderable
}

class TranscriptView {
  #session: AgentSession
  #nextMessageIndex: number
  #omittedMessageCount: number
  #committed: CommittedMessageView[]
  #pendingToolCalls: Map<string, PendingToolCall>
  #streaming: StreamingAssistantView | undefined
  #toolViews: Map<string, ToolCallView>
  #standaloneTools: Map<string, ToolCallView>
  #dirty: boolean
}
```

The concrete names may change during implementation, but ownership may not be split into a generic reconciler, row registry, or controller hierarchy.

The native child order remains:

```text
optional omitted-history marker
committed message roots, with source-ordered embedded tool roots
optional streaming assistant root, with source-ordered embedded tool roots
standalone fallback tool roots in InteractiveStore order
```

## Frame admission

`TranscriptView` subscribes only to `$transcriptRevision`, marks its projection dirty, and requests a native render. Its root owns one OpenTUI lifecycle pass that reconciles before layout.

Rules:

1. The first dirty notification requests one native frame.
2. Further notifications before that frame only remain dirty.
3. The lifecycle pass clears the dirty state and reads the current authoritative session state once.
4. Reconciliation runs before the frame's layout and native render; no follow-up timer is introduced.
5. Destroying the root unregisters the lifecycle pass before destroying owned renderables.
6. Session replacement continues to destroy the old `SessionScreen`; no lifecycle pass from the old screen may mutate the replacement.

OpenTUI 0.4.5 executes its installed `requestAnimationFrame` immediately when an idle renderer is activated, so RAF admission alone does not coalesce separately delivered provider deltas. No `setTimeout`, polling loop, or independent FPS scheduler is allowed in this path. Renderer-installed RAF remains appropriate for the one-frame-later detached-scroll anchor correction.

## Committed messages

Committed messages are append-only during an ordinary session run.

For each newly observed `session.messages[index]`:

1. record assistant tool calls in `#pendingToolCalls`;
2. resolve a tool result from that bounded map when possible;
3. build its durable message renderable once;
4. insert it before transient streaming/tool roots;
5. retain `{ messageIndex, root }`;
6. remove a consumed tool call after its tool-result view is built.

A reset occurs only when:

- the `AgentSession` identity changes;
- `session.messages.length < #nextMessageIndex`;
- a future coding-agent event explicitly reports history replacement.

A reset destroys the owned message roots, clears presentation indexes, computes the bounded initial window, and rebuilds only that window.

`#pendingToolCalls` is presentation metadata, not a transcript copy. It is limited to 64 unresolved calls. On overflow, discard the oldest entry; a later tool result falls back to `message.toolName`, as it already does when call arguments are unavailable.

## Streaming assistant

Add one deep `StreamingAssistantView` under `interactive/transcript/`. It owns one stable root for the lifetime of the active `session.streamingMessage`.

Its `update(message)` operation:

- returns immediately when the visible value did not change;
- keeps thinking `TextRenderable` instances stable and assigns only changed content;
- keeps answer `MarkdownRenderable` instances stable and assigns only changed content;
- leaves `MarkdownRenderable.streaming = true` while receiving deltas;
- appends native part renderables when new visible parts appear;
- rebuilds only the suffix beginning at the first part whose visible kind changed;
- updates or removes the error row independently;
- never reconstructs the root merely because text grew.

Promoted and restored committed messages also retain streaming presentation because OpenTUI 0.4.5 otherwise drops Markdown blocks from the immediate frame. Revisit finalization only when it preserves first-frame content and native identity.

Tool-call parts create keyed `ToolCallView` children at their source positions. The same child receives partial parsed arguments, ready/running state, partial output, and the committed tool result. A streaming assistant root is promoted only at the message index where that stream began, preventing a coalesced later stream from being attached to an earlier committed assistant message.

When streaming ends, `TranscriptView` promotes the same root only when its recorded starting message index matches the committed assistant index. A coalesced newer stream can therefore never attach to an earlier message, and promotion does not depend on undocumented message object identity from `pi-agent-core`.

If a future stream presents a non-assistant message, `TranscriptView` uses the existing static message builder and replaces that one transient root only when its role changes.

## Active tools

`ToolCallView` is the concrete keyed handle:

```ts
interface ToolViewFrame {
  readonly status: ToolPresentationSource["status"]
  readonly presentation: ToolPresentation
}

interface ToolCallView {
  readonly root: BoxRenderable
  readonly isRunning: boolean
  update(frame: ToolViewFrame): boolean
  refreshRunning(now: number): boolean
  setExpanded(expanded: boolean): boolean
  setActionHint(hint: string | undefined): boolean
  destroy(): void
}
```

`InteractiveStore` owns bounded `preparing | ready | running | done | failed | aborted` transitions. `message_update` uses `assistantMessageEvent.contentIndex` to update only the changed tool-call arguments. `message_end` marks complete arguments ready, `tool_execution_update` applies partial results, and the later tool-result commit removes transient state. `agent_end` converts every remaining nonterminal invocation to aborted so sequential calls skipped after interruption cannot remain waiting.

The transcript projection calls coding-agent's pure `projectToolPresentation()` only when the source invocation changes. `ToolCallView` receives lifecycle status plus the resulting verb-first header, optional terminal/source/diff/text body, structured notices, explicit compact/detailed windows, and generic timing policy. It never receives raw arguments/results and never switches on built-in names. Running refresh updates generic lifecycle chrome only—the marker pulse and timing—and does not reproject, serialize, validate, truncate, or syntax-highlight tool data.

`StreamingAssistantView` embeds handles by tool-call ID. `TranscriptView` admits at most 64 projected tool IDs across all placements, indexes those non-owning handles, updates them from the transient map, and applies a committed tool result in place. Excess calls receive bounded omission rows. If no originating assistant tool view is retained, it creates one standalone fallback; that fallback is promoted rather than recreated when its result commits. If message eviction removes an assistant while its result remains retained, the embedded root is detached and promoted to that result position before its parent is destroyed. Only standalone roots are reordered.

The handle retains stable header, body, notice, action-hint, and open-rail chrome owners. A body owner is selected only by the generic body primitive and updates in place while that primitive remains unchanged. Replacing a body subtree clears native selection first. Hidden previews short-circuit before line splitting or wrapping; visible compact previews retain at most 12 rows and detailed previews at most 200 visual rows through directional cell-aware head, tail, or edge admission. The mode-owned `app.tools.expand` binding updates retained handles without replacing roots. One transcript-owned renderer live request supplies one timestamp to every visible running tool. Each handle refreshes elapsed text and changes the `◈` marker foreground only when its shared 100 ms phase changes; rails remain static, and views and tools own no timers. Foreground shell action hints derive from the authoritative session task and semantic keybinding owner, not a tool-name branch. Transcript-item spacing, transparent tool surfaces, lifecycle-only glyphs, and structural selection behavior are specified in `docs/transcript-item-presentation-implementation-spec.md`; semantic projection remains specified in `docs/tool-presentation-implementation-spec.md`.

## One notification stream

Remove `TranscriptView`'s direct `$activeTools` subscription. `InteractiveStore.transitionInteractiveState()` already increments `transcriptRevision` for every accepted tool start, update, and end. Tests must preserve that invariant.

Do not add a second transcript event bus. Reconciliation reads `AgentSession` and `$activeTools` from their existing owners at the admitted frame.

# 2. Bounded terminal projection

## Limits

The first implementation uses:

```ts
const maxProjectedMessages = 200
const maxProjectedToolViews = 64
const maxPendingToolCalls = 64
```

The retained transcript is therefore bounded by:

- at most 200 committed message roots;
- one omitted-history marker;
- one streaming root;
- at most 64 transient invocation states and at most 64 projected tool roots across embedded, standalone, and committed placements;
- the existing status overlay.

The 200-message limit follows the current OpenCode `v2` hydration bound and is large enough for normal terminal context while preventing unbounded native trees. It limits presentation only; `AgentSession.messages` and persistence are untouched.

## Initial session projection

For `N` committed messages:

```ts
const start = Math.max(0, N - maxProjectedMessages)
```

Build messages in `[start, N)`. If `start > 0`, insert a one-line non-selectable marker:

```text
… 37 earlier messages are not rendered
```

The marker count is cumulative for the current session projection and is updated in place.

## Live eviction

After appending a committed view beyond the limit:

1. choose the oldest committed view;
2. if there is native selection, clear it before destroying selected-capable nodes;
3. when navigation is detached, record the first retained root and its pre-removal `y` position;
4. detach and promote any embedded tool whose result remains inside the projection window;
5. remove and destroy the oldest root;
6. increment and update the omission marker;
7. after OpenTUI settles layout, adjust scroll by the retained anchor's `y` delta;
8. validate operation generation, target scrollbox identity, and destruction state before applying the adjustment.

When following the tail, sticky scroll owns the resulting position and no manual anchor correction runs.

If the detached viewport was inside the evicted root, it lands at the omission marker. Eviction must never transition detached navigation back to following by itself.

## Paging boundary

The marker is not interactive in this slice. History paging requires a coding-agent operation that can supply an older immutable page without making the TUI authoritative. When that operation exists:

- `TranscriptView` requests a page only from an explicit user action near the marker;
- the coding-agent history owner single-flights the request;
- the TUI prepends a bounded page and evicts from the opposite edge;
- a stable visible-root anchor preserves position;
- loading, failure, cancellation, and exhaustion are explicit states owned by the transcript feature.

Do not implement paging by slicing and re-reading `SessionManager` internals from `packages/tui`.

# 3. Instrumentation

Instrumentation is opt-in and instance-scoped. It must not create a mutable module-global metrics registry or write process output from a component.

## Runtime flags

`runTui` recognizes these development environment flags at terminal-run admission:

- `ZI_SHOW_TTFD=1`: mount OpenTUI's `TimeToFirstDrawRenderable` in a small diagnostic overlay;
- `ZI_TUI_STATS=1`: create the renderer with `gatherStats: true`, retain at most 300 samples, and show OpenTUI's debug statistics overlay;
- `ZI_TUI_MEMORY=1`: show an owner-composed memory snapshot covering process memory, session payload, renderer resources, and listeners.

The flags affect diagnostics only. They do not alter application state, loading order, target FPS, or normal rendering when absent.

## Transcript diagnostics

`TranscriptView` maintains a readonly diagnostic snapshot for tests and the optional performance overlay:

```ts
interface TranscriptDiagnostics {
  readonly syncRequests: number
  readonly syncPasses: number
  readonly coalescedRequests: number
  readonly lastSyncMs: number
  readonly maxSyncMs: number
  readonly projectedMessages: number
  readonly omittedMessages: number
  readonly streamingCreates: number
  readonly streamingUpdates: number
  readonly activeToolCreates: number
  readonly activeToolUpdates: number
  readonly activeToolDestroys: number
  readonly toolProjections: number
}
```

Duration sampling uses `performance.now()` only when either diagnostic flag is enabled. Structural counters remain available to renderer tests. The snapshot is not a Nano Store and does not drive ordinary product rendering.

The optional overlay may read `renderer.getStats()` and the transcript snapshot on frame events. It must use ordinary `TextRenderable`/`BoxRenderable` instances, update at most four times per second, and release its frame listener on destruction.

## Memory diagnostics

`AgentSession` exposes a readonly memory diagnostic containing committed active-message count and serialized UTF-8 bytes, current streaming bytes, queued input count and bytes, subscriber count, and `SessionManager` journal ownership. Journal diagnostics distinguish total, resident, and cold entry counts; logical journal bytes; resident entry bytes; image blob bytes; and encoded in-memory cold bytes. Committed accounting initializes lazily and advances on the append-only `message_end` path; a replacement or shrink invalidates it for recomputation. Byte values describe encoded payloads, not JavaScript engine heap allocation.

`InteractiveMode.captureMemoryDiagnostics()` composes that authoritative session snapshot with `process.memoryUsage()`, reachable and process-registered OpenTUI renderable counts, transcript roots, renderer buffer bytes, lifecycle/live request counts, and renderer/key-input listener counts. The result contains plain numbers and retains no owner references.

When `ZI_TUI_MEMORY=1`, the existing diagnostic overlay captures at most once every three seconds from renderer frame events. It introduces no timer, does not keep an idle renderer live, and retains only the displayed snapshot. Exact Zig allocator usage is not inferred from RSS; renderable and buffer counts are the supported native-resource proxies until OpenTUI exposes allocator statistics.

## Performance evidence

CI acceptance uses deterministic structure, not wall-clock thresholds:

- a burst of transcript notifications before a frame produces one reconciliation pass;
- the streaming root keeps identity across deltas;
- an unchanged active tool receives no native update;
- changing one tool does not recreate sibling roots;
- projected committed roots never exceed 200;
- all lifecycle passes, scheduled anchor callbacks, and diagnostic listeners are released on destruction.

Manual profiles record TTFD, average/max native frame time, transcript max reconciliation time, projected messages, and retained root count at representative 80x24 and constrained dimensions. A transcript reconciliation repeatedly exceeding half of the 60 FPS frame budget is evidence for another optimization pass, not an automatic reason to introduce custom drawing.

# 4. Framework-neutral keymap adoption

## Adoption trigger

Do not migrate key handling as part of the transcript hot-path patch. Adopt `@opentui/keymap` before either of these lands:

1. a second exclusive focus mode such as a true modal/dialog stack; or
2. extension-provided terminal commands or shortcuts.

Inline picker state alone does not justify a modal stack because the composer remains the sole focus owner.

## Target ownership

When triggered:

- add `@opentui/keymap` `0.4.5` to the workspace catalog and `packages/tui` dependencies;
- `InteractiveMode` creates exactly one `createDefaultOpenTuiKeymap(renderer)` instance;
- `InteractiveKeybindings` remains the immutable semantic catalog, override parser, hint source, and conflict reporter;
- components register concrete command layers and retain the returned cleanup;
- ordinary textarea mechanics remain in OpenTUI's managed textarea layer;
- mode or modal owners activate exclusive layers; components do not coordinate booleans;
- `InteractiveMode.dispose()` unregisters layers and disposes the keymap after child input owners stop accepting input.

The initial layers are:

```text
global       exit/copy commands that are valid in every product mode
transcript   page, line, and tail navigation
prompt       submit, follow-up, clear, restore, and interrupt
picker       confirm, complete, cancel, up, and down; enabled from PickerStack state
modal        future true modal owner only
```

Picker enablement is derived from `PickerStack`; it is not copied into keymap state. A future modal stack owns its active mode and focus restoration, and the keymap derives reachability from that owner.

## Migration sequence

1. Characterize current physical-key precedence unchanged.
2. Register semantic commands with current callbacks behind `InteractiveKeybindings`.
3. Move transcript handling off `renderer.keyInput`.
4. Move prompt/picker handling off `renderer.keyInput`.
5. Register managed textarea defaults.
6. Remove custom physical event matching only where `@opentui/keymap` now provides equivalent normalized bindings.
7. Keep reserved/overridable extension policy and conflict reporting at the mode boundary.

No mutable global keymap and no component-local physical chord catalog are permitted.

# 5. Owner-driven asynchronous loading

Every future asynchronous terminal load follows this admission sequence:

```text
feature owner receives explicit request
  -> validate current state and authoritative session identity
  -> record loading state with operation identity
  -> start one bounded effect
  -> apply success/failure only if identity and owner state still match
```

Rules:

1. The feature that presents the data decides when it is needed.
2. The coding-agent owner that can authoritatively load it owns single-flight behavior and bounds.
3. `InteractiveMode` does not preload catalogs for inactive screens.
4. Renderer construction and first draw do not await model lists, session lists, extension catalogs, repository state, or history pages.
5. Independent required startup reads run concurrently.
6. Heavy optional modules use dynamic import from the narrow branch that needs them.
7. Disposal cancels owner-created effects; stale completion is ignored even if cancellation loses a race.
8. Failure remains local and retryable; it does not poison an application-wide cache.
9. Results are bounded before entering terminal presentation.

Do not create a generic `AsyncResource<T>`, query cache, request registry, or loading service. Model selection, authentication, settings, future session browsing, and future history paging keep their own direct unions because their transitions and cancellation policies differ.

The existing `PromptWorkflow` operation/session identity is the reference implementation for terminal-owned asynchronous admission. Future history paging must use the same discipline in a transcript-specific state rather than extending `PromptStore`.

# 6. Custom renderables

Core OpenTUI renderables remain the default. A custom `FrameBufferRenderable` is admitted only when all of the following are true:

1. instrumentation identifies a repeatable frame-budget problem;
2. stable renderables, bounded projection, reduced assignments, and frame coalescing have already been attempted;
3. the hot region has a narrow painter contract that can be tested without the terminal application;
4. geometry, theme, and content cache invalidation can be stated explicitly;
5. cache memory has a hard bound;
6. the owner can restore renderer FPS/live state during disposal.

A custom painter must:

- precompute geometry only when dimensions change;
- compare input setters and request render only on change;
- avoid allocation in the per-frame cell loop;
- cache only when measured reuse pays for retained memory;
- cap continuous animation at 30 FPS unless evidence requires more;
- use `live: true` only while animation is active;
- separate pure painting from the renderable resource wrapper;
- include painter tests for geometry, invalidation, and bounds.

The transcript hot-path work explicitly does not meet this threshold. It must use stable `MarkdownRenderable`, `TextRenderable`, `BoxRenderable`, and `ScrollBoxRenderable` instances and their supported streaming/content setters.

# 7. Implementation slices

## Slice A — characterization and diagnostics

Files:

- `packages/tui/src/interactive/run.ts`
- `packages/tui/src/interactive/interactive-mode.ts`
- `packages/tui/src/interactive/screen.ts`
- `packages/tui/src/interactive/transcript/view.ts`
- `packages/tui/test/interactive/transcript-performance.test.ts`

Deliver:

- optional TTFD and renderer-stat diagnostics;
- transcript structural counters;
- tests fixing current output, native child order, identity churn, and notification bursts before behavior changes.

## Slice B — frame-coalesced stable transients

Files:

- `packages/tui/src/interactive/transcript/view.ts`
- `packages/tui/src/interactive/transcript/message-view.ts`
- `packages/tui/src/interactive/transcript/tool-view.ts`
- transcript tests

Deliver:

- one transcript subscription;
- one reconciliation per frame;
- stable streaming assistant root;
- keyed active-tool handles;
- bounded unresolved tool-call index;
- unchanged visual output.

## Slice C — bounded committed projection

Files:

- `packages/tui/src/interactive/transcript/view.ts`
- `packages/tui/test/interactive/transcript.test.ts`
- `packages/tui/test/interactive/visual-parity.test.ts`

Deliver:

- 200-message projection;
- omission marker;
- live eviction;
- detached anchor preservation;
- explicit selection behavior;
- hard retained-root assertions.

## Slice D — keymap migration when triggered

Files:

- root `package.json`
- `packages/tui/package.json`
- `packages/tui/src/interactive/interactive-keybindings.ts`
- `packages/tui/src/interactive/interactive-mode.ts`
- prompt/transcript views and keybinding tests

Deliver only after the adoption trigger occurs. Do not combine this slice with transcript reconciliation or history bounds.

## Slice E — owner-driven loads as capabilities arrive

Apply the loading rules in the feature introducing each concrete asynchronous catalog or page. Do not land an infrastructure-only abstraction.

# 8. Acceptance checklist

The complete transcript work is accepted when:

- [x] committed message renderables are created once and retained until bounded eviction or reset;
- [x] streaming text updates through a stable Markdown renderable;
- [x] tool siblings retain identity when one tool changes;
- [x] transcript reconciliation runs at most once per OpenTUI frame;
- [x] `collectToolCalls()` no longer scans the complete session on every delta;
- [x] `TranscriptView` has one interactive-store subscription for content changes;
- [x] retained committed message roots never exceed 200;
- [x] omitted history is visible and authoritative history remains untouched;
- [x] detached scrolling remains detached across append and eviction;
- [x] stale scheduled callbacks cannot mutate a replaced or destroyed screen;
- [x] visual parity tests pass at normal and constrained dimensions;
- [x] TTFD, native renderer statistics, and memory diagnostics can be enabled without changing normal behavior;
- [x] full workspace formatting, linting, typechecking, and tests pass;
- [x] no generic cache, event bus, custom painter, or framework layer was introduced by the transcript slices.

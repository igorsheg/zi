# ADR 0012: AgentSessionRuntime owns whole-session replacement

## Status

Accepted.

## Context

`AgentSession` owns one conversation and `SessionManager` owns one append-only journal. Neither can safely resume or create another session in place: the effective cwd determines `ZiPaths`, settings, resources, tools, shell ownership, and the model restored from the journal. Replacing only the journal would leave those owners bound to the previous cwd.

Pi separates the same responsibilities in `core/agent-session.ts`, `core/session-manager.ts`, and `core/agent-session-runtime.ts` at the repository pin in `docs/reference-pins.md`. Grok Build provides additional failure cases around strict resume, stale picker work, shadow sessions, cross-cwd restoration, torn JSONL appends, and large session catalogs. Pi remains the behavior and owner-decomposition reference; Grok Build is not a parity target.

## Decision

`AgentRuntime` remains the immutable SDK value for one session, its cwd-bound services, and any bootstrap diagnostic. The new `AgentSessionRuntime` is a narrow coding-agent owner used only when a client needs `/new` or `/resume`. It retains the original runtime construction policy, exposes the current `AgentSession`, services, and bootstrap diagnostic, and recreates a complete `AgentRuntime` for every replacement.

Its replacement state is explicit:

```text
ready(current)
  -> replacing(current, operation)
  -> cancelling(current, operation)
  -> ready(current)

replacing(current, operation)
  -> settling(next, operation)
  -> ready(next)

ready | replacing | cancelling | settling
  -> disposed(settlement)
```

Replacement is admitted only while the current session has no provider run, authentication, model mutation, or queued input. The target runtime is constructed and validated before the current session is invalidated. The old session is checked again immediately before commit so a concurrent prompt cannot be lost. Construction or pre-commit validation failure leaves the old runtime current and usable. After commit, cleanup failure is retained for the creator's final settlement boundary but does not leave the client bound to a disposed old session.

The runtime owns disposal of replaced and final sessions. Interactive mode may request replacement cancellation during terminal shutdown, but it never disposes the runtime. The CLI that creates the runtime performs final `dispose()` and a bounded `waitForIdle()` after terminal restoration.

`AgentSessionRuntime.listSessions()` is the authoritative current-cwd catalog operation. Calls are single-flight for one runtime and globally serialized across replacements, so a slow stale scan cannot multiply filesystem pressure. A queued scan is keyed to its admitted runtime, and runtime disposal joins the catalog tail. `SessionManager.list()` bounds directory candidates, inspected journals, preview bytes, concurrency, first-message text, and returned rows. It stats candidates first, reads only the newest bounded set, isolates invalid journals, and returns omission counts.

`/resume` follows the owner split used by Pi's selector/runtime host and Grok Build's slash-action/dispatch boundary without copying their frontend architectures. `SlashController` emits a closed `resume_session` intent. `InteractiveMode` adapts its caller-owned `AgentSessionRuntime` into narrow list/new/resume/cancel actions and is the only layer that applies a committed runtime session to `InteractiveStore`. `PromptStore` owns the transient `loading_sessions | choosing_session | resuming_session | cancelling_session` workflow and admitted session identity. `PickerStack` owns bounded rows, filtering, selection, and focus mechanics; renderables perform no filesystem or replacement work.

The TUI opens the picker before starting catalog I/O, loads only on demand, and rejects completion from a replaced session. Browsing is read-only and remains available during a provider run; selection still passes through runtime replacement admission. The current session remains visibly selected and choosing it is a no-op, following Grok Build's focus-existing policy rather than rebuilding an already-open session. Escape cancellation remains in `cancelling_session` until the runtime settlement resolves, so the composer cannot advertise readiness while candidate cleanup is still active. This milestone remains current-cwd only: Pi's all-project scope, rename/delete controls, and richer sorting, plus Grok Build's remote/content-search lanes, require separate authoritative owners and measured product pressure.

Strict resume and continue-recent remain distinct intents. Resume must open an existing journal. Continue-recent may prepare a new persisted session when the current cwd has no saved session. Bootstrap precedence and the pending-to-durable journal transition are defined in ADR 0016. Unprompted and response-less sessions never enter the catalog. A malformed unterminated final JSONL append is treated as a torn tail by both full loading and catalog preview; malformed completed records still invalidate the journal.

## Consequences

- Cross-cwd resume rebuilds every cwd-bound service from the stored session header.
- `AgentSession`, `SessionManager`, the TUI, and CLI do not acquire partial replacement responsibilities.
- Existing single-session SDK users continue to use `createAgentRuntime()` and caller-owned `session.dispose()`.
- `/new` and `/resume` compose the runtime through mode-owned typed actions; `PromptStore` owns only their transient workflow, and components only render picker state and native input.
- Zi does not add Grok Build's sidecar summaries, SQLite search, actor command bus, remote registry, leader process, or multi-session dashboard. A materialized catalog index requires measured pressure and its own source-of-truth decision.

# Interruption and terminal shutdown are distinct owner transitions

OpenZi separates run interruption, terminal exit gestures, terminal teardown, and final session disposal. They have different data-loss and resource-lifetime semantics and must not share an ambiguous `abort()` path.

`AgentSession` remains authoritative for active-run and queue transitions:

- `takeQueuedInputsAndAbort()` detaches pending input, enters `aborting`, signals the active agent, and returns both the detached input and the run settlement. Interactive Escape uses this operation so the composer can restore pending work.
- `abortAndDiscardQueuedInputs()` performs the same ordered cancellation but intentionally discards the detached input. Terminal shutdown uses this operation so queued work cannot continue after exit.
- `abort()` remains a lower-level interruption that preserves admitted queued work. It is not a shutdown operation.
- `dispose()` permanently closes the caller-owned session and remains the responsibility of the process layer that created it.

`InteractiveMode` owns the temporal clear/exit gesture as `ready` or `armed { pressedAt }`. `InteractiveKeybindings` maps Ctrl+C to `app.clear` by default. Native selection-copy and picker-back precedence consume that physical overlap and reset any earlier arm. Otherwise the first effective clear action clears the composer and arms a 500 ms window; the second requests exit. Ctrl+D requests exit only while the composer is empty. Escape remains cancellation, not exit.

`runTui` owns a closed `running | closing | closed` union. The first interactive exit, signal, or renderer-destroy request starts one shared close operation. It stops mode input, starts cancel-and-discard, clears the title, and destroys OpenTUI immediately. It then awaits session settlement with a five-second deadline after the alternate screen has been restored. Every concurrent close request joins the same completion. Shutdown failure is propagated only after terminal cleanup; the CLI then reports it and disposes the session in its existing `finally` boundary.

This follows Pi's double-Ctrl+C and Ctrl+D product semantics from `packages/coding-agent/src/modes/interactive/interactive-mode.ts` at `0e6909f0`. Renderer-destroy completion and scoped SIGHUP cleanup follow the proven OpenTUI application pattern in OpenCode's `packages/tui/src/app.tsx` at `cb8be9ba1`. OpenZi does not adopt either reference's framework architecture.

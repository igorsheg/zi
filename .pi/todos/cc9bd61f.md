{
"id": "cc9bd61f",
"title": "Harden TUI resume ownership and policy",
"tags": [
"sessions",
"tui",
"cli",
"architecture"
],
"status": "closed",
"created_at": "2026-07-16T14:11:52.655Z"
}

Remove the deprecated `--session` CLI alias. Re-review `/resume` against Pi and Grok Build, then tighten OpenZi's local owner composition, stale catalog bounds, no-op current selection, cancellation settlement state, torn-tail preview consistency, docs, and behavior tests without importing cross-project/remote/actor complexity.

## Implemented

- Removed `--session` parsing/help/docs and fixed rejection coverage; `--resume/-r` is the sole strict resume spelling.
- Recast the TUI boundary after reviewing Pi's selector/runtime host and Grok Build's slash-action/dispatch split: `InteractiveMode` now adapts `AgentSessionRuntime` to narrow list/new/resume/cancel actions and alone applies committed sessions; screens and `PromptStore` no longer receive the coding-agent runtime owner.
- Kept `PromptStore` as the transient workflow owner and added explicit `cancelling_session` settlement so Escape cannot expose false readiness or report the expected cancellation as an error.
- Made selecting the active session a no-op, retained current-path selection, allowed read-only browsing during a provider run, and kept replacement admission strict until idle.
- Globally serialized runtime-keyed catalog scans across replacements and joined the scan tail during runtime settlement, preventing stale generations from multiplying filesystem pressure.
- Made catalog preview and full open agree on malformed unterminated final records.
- Expanded ADR 0012, architecture, roadmap evidence, CLI/runtime/session-manager/prompt/TUI tests.

Verification: `bun run check` passes (135 coding-agent tests, 112 TUI tests, 20 CLI tests, 7 script tests).

{
"id": "ee1c5fbd",
"title": "Decompose imperative prompt presentation owners",
"tags": [
"tui",
"refactor",
"architecture",
"legibility"
],
"status": "closed",
"created_at": "2026-07-15T13:39:38.850Z"
}

Decomposed prompt presentation with direct typed composition and no event bus. Added ExitGestureController, PromptFeedbackView, QueuedInputsView, concrete cell-text truncation, and prompt picker-frame mapping. PromptView now owns only native input synchronization, semantic key precedence, and child lifetime. Browser opening moved behind feedback presentation with explicit request IDs, fixing repeated-URL login retries. PromptStore remains the single workflow-state owner. Updated architecture and added focused owner tests. `bun run check` passes: 67 coding-agent, 88 TUI, and 2 CLI tests.

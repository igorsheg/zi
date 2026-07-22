{
"id": "de201daa",
"title": "Keep Bash compact evidence stable on completion",
"tags": [
"tui",
"coding-agent",
"bash",
"ux"
],
"status": "closed",
"created_at": "2026-07-18T10:16:40.327Z"
}

Implemented completion-stable compact Bash evidence without transition memory or a new presentation contract.

- `projectBash()` now keeps tail 5 for successful completed commands with real output; empty success and background handoff remain compact-hidden; failures retain edges 2/3; detailed success remains bounded to 200 rows.
- `ToolCallView` derives whether the current semantic presentation has a compact body and keeps a secondary command visible when that evidence is visible. This remains generic layout behavior with no built-in dispatch or previous-frame state.
- The same terminal body root survives `running -> done`; only the no-longer-actionable foreground action row disappears.
- Added projector coverage for output success, empty success, and background handoff; added direct completed/restored rendering and lifecycle identity coverage; retained detailed row-bound coverage.
- Updated the implementation spec with the deterministic completion-continuity rule and Bash matrix.

Validation: targeted coding-agent/TUI tests, package typechecks, full `bun run check`, `git diff --check`, and `bun run build` pass. Rebuilt `dist/zi`.

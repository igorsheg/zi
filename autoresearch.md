# Autoresearch: Builtin Tool Parity

## Objective
Close the remaining builtin-tool behavior and UX gaps against the acceptance criteria in `docs/tool-parity-acceptance.md`, while keeping Zi idiomatic Zig 0.16, grug-brained, and Tiger Style: simple boundaries, explicit ownership, bounded resources, and tested behavior.

The workload is the current Zi tool parity implementation. Each iteration should reduce the count of acceptance gaps detected by `autoresearch.sh` without regressing build/test/lint gates.

## Metrics
- **Primary**: gaps_remaining (count, lower is better) — static acceptance checks still failing.
- **Secondary**: test_status, build_status, lint_status — tradeoff/correctness monitors; 0 means pass, 1 means fail.

## How to Run
`./autoresearch.sh` — outputs `METRIC name=value` lines.

## Files in Scope
- `src/coding_agent/tools/*.zig` — builtin tool behavior, output contracts, bounded accumulation, path policy use.
- `src/coding_agent/tool_output_policy.zig` — shared bounded output/truncation contracts.
- `src/coding_agent/tool_registry.zig` — builtin tool metadata and prompt snippets.
- `src/coding_agent/interactive.zig` — agent-event to neutral TUI transcript translation only when needed.
- `src/tui/product/*.zig`, `src/tui/primitive/*.zig` — only for neutral transcript/chrome behavior; no agent/tool imports.
- `docs/tool-parity-acceptance.md` — acceptance criteria and explicitly deferred gaps.
- `autoresearch.md`, `autoresearch.sh`, `autoresearch.checks.sh`, `autoresearch.ideas.md` — session files.

## Off Limits
- Do not move tool policy into `src/runtime`.
- Do not import coding-agent/agent/ai/runtime concepts into `src/tui`.
- Do not add broad generic frameworks without a second concrete owner.
- Do not vendor or port pi-mono/libvaxis/ZigZag wholesale.
- Do not weaken path containment, output bounds, mutation queue ownership, or UTF-8 safety.

## Constraints
- Gates must pass before keeping a change: `zig build test`, `zig build`, `ziglint`, `zig fmt --check src`.
- Every new resident buffer/traversal/diff/output must have a named cap and tested overflow behavior.
- File mutation remains through `FileMutationQueue`.
- Operational file/tool input degrades or reports; owner loops must not crash.
- Keep changes Zi-owned and minimal.

## What's Been Tried
- Bash parity mostly closed: explicit env, shell path, command prefix, bounded OutputAccumulator, interleaved output, truncation metadata, timeout/cancel/nonzero classification.
- TUI tool chrome aligned with open-box design and segmented styles.
- Tool output ANSI/control sanitization added at transcript ingestion.
- Path normalization batch implemented: shared existing/creatable resolution, `@` stripping, Unicode-space mapping, canonical containment, symlink escape tests.
- Observational/listing/search batches partially implemented: ls/find/grep defaults, limits, no-match messages, deterministic sorting for collected results, `.git`/`node_modules` ignore policy, grep long-line and invalid-UTF-8 handling.
- Current next high-ROI target: Batch 2 edit/write UX — CRLF/BOM matching/restoration, no-op edit rejection, actionable errors, bounded diff/details metadata.

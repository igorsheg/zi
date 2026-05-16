# Autoresearch: TUI editor/text layout throughput

## Objective
Optimize TUI editor and plain-text visual layout throughput by removing redundant display-width scans and allocation churn in wrapping/layout paths.

## Metrics
- Primary: `layout_ms` (milliseconds, lower is better)
- Secondary: `edit_lines`, `text_lines` — rendered/wrapped line counts used as correctness/tradeoff monitors

## How to Run
`./autoresearch.sh` — outputs `METRIC layout_ms=...`, `METRIC edit_lines=...`, and `METRIC text_lines=...`.

## Files in Scope
- `src/tui/edit/layout.zig` — editor visual-line wrapping/layout.
- `src/tui/text/layout.zig` — reusable text layout wrapping and viewport helpers.
- `src/tui/wrap/breaks.zig` — shared segment wrapping primitive.
- `src/tui/wrap/display.zig` — display word wrapping primitive if benchmark evidence points there.
- `src/tui/grapheme.zig` — width helpers only for isolated safe fast paths.
- `src/tui_edit_layout_bench.zig` — temporary benchmark workload.
- `autoresearch.sh`, `autoresearch.checks.sh`, `autoresearch.md`, `autoresearch.ideas.md`, `autoresearch.jsonl` — experiment artifacts.

## Off Limits
- Provider/network code under `src/ai/`.
- Agent loop behavior under `src/agent/`.
- Durable session format and storage behavior.
- Extension public API semantics.

## Constraints
- Preserve editor cursor/layout semantics and text wrapping behavior.
- `zig build test` must pass.
- Avoid broad rewrites. Prefer isolated hot-path changes.
- No external dependencies.
- Benchmark must stay deterministic and compact.

## What's Been Tried
- Baseline workload added in `src/tui_edit_layout_bench.zig`.

# Autoresearch: TUI render throughput

## Objective
Optimize TUI markdown/transcript wrapping and rendering throughput for large assistant messages. The workload constructs a large markdown assistant response, repeatedly measures and renders it through the retained Markdown component, and reports median runtime.

## Metrics
- Primary: `render_ms` (milliseconds, lower is better)
- Secondary: `rows` — rendered row count, used as a correctness/tradeoff monitor

## How to Run
`./autoresearch.sh` — outputs `METRIC render_ms=...` and `METRIC rows=...`.

## Files in Scope
- `stui/wrap/` — text wrapping segment and display-width logic.
- `stui/markdown/` — markdown parse/render into spans and rendered lines.
- `stui/transcript/` — retained transcript Markdown layout and assistant message rendering.
- `stui/components/text.zig` — plain text rendering if benchmark evidence points there.
- `stui/primitives/` — surface/layout primitives only when directly required by render path.
- `src/tui_render_bench.zig` — benchmark workload.
- `autoresearch.sh`, `autoresearch.checks.sh`, `autoresearch.md`, `autoresearch.ideas.md`, `autoresearch.jsonl` — experiment artifacts.

## Off Limits
- Provider/network code under `src/ai/`.
- Agent loop behavior under `src/agent/`.
- Durable session format and storage behavior.
- Extension public API semantics.

## Constraints
- Preserve visible wrapping/markdown output semantics.
- `zig build test` must pass.
- Avoid broad rewrites. Prefer isolated hot-path changes.
- No external dependencies.
- Benchmark must stay deterministic and compact.

## What's Been Tried
- Baseline workload added in `src/tui_render_bench.zig`.

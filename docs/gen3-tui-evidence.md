# Gen-3 TUI evidence checklist

P5 parity audit for `docs/gen3-tui-plan.md` §2.2.

| Behavior | Evidence |
|---|---|
| B1 assistant text streams live markdown | `Transcript.zig` test "transcript applies streamed assistant text by delta"; pty e2e "streamed markdown renders, escape aborts, and ctrl-c exits" |
| B2 thinking visibility and relayout | `Loop.zig` test "loop thinking relayout preserves anchored item"; `Loop.zig` test "loop P4 settings thinking visibility persists through services" |
| B3 tool block appears on streamed toolcall | `Transcript.zig` test "transcript creates tool before execution and records output" |
| B4 tool status tint lifecycle | `Transcript.zig` test "transcript creates tool before execution and records output"; `chrome.zig`/`blocks.zig` rendering tests |
| B5 running tool tail and elapsed/done timing | `blocks.zig` test "tail buffer keeps the last five normalized lines"; pty e2e "P3 viewport rebuild and resize storm" synthetic tools check |
| B6 ESC abort | `Loop.zig` test "run cancel restores queued text into empty editor"; `RunHandle.cancellationOutstanding` drives truthful status when cancellation spans an iteration; pty e2e "streamed markdown renders, escape aborts, and ctrl-c exits" |
| B7 tool expand/collapse | `Loop.zig` test "loop collapsed tool body ending newline has no blank before marker" |
| B8 typing during streaming and steer/follow-up | `Loop.zig` test "agent run queues steering and dequeue-all restores queued text" |
| B9 queued steering/follow-up display and Alt+Q | `Loop.zig` test "agent run queues steering and dequeue-all restores queued text" |
| B10 ESC cascade | `Loop.zig` centralized picker, foreground-operation, retry/compaction, and active-run cancellation paths; pty e2e abort coverage |
| B11 Ctrl+C/Ctrl+D exit | `Loop.zig` test "loop clear_or_quit clears first then exits"; the concrete `Loop.step` input path and pty exit coverage |
| B12 virtual scrollback | `Loop.zig` tests "loop viewport anchors while appended lines arrive", "loop viewport clamps to oldest live item after eviction", and "loop submit repins viewport to follow" |
| B13 slash command dispatch | `Loop.zig` test "loop slash help appends a notice"; `slash_commands.zig` dispatch tests |
| B14 slash/file completion popup | `Loop.zig` test "loop P4 file completion popup accepts selected candidate" |
| B15 model/session pickers | `Loop.zig` concrete background session-listing/opening state and test "loop P4 model picker applies faux model through services"; pty e2e "P4 completion model picker resume and new session" |
| B16 session restore fold | `Loop.zig` bounded `restoreEntriesStep`, test "loop P4 restore fold renders durable user tool and assistant transcript", and restore-work trace counters |
| B17 compaction | `AgentSession.zig` tests "agent session auto compaction summarizes persists and replaces context", "overflow settle starts compaction and arms the resubmit retry" |
| B18 auto-retry | `AgentSession.zig` tests "settle verdict arms backoff retry and repairs the runtime transcript", "settle verdict fails after exhausted attempts with terminal retry end" |
| B19 working status | `Loop.zig` agent-run faux session coverage and pty streaming e2e |
| B20 footer context/token stats | `Loop.zig` test "loop P4 header footer cache assistant usage" |
| B21 thinking-level editor border | `chrome.zig` test "chrome renders bordered editor with supplied border style"; `Loop.zig` border mapping in P2/P4 frame tests |
| B22 `/settings thinking:*` | `slash_commands.zig` test "slash dispatch maps settings actions"; `Loop.zig` test "loop P4 settings thinking visibility persists through services" |
| B23 terminal title | Code-review evidence: `src/tui/root.zig` sets the initial title and applies `Loop.takePendingTitleUpdate()` after restore/session switch; covered by P4 full gates. |
| B24 resize | concrete `Loop.step` resize handling; pty e2e "P3 viewport rebuild and resize storm" |
| B25 exit hygiene | `Terminal.zig` test "terminal setup and shutdown are idempotent"; pty e2e termios assertions; panic restore via `main.zig` panic handler; pty e2e "undrained shutdown restores terminal and exits failure" proves the five-second fatal escalation |
| B26 large paste marker | `Editor.zig` tests "editor collapses and expands large paste markers" and "editor treats paste marker as one cursor unit" |
| B27 editor behavior | `chrome.zig` shared visual-row cursor targeting tests for hard/soft wraps, Unicode, and paste markers; `Loop.zig` test "loop vertical editor actions traverse visual rows before history"; `Editor.zig` grapheme/delete/history/kill/undo tests |
| B28 explicit out-of-scope list | Preserved in `docs/gen3-tui-plan.md` §2.2 |

Additional P5 evidence:

- Print text/json: `print_mode.zig` tests "print mode streams text deltas" and "print mode writes json events".
- CLI print wiring: `cli/root.zig` test "cli text and json print frontends run through faux provider".
- T11 real provider resolution carrier: pty e2e "P5 print json faux provider" with `ZI_ENABLE_FAUX_PROVIDER=1 zi -p --mode json hi`.
- Input fuzz: `InputDecoder.zig` test "decoder fuzz random byte streams stay bounded".
- Dumb terminal hardening: `cli/root.zig` test "cli refuses TUI on dumb terminal with print hint".
- Theme env hardening: `theme.zig` test "terminal info resolves light theme from environment".
- Perf/trace gate: pty e2e "synthetic flood trace meets P2 gate three times".

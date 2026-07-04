# Phase 0 TUI trace baselines

Run from the repo root:

```sh
scripts/capture_baselines.sh
```

The script builds `zig-out/bin/zi`, runs the headless scenarios through a PTY with
`ZI_TUI_TRACE=1`, and copies the emitted trace reports here.

## Captured headlessly

| Scenario | Trace file | Driver |
|---|---|---|
| `/resume` of a multi-MB session | `resume-multimb.trace` | Generated jsonl session under a temp `ZI_CODING_AGENT_DIR`, opened with `zi --session <file>`, then exited. |
| 17KB paste | `paste-17kb.trace` | Bracketed paste into a fresh TUI session, then double Ctrl-C exit. |
| Faux prompt stream | `prompt-stream-faux.trace` | Temp `settings.json` selects `faux`/`faux-default`, `ZI_ENABLE_FAUX_PROVIDER=1`, prompt typed through the real TUI, scripted response asserted in terminal output. |
| Assistant flood | `assistant-flood.trace` | Automated with `ZI_FAUX_SCRIPT`; capped at 16,128 bytes because the faux provider uses a 256-event buffered stream (252 64-byte text deltas + start/text-start/text-end/done). |

## Manual capture required

These require a real interactive terminal and/or tool-call/scroll paths that the
plain-text faux script does not cover.

### Chatty bash tool

1. Build: `zig build`.
2. Start: `ZI_TUI_TRACE=1 zig-out/bin/zi`.
3. Use an authenticated provider/model.
4. Prompt: `Run a bash command that prints 2000 numbered lines, then summarize it in one sentence.`
5. Wait for the tool and assistant response to finish, then exit.
6. Copy the emitted trace to `docs/baselines/chatty-bash-tool.trace`.

### Scroll during stream

1. Build: `zig build`.
2. Start: `ZI_TUI_TRACE=1 zig-out/bin/zi` in a real terminal.
3. Use an authenticated provider/model.
4. Prompt a long streaming answer, for example: `Write a long numbered list with 5000 short items.`
5. While output is streaming, repeatedly scroll up/down with the normal TUI keys or mouse.
6. Exit after completion and copy the emitted trace to `docs/baselines/scroll-during-stream.trace`.

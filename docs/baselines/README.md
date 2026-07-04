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

## Manual capture required

These require a real interactive terminal and/or a streaming provider path. The
current CLI registers only real providers; the faux provider exists for tests but
is not exposed to the TUI without a source change, so the script does not fake
these baselines.

### 1MB assistant flood

1. Build: `zig build`.
2. Start a real TUI with tracing: `ZI_TUI_TRACE=1 zig-out/bin/zi`.
3. Use an authenticated provider/model.
4. Prompt: `Write exactly 1 MiB of plain text in small chunks. No markdown.`
5. Wait for completion, then exit with Ctrl-D on an empty composer.
6. Copy the path printed as `zi tui trace: ...` to `docs/baselines/assistant-flood-1mb.trace`.

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

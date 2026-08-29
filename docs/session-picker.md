# Interactive session picker

## Product contract

Zi follows hax v0.4.0 behavior at the revision recorded in `THIRD_PARTY_NOTICES.md`.
Bare `zi --resume` opens a normal-buffer picker for sessions in the current working directory.
It never starts providers before selection. Cancellation, non-TTY use, and picker setup failure exit
successfully. An empty list prints `no past conversations in this directory` and exits successfully.

The picker shows at most the newest 200 sessions. Rows use the first typed prompt, relative file age,
opening provider/model/effort/preset, and opening Git branch/subject. Filtering matches every
space-separated term against the prompt with ASCII case folding. Enter accepts. Escape, Ctrl-C,
Ctrl-G, EOF, and input failure cancel. Arrow keys, Ctrl-N/Ctrl-P, Home/End, and Page Up/Page Down
navigate without wrapping.

## Ownership and layering

- `terminal` owns the reusable picker state machine, raw input, normal-buffer repaint, geometry, and
  terminal restoration. Picker text and items are borrowed synchronously. Match indexes, query bytes,
  and paint buffers are bounded and picker-owned.
- `persistence` owns bounded session-label decoding. The result owns prompt and opening provenance.
- `cli` owns session-row assembly and process admission. It checks both TTYs, limits rows to 200,
  installs fatal-signal restoration before raw mode, and transfers the selected indexed session into
  `SessionStartup.Resolved`.
- `SessionIndex` remains filesystem indexing. `SessionStartup` remains session resolution and ownership
  transfer. Neither imports terminal code.
- ZigAI commit `e2c5aef5f93015322891028a2048a217e7081687` is the Zig 0.16 posture reference: explicit
  `std.Io`, allocator-owned results, bounded work, tagged states, and testable reader/state splits.

## Program shape

```text
PrintRun.run
  SessionStartup.resolve
    .select -> Candidates
  SessionPicker.run(Candidates.entries)
    SessionLabel.read for newest 200
    terminal.Picker.run
      PickerCore filter/navigation
      PosixMode prompt_edit
      normal-buffer paint/read/erase
  Candidates.resolve(selected_index)
  existing StartupConfig and SessionStartup.start flow
```

```text
src/
  terminal/
    PickerCore.zig       # pure bounded filter/navigation state
    Picker.zig           # raw terminal owner and normal-buffer renderer
  persistence/
    SessionLabel.zig     # 64 KiB opening-label reader
  cli/
    SessionPicker.zig    # session-specific rows and selection
```

## Slices and checks

1. Generic picker core and terminal runner
   - filtering, navigation, clipping, resize layout, bounded query, terminal cleanup tests
   - no alternate-screen sequence
2. Session labels and candidate ownership
   - opening selection only, first external prompt, compacted/no-preview fallbacks, age/provenance
   - newest 200 cap and selected-index ownership transfer
3. Startup integration
   - non-TTY, empty, cancellation, and successful selection behavior
   - PTY probes for selection, cancellation, normal-buffer output, and termios restoration

Every major slice must pass targeted tests, `ziglint`, and `git diff --check`. The final slice must pass
the complete ready gate from `AGENTS.md`.

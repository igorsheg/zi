# TUI review punch list

`src/tui/` was rewritten from scratch (2026-06-13, branch `alpha`) on the
shapes the original review called load-bearing: the pure `App.apply(Command)
-> ?Effect` core, the single terminal-byte authority (`tui.Terminal`), and one
row producer shared by scroll accounting and drawing. Delete this file when it
empties.

## Resolved by the rewrite

- **Typed/pasted input can crash the TUI** — `apply` is now total over
  operational input: composer overflow degrades to one coalesced warning
  notice, invalid UTF-8 is sanitized on ingest, only OutOfMemory propagates.
  Pinned by App tests.
- **Idle owner loop ticks 60/s forever** — the frame timer is animation-gated
  (16ms only while a shimmer is live, 30s heartbeat otherwise), and the ctrl+c
  double-press window is wall-clock ms carried by `Command.tick`; App never
  reads a clock.
- **Dead `generated_buffer` plumbing / use-after-overwrite class** — gone.
  Generated row text (tool titles, hints, omission notices) is interned into
  the heap-pinned draw scratch (`render.RowScratch`), so no row ever borrows a
  dead stack buffer. The first test run of the rewrite caught exactly this bug.
- **Vaxis seam spread over 10 files** — `theme.zig` aliases `Style`/`Color`;
  vaxis is imported only by `Terminal.zig`, `render.zig`, `input.zig`,
  `text.zig`, `theme.zig`.
- **~300 KB of per-frame stack arrays** — rows draw directly from the sink;
  the one per-item scratch lives in the heap-pinned Terminal.
- **Per-tool preview cap exceeded the transcript budget** — tool previews cap
  at 1/8 of a 256 KB total (`Transcript.tool_preview_bytes_max`).
- **O(whole-transcript re-wrap) per streamed delta** — per-item row counts
  memoize in `Transcript.Item.layout` keyed by (item version, width,
  expanded); scroll math is O(items), drawing is O(viewport) with item-granular
  scroll skip.
- **Keymap gaps (partial)** — newline-in-composer wired (alt+enter / ctrl+j),
  delete-forward wired, enter inside a bracketed paste inserts a newline
  instead of submitting; multibyte codepoints split across streamed deltas are
  carried and rejoined.
- **Dead product surface** — Confirm modal/surfaces, slot machinery's heap
  allocations, `replace_tool_call_preview`/`call_preview`, and the unused
  snapshot test helper are deleted; status contributions are allocation-free
  inline storage.

## Resolved after the rewrite

- **Composer up/down movement and prompt history** — arrow up/down first move
  through wrapped visual rows, then recall bounded App-owned prompt history at
  the composer boundary. Draft text is restored when walking back down past the
  newest history entry.

## Still open

- [ ] **Verify bracketed paste end-to-end in a real terminal.** The mechanism
  changed (paste-mode enter -> newline; content flows as key events), but none
  of it has been exercised against a real terminal emulator. Pasting a file
  path or code block into the prompt is day-one dogfooding; test it first,
  fix what falls out.

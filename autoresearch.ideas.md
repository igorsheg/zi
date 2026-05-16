# Autoresearch Ideas

- Use `segment.width_cols` in `src/tui/edit/layout.zig` instead of recomputing `strWidth`.
- Reuse segment width in logical column advancement when skipped whitespace does not affect editor semantics.
- Preallocate editor virtual lines based on byte length and width.
- Preallocate text layout line arrays for char/word wrapping paths.
- Add ASCII fast paths to viewport offset helpers if measurable.

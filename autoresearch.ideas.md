# Autoresearch Ideas

- Avoid repeated full-string display-width scans in `src/tui/wrap/breaks.zig`.
- Cache span widths during markdown render-to-layout conversion.
- Add ASCII fast path for wrapping and display width.
- Reduce transient `ArrayListUnmanaged` allocations while building layout rows.

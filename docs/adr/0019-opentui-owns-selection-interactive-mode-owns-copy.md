# OpenTUI owns selection; interactive mode owns explicit copy delivery

Zi delegates native text ranges, mouse dragging, editor selection, visual highlighting, cross-renderable reading order, and selected-text extraction to OpenTUI. The TUI does not mirror a range or selected text in a store and does not build a second scrollback selection model.

Copy remains an explicit product action. Completing a mouse selection never changes the clipboard. The mode-owned `app.selection.copy` binding defaults to Cmd+C then Ctrl+C on macOS and Ctrl+C elsewhere. Cmd+C works when the terminal forwards the Super modifier; Ctrl+C remains the portable fallback because terminal emulators may reserve Command shortcuts. A copy binding with no non-empty native selection falls through, preserving Ctrl+C clear/exit behavior.

`InteractiveMode` creates one `SelectionCopyController` before screen key handlers. It reads the current OpenTUI selection only when the semantic copy action arrives, consumes that key ahead of prompt and picker actions, resets any armed exit gesture, and owns `idle | writing | disposed`. A newer copy aborts the prior write. Completion clears the selection only when both its native selection identity and selected text still match; failure or stale completion leaves the current selection untouched. Screen components contain no screen-wide copy policy.

The terminal clipboard boundary has separate `ClipboardReader` and `ClipboardWriter` contracts because reads admit image-or-text prompt input while writes deliver bounded text. `SystemClipboardWriter` admits at most 4 MiB of UTF-8, attempts OpenTUI's terminal-aware OSC 52 route and a bounded local native writer, and returns `copied | unavailable | too_large`. Native subprocesses have a three-second deadline, receive input directly rather than through shell interpolation, and fall back through platform tools. SSH sessions skip remote-host native clipboards and rely on OSC 52 toward the user's terminal. Every in-flight subprocess follows the controller's abort signal.

This keeps the useful parts of the references without importing their architectures:

- OpenTUI `0c8c4f7c` remains the selection engine and owns tmux/Screen-aware OSC 52 emission.
- OpenCode `4678bd104` demonstrates app-level selection precedence and dual native/OSC 52 delivery; Zi rejects its default copy-on-mouse-up policy and unbounded subprocess path.
- Grok Build `98c3b243` demonstrates explicit delivery outcomes, remote-aware routing, bounds, and stale selection protection; Zi does not need Grok's custom Ratatui selection geometry, persistent range projection, or timer-driven highlight state.

# Interactive mode owns instance-scoped semantic keybindings

Terminal product behavior binds to semantic actions, not physical key checks distributed through components. `InteractiveMode` constructs and owns one immutable `InteractiveKeybindings` instance for its lifetime and injects it into the prompt and transcript owners.

`InteractiveKeybindings` owns:

- the closed built-in action IDs used by the current terminal mode;
- default key IDs and descriptions;
- validated, normalized per-mode overrides, including explicit disablement;
- effective key lookup and display hints;
- conflicts among user overrides;
- whether a built-in action is reserved from or overridable by a future extension shortcut;
- translation of OpenTUI `KeyEvent` values into closed prompt and transcript actions.

It contains no action callbacks and executes no session operation. `InteractiveMode` retains temporal exit-gesture state and application composition. `SelectionCopyController`, `PromptView`, and `TranscriptView` apply the returned closed actions to their concrete native resources and stores. OpenTUI continues to own ordinary textarea editing, cursor movement, focus, selection, and scrolling mechanics.

Context resolves intentional overlap. The mode-level `app.selection.copy` action precedes screen handlers only when OpenTUI has a non-empty native selection; otherwise Ctrl+C falls through to clear/exit and a delivered Cmd+C remains inert. Picker actions precede prompt actions; empty-editor exit falls through to OpenTUI delete behavior when text exists; unsupported modified submit/navigation keys are consumed while a picker is active. `tui.input.historyPrevious` and `tui.input.historyNext` default to Up and Down, intentionally overlap picker selection bindings, and are exposed only for the idle, picker-free prompt. Their actions preserve native vertical movement until Composer reaches a visual buffer boundary. `app.editor.external` and `app.task.background` intentionally default to Ctrl+G: an active foreground task takes precedence, otherwise an idle prompt opens the external editor. Non-idle workflows, including secret authentication input, cannot launch it. Visible queue and transcript hints are derived from the effective bindings.

`InteractiveMode` owns one `SystemExternalEditor` for its lifetime. It admits one editor and at most 1 MiB of draft content, suspends OpenTUI before lending inherited terminal streams to its owned child process, uses a private temporary `prompt.md`, restores the renderer on every settlement, and rejects stale prompt-view completion after screen replacement or disposal. Disposal restores the terminal immediately, asks the child to stop, and force-kills it after a one-second grace period. The editor receives Composer's expanded text and successful exit replaces the native draft without moving draft authority into a store. Command resolution is captured by `SettingsManager` and follows Pi's precedence: effective `externalEditor` setting, `$VISUAL`, `$EDITOR`, then `notepad` on Windows or `nano` elsewhere.

Future extension shortcuts remain with their concrete coding-agent extension owner. That owner will expose validated shortcut entries and invocation; the terminal mode will compare them with the effective built-in catalog and its reserved policy before dispatch. Extensions do not mutate `InteractiveKeybindings`, append open action IDs, or register callbacks inside components.

Pi uses the same responsibility split at `0e6909f0`: `packages/coding-agent/src/core/keybindings.ts` defines semantic IDs, defaults, overrides, migration, and conflicts; `InteractiveMode` owns one effective manager; `CustomEditor` applies contextual precedence; and `ExtensionRunner.getShortcuts()` protects reserved bindings and reports conflicts. External-editor behavior was refreshed from Pi at `8eef62ed`: `app.editor.external` defaults to Ctrl+G, settings resolve the editor command with the precedence above, and `editInExternalEditor()` lends the terminal to an inherited-stdio child over a temporary Markdown file. Zi keeps the keybinding owner in `packages/tui`, deliberately rejects Pi TUI's mutable global manager, and uses OpenTUI's native suspend/resume lifecycle instead of Pi TUI's stop/start calls.

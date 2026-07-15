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

It contains no action callbacks and executes no session operation. `InteractiveMode` retains temporal exit-gesture state and application composition. `PromptView` and `TranscriptView` apply the returned closed actions to their concrete native resources and stores. OpenTUI continues to own ordinary textarea editing, cursor movement, focus, selection, and scrolling mechanics.

Context resolves intentional overlap. Native selection copy precedes picker cancellation; picker actions precede prompt actions; empty-editor exit falls through to OpenTUI delete behavior when text exists; unsupported modified submit/navigation keys are consumed while a picker is active. Visible queue and transcript hints are derived from the effective bindings.

Future extension shortcuts remain with their concrete coding-agent extension owner. That owner will expose validated shortcut entries and invocation; the terminal mode will compare them with the effective built-in catalog and its reserved policy before dispatch. Extensions do not mutate `InteractiveKeybindings`, append open action IDs, or register callbacks inside components.

Pi uses the same responsibility split at `0e6909f0`: `packages/coding-agent/src/core/keybindings.ts` defines semantic IDs, defaults, overrides, migration, and conflicts; `InteractiveMode` owns one effective manager; `CustomEditor` applies contextual precedence; and `ExtensionRunner.getShortcuts()` protects reserved bindings and reports conflicts. OpenZi keeps the owner in `packages/tui` because terminal behavior is frontend-specific, and deliberately rejects Pi TUI's mutable global keybinding singleton.

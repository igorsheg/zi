# Terminal interactive mode owns frontend orchestration

> Amended by [ADR 0007](0007-terminal-interactive-mode-over-agent-session.md), [ADR 0008](0008-composer-owned-picker-stack.md), [ADR 0009](0009-interruption-and-terminal-shutdown.md), and [ADR 0010](0010-interactive-mode-owns-keybindings.md): `AgentSession` is the shared core, `InteractiveMode` is terminal-specific, nested choice presentation uses the composer-owned picker stack, interruption is distinct from shutdown, and terminal actions use instance-scoped semantic keybindings.

Pi's `interactive-mode.ts` combines terminal product behavior with terminal rendering while delegating coding-agent policy to `AgentSession`. OpenZi keeps the same owner boundary using imperative OpenTUI:

```text
AgentSession and concrete managers
  -> terminal InteractiveMode
      -> session-screen composition
          -> imperative OpenTUI components
```

`AgentSession` remains authoritative for persistence, model and thinking changes, queues, cancellation, provider work, and durable messages. `packages/tui/src/interactive/interactive-mode.ts` owns the current session subscription, transient tool presentation, the semantic keybinding instance, command/selector admission, focus, session replacement, and terminal resources.

The interactive store delegates prompts and Escape cancellation with queue restoration to its current `AgentSession`; it does not recreate those policies. `runTui` calls the separate cancel-and-discard operation during terminal shutdown. Generic `Composer` and `PickerList` components may not encode supported commands or session behavior.

Pi splits slash commands by responsibility. Coding-agent owners expose command descriptors: the immutable built-in catalog lives in `core/slash-commands.ts`, extension commands live in `ExtensionRunner`, and prompt/skill commands live with session resources. Pi's terminal `InteractiveMode` assembles those descriptors for completion and parses/dispatches built-in invocations; its editor owns only completion mechanics.

OpenZi follows that split. `packages/coding-agent/src/slash-commands.ts` owns descriptors for supported built-ins. The terminal `InteractiveMode` owns one `SlashController`, which retains a bounded current-session descriptor projection, fuzzy-ranks command names, produces range-safe composer edits, and parses invocations into closed command intents without retaining active picker state. `PromptStore` receives those typed edits or intents and owns the resulting prompt/selector workflow. `PromptView`, `Composer`, and `PickerList` contain no command names, argument syntax, descriptions, or dispatch policy.

The first `/model` slice calls existing `AgentSession` catalog and mutation operations, expresses choice presentation as `PickerStack` frames beneath the always-focused composer, and rejects async completion after cancellation, supersession, disposal, or session replacement. Extension/template/skill catalogs will remain with their concrete coding-agent owners and join the terminal aggregate only when those capabilities exist. OpenZi will not introduce an application-wide command bus or generic state-machine framework.

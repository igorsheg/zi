# Terminal interactive mode owns frontend orchestration

> Amended by [ADR 0007](0007-terminal-interactive-mode-over-agent-session.md) and [ADR 0008](0008-composer-owned-picker-stack.md): `AgentSession` is the shared core, `InteractiveMode` is terminal-specific, and nested choice presentation uses the composer-owned picker stack.

Pi's `interactive-mode.ts` combines terminal product behavior with terminal rendering while delegating coding-agent policy to `AgentSession`. OpenZi keeps the same owner boundary using imperative OpenTUI:

```text
AgentSession and concrete managers
  -> terminal InteractiveMode
      -> session-screen composition
          -> imperative OpenTUI components
```

`AgentSession` remains authoritative for persistence, model and thinking changes, queues, cancellation, provider work, and durable messages. `packages/tui/src/interactive/interactive-mode.ts` owns the current session subscription, transient tool presentation, editor key semantics, command/selector admission, focus, session replacement, and terminal resources.

The interactive store delegates prompts, queue restoration, and abort to its current `AgentSession`; it does not recreate those policies. Generic `Composer` and `PickerList` components may not encode supported commands or session behavior.

Pi splits slash commands by responsibility. Coding-agent owners expose command descriptors: the immutable built-in catalog lives in `core/slash-commands.ts`, extension commands live in `ExtensionRunner`, and prompt/skill commands live with session resources. Pi's terminal `InteractiveMode` assembles those descriptors for completion and parses/dispatches built-in invocations; its editor owns only completion mechanics.

OpenZi follows that split. `packages/coding-agent/src/slash-commands.ts` owns descriptors for supported built-ins. The terminal `InteractiveMode` owns `InteractiveCommands`, which assembles completion candidates and parses invocations into closed command intents. `PromptStore` receives those typed intents and owns the resulting prompt/selector workflow. `PromptView`, `Composer`, and `PickerList` contain no command names, argument syntax, descriptions, or dispatch policy.

The first `/model` slice calls existing `AgentSession` catalog and mutation operations, expresses choice presentation as `PickerStack` frames beneath the always-focused composer, and rejects async completion after cancellation, supersession, disposal, or session replacement. Extension/template/skill catalogs will remain with their concrete coding-agent owners and join the terminal aggregate only when those capabilities exist. OpenZi will not introduce an application-wide command bus or generic state-machine framework.

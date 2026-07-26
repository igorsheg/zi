# ADR 0016: Session bootstrap separates preferences, context, and durability

## Status

Accepted.

## Context

A session starts from three different authorities: layered settings describe user preferences, an opened journal describes conversation context, and runtime arguments describe explicit invocation overrides. Treating journal metadata as a settings overlay obscures precedence, prevents fallback when a saved model is unavailable, and makes a planned session file look durable before a conversation exists.

Pi keeps these concerns separate in `core/sdk.ts`, `core/model-resolver.ts`, `core/settings-manager.ts`, and `core/session-manager.ts` at the pinned revision in `docs/reference-pins.md`.

## Decision

`SettingsManager` loads Pi-shaped model preferences from global and project `settings.json`:

- `defaultProvider`
- `defaultModel`
- `defaultThinkingLevel`

Global settings load first, project settings override them, and construction overrides remain invocation-local. Session metadata never enters `SettingsManager`.

`createAgentRuntime()` admits one closed session intent—new with an explicit persistence choice, continue recent, or resume an exact file—and snapshots mutable invocation inputs before asynchronous work. `createAgentSession()` owns bootstrap after runtime construction has selected the journal, cwd-bound services, and optional explicit model. It classifies the journal directly:

```text
new(context with no messages)
resumed(context with messages)
```

Model selection follows one precedence path:

1. an explicit runtime model;
2. the resumed journal model, when still known and configured;
3. the configured settings default;
4. Pi's ordered provider defaults;
5. the first model from a configured provider;
6. explicit `unselected` state when none is available.

The journal model is derived from both `model_change` entries and assistant message metadata. An unavailable journal or settings model is a preference miss, not a terminal resolution result. `createAgentSession()` returns the session plus an optional structured bootstrap diagnostic. A missing resumed model records the saved model and either the selected fallback or the absence of any configured model; runtime and clients present that diagnostic on initial startup and session replacement.

Thinking selection follows:

1. an explicit runtime thinking level;
2. the resumed journal level;
3. `defaultThinkingLevel`;
4. Pi's `medium` default.

The result is clamped to the selected model and becomes `off` without a model. Runtime thinking belongs to `AgentSession`; settings retain the user's default rather than mirroring a model-clamped value.

A new logical session immediately appends pending `model_change` and `thinking_level_change` entries. A resumed journal is not reseeded, except that an older journal without thinking metadata receives one inferred `thinking_level_change`. Physical persistence remains a separate `memory | pending | durable` transition owned by `SessionManager`: pending metadata and user input stay in memory, and the first assistant response writes the complete JSONL journal before the state becomes durable.

Model and thinking mutations update both authorities deliberately: the session journal records conversation-local changes, while `SettingsManager` records future-session defaults. Switching away from a non-reasoning model recovers the saved thinking preference; clamping a non-reasoning model to `off` does not overwrite that preference.

## Consequences

- New sessions have a selected model and effective thinking level before any prompt when configured preferences or providers permit it.
- Unprompted and response-less sessions do not enter session history.
- Resume context wins over changed defaults without contaminating the settings view.
- Missing saved models fall back through configured preferences and providers without failing resume, and the fallback is visible to the user.
- The removed composite `model` and runtime `thinkingLevel` settings are not part of the settings schema.
- Bootstrap behavior is testable through coding-agent owners without a terminal client.

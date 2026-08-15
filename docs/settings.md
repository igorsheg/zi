---
slug: settings
title: Set defaults
order: 30
---

# Set defaults

You keep passing the same flags on every run, or this repository needs a different model than your personal default. Settings hold those defaults so the command line stays short.

Zi reads them from two scopes:

```text
$HOME/.zi/agent/settings.json
<cwd>/.zi/settings.json
```

Global settings are your preferences. Project settings belong to the repository and load only when project configuration is [trusted](vocabulary.md). Runtime flags such as `--model` and `--api-key` are applied after both.

## Edit settings in the terminal

```text
/settings
```

The settings picker writes either the global or project scope, then reports the effective value. If a project setting shadows a global write, Zi says so instead of pretending the global value took effect.

Open provider-specific Codex settings with:

```text
/codex-settings
```

Its two-step picker exposes Fast Mode. On sends `text.verbosity: "low"` and `service_tier: "priority"` to the `openai-codex` provider. Off removes both fields. The picker writes the global setting.

## Example

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4-5-20250929",
  "defaultThinkingLevel": "medium",
  "externalEditor": "nvim",
  "steeringMode": "one-at-a-time",
  "followUpMode": "one-at-a-time",
  "codexFastMode": false,
  "subagentWaitTimeoutMs": 30000,
  "subagentWorkTimeoutMs": 900000,
  "retryEnabled": true,
  "retryMaxRetries": 3,
  "retryBaseDelayMs": 2000,
  "compactionEnabled": true,
  "compactionReserveTokens": 16384,
  "compactionKeepRecentTokens": 20000,
  "skills": ["~/.codex/skills"]
}
```

Provider and model should move together. If a project needs a different model, set both `defaultProvider` and `defaultModel` in the project settings file.

## Resource paths

Use typed arrays to add local resource files or directories:

```json
{
  "extensions": ["~/agent-resources/extensions"],
  "skills": ["~/.codex/skills", "~/agent-resources/skills"],
  "prompts": ["~/agent-resources/prompts"]
}
```

These paths are additive; conventional `.zi` locations continue to load. Absolute paths and leading `~` are supported.

Paths in global settings resolve relative to `$HOME/.zi/agent/`. Paths in project settings resolve relative to `<cwd>/.zi/`. Project entries load only after project trust and precede conventional project resources with the same name.

Each array accepts at most 128 file or directory paths, with each path bounded at 4096 bytes, keeping resource discovery bounded no matter what a repository adds.

## Fields

`defaultProvider`
: Provider name.

`defaultModel`
: Model ID within the provider.

`defaultThinkingLevel`
: Provider-supported thinking level.

`externalEditor`
: Command used by the terminal client's external-editor action. If omitted, Zi resolves `VISUAL`, then `EDITOR`, then the platform fallback.

`steeringMode`
: How prompts submitted during a run are queued.

`followUpMode`
: How prompts submitted after a run has pending follow-up are queued.

`codexFastMode`
: Send low text verbosity and the priority service tier to OpenAI Codex. When false, Zi removes both request fields.

`subagentWaitTimeoutMs`
: Default observation timeout for `wait_subagents`, in milliseconds from `0` through one hour. A wait timeout never cancels child work.

`subagentWorkTimeoutMs`
: Running deadline for each subagent work cycle, in milliseconds from `1` through one hour, defaulting to 15 minutes. A queued cycle starts this deadline only when FIFO admission moves it to running.

`retryEnabled`
: Turn automatic retry on or off.

`retryMaxRetries`
: Maximum retries for transient assistant failures.

`retryBaseDelayMs`
: Base retry delay. Zi applies bounded exponential backoff from this value.

`compactionEnabled`
: Turn automatic context compaction on or off.

`compactionReserveTokens`
: Context budget reserved for the next provider turn.

`compactionKeepRecentTokens`
: Recent context preserved around a compaction boundary.

`extensions`
: Additional extension files or directories.

`skills`
: Additional skill files or directories.

`prompts`
: Additional prompt-template files or directories.

A changed `subagentWorkTimeoutMs` applies to new sessions, not the running one. See [Subagents](subagents.md) for which work starts a fresh deadline, what Zi records when one expires, and how bounded interruption settlement ends a child.

## Invalid settings

Settings files are bounded and validated as operational input. If a file is missing, malformed, unreadable, or too large, Zi reports a diagnostic and falls back to valid layers. Zi refuses to overwrite an invalid settings file until you correct it.

See [Resources](resources.md) for where these files live and how project trust admits the project scope.

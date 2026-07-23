---
slug: settings
title: Set defaults
order: 14
---

# Set defaults

Zi reads settings from two scopes:

```text
$HOME/.zi/agent/settings.json
<cwd>/.zi/settings.json
```

Global settings are your preferences. Project settings belong to the repo. Runtime flags such as `--model` and `--api-key` are applied after both.

## Edit settings in the TUI

```text
/settings
```

The settings picker writes either the global or project scope, then reports the effective value. If a project setting shadows a global write, Zi says so instead of pretending the global value took effect.

## Example

```json
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-4-5-20250929",
  "defaultThinkingLevel": "medium",
  "steeringMode": "one-at-a-time",
  "followUpMode": "one-at-a-time",
  "retryEnabled": true,
  "retryMaxRetries": 3,
  "retryBaseDelayMs": 2000,
  "compactionEnabled": true,
  "compactionReserveTokens": 16384,
  "compactionKeepRecentTokens": 20000
}
```

Provider and model should move together. If a project needs a different model, set both `defaultProvider` and `defaultModel` in the project settings file.

## Fields

`defaultProvider`
: Provider name.

`defaultModel`
: Model id within the provider.

`defaultThinkingLevel`
: Provider-supported thinking level.

`steeringMode`
: How prompts submitted during a run are queued.

`followUpMode`
: How prompts submitted after a run has pending follow-up are queued.

`retryEnabled`
: Turn automatic retry on or off.

`retryMaxRetries`
: Maximum retry attempts for transient assistant failures.

`retryBaseDelayMs`
: Base retry delay. Zi backs off from this value.

`compactionEnabled`
: Turn automatic context compaction on or off.

`compactionReserveTokens`
: Context budget reserved for the next provider turn.

`compactionKeepRecentTokens`
: Recent context preserved around a compaction boundary.

## Bad settings do not break Zi

Settings files are capped and validated as operational input. If a file is missing, malformed, unreadable, or too large, Zi reports a diagnostic and falls back to the valid layers.

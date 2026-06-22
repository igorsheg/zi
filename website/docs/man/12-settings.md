---
slug: settings
title: Set your defaults
order: 12
aliases:
  - settings.json
  - config
  - configuration
  - model
---

# Set your defaults

You should not need to remember the right model every time you open a repo.

Put the defaults in settings.

Zi reads:

```text
~/.zi/agent/settings.json
<project>/.zi/settings.json
```

Use global settings for your preferences. Use project settings for what this repo needs.

## A useful starting point

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.1-codex-max",
  "defaultThinkingLevel": "medium"
}
```

That is enough for most setups.

## Add recovery policy when sessions get real

Longer work needs two things: compaction and retry.

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.1-codex-max",
  "defaultThinkingLevel": "medium",
  "compaction": {
    "enabled": true,
    "keepRecentTokens": 24000,
    "reserveTokens": 8000
  },
  "retry": {
    "enabled": true,
    "maxRetries": 2,
    "baseDelayMs": 1000
  }
}
```

Compaction keeps the model context useful as the session grows. Retry handles operational failures that are worth trying again.

## Provider and model move together

Zi resolves provider and model from the same scope.

If your global settings say:

```json
{ "defaultProvider": "openai-codex", "defaultModel": "gpt-5.1-codex-max" }
```

and your project settings only say:

```json
{ "defaultModel": "some-other-model" }
```

Zi will not combine them. That kind of silent mixing creates confusing sessions. Give the project both fields, or let it inherit both.

## Fields

`defaultProvider`
: Provider name.

`defaultModel`
: Model id.

`defaultThinkingLevel`
: Thinking level string.

`compaction.enabled`
: Turn compaction policy on or off.

`compaction.keepRecentTokens`
: Recent context to preserve.

`compaction.reserveTokens`
: Context budget to keep free for the next turn.

`retry.enabled`
: Turn retry policy on or off.

`retry.maxRetries`
: Maximum retry attempts.

`retry.baseDelayMs`
: Base delay before retry.

## Bad settings do not break Zi

Settings files are capped and parsed as operational input. If a file is missing, malformed, unreadable, or too large, Zi falls back to defaults.

Fix the file when you notice. The session should not crash because of a typo in JSON.

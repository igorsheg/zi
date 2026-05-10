---
slug: settings
title: Settings
order: 12
aliases:
  - settings.json
  - config
  - configuration
  - user settings
  - project settings
---

# Settings

zi reads JSON settings from two places:

```text
~/.zi/agent/settings.json
<project>/.zi/settings.json
```

User settings are the baseline. Project settings are layered on top for the current project.

Keep settings small. If a behavior needs code, write an extension. If it needs files, use [Resource discovery](resources.html).

## Example

```json
{
  "defaultModel": "claude",
  "theme": "dark",
  "quietStartup": true,
  "extensions": ["../zi-extensions"],
  "skills": ["../zi-skills"],
  "prompts": ["../zi-prompts"],
  "themes": ["../zi-themes"]
}
```

All fields are optional. Unknown fields are ignored.

## Model defaults

`defaultProvider`
: Preferred provider name.

`defaultModel`
: Preferred model id or model pattern.

`defaultThinkingLevel`
: One of `off`, `minimal`, `low`, `medium`, `high`, or `xhigh`.

`thinkingBudgets`
: Token budgets for thinking levels.

```json
{
  "thinkingBudgets": {
    "minimal": 1024,
    "low": 4096,
    "medium": 8192,
    "high": 16384
  }
}
```

`transport`
: Provider transport preference. One of `auto`, `sse`, or `websocket`.

`enabledModels`
: Array of model ids or patterns to show/use.

`models`
: Custom model definitions. Use this when a provider-compatible model is not built in.

```json
{
  "models": [
    {
      "id": "local/example",
      "name": "Example",
      "api": "openai",
      "provider": "local",
      "baseUrl": "http://localhost:11434/v1",
      "contextWindow": 32768,
      "maxTokens": 4096
    }
  ]
}
```

## Resources

These fields add extra resource paths:

`extensions`
: Extension roots or extension files.

`skills`
: Skill directories or individual `.md` skill files.

`prompts`
: Prompt directories or individual `.md` prompt files.

`themes`
: Theme directories or individual `.json` theme files.

`packages`
: Extension package roots. Current package loading applies to extension discovery.

Relative direct paths are resolved from the current project. User packages are resolved from `~/.zi/agent/`; project packages are resolved from `<project>/.zi/`.

See [Resource discovery](resources.html) for the directory layout.

## Interface

`theme`
: Theme name.

`quietStartup`
: Suppress startup noise.

`collapseChangelog`
: Collapse the changelog display.

`hideThinkingBlock`
: Hide model thinking blocks when supported.

`showHardwareCursor`
: Use the terminal hardware cursor.

`editorPaddingX`
: Horizontal editor padding.

`autocompleteMaxVisible`
: Maximum visible autocomplete entries.

`doubleEscapeAction`
: One of `fork`, `tree`, or `none`.

`treeFilterMode`
: One of `default`, `no-tools`, `user-only`, `labeled-only`, or `all`.

## Agent behavior

`steeringMode`
: One of `all` or `one-at-a-time`.

`followUpMode`
: One of `all` or `one-at-a-time`.

`enableSkillCommands`
: Enable skill command expansion.

`sessionDir`
: Override where sessions are written.

`compaction`
: Configure transcript compaction.

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 2000,
    "keepRecentTokens": 8000
  }
}
```

`branchSummary`
: Configure branch summaries.

```json
{
  "branchSummary": {
    "reserveTokens": 1000,
    "skipPrompt": false
  }
}
```

`retry`
: Configure provider retry behavior.

```json
{
  "retry": {
    "enabled": true,
    "maxRetries": 3,
    "baseDelayMs": 250,
    "maxDelayMs": 4000
  }
}
```

## Shell and terminal

`shellPath`
: Shell executable path.

`shellCommandPrefix`
: Prefix used for shell command execution.

`npmCommand`
: Command argv used when zi needs npm.

`terminal`
: Terminal behavior.

```json
{
  "terminal": {
    "showImages": true,
    "clearOnShrink": true
  }
}
```

`images`
: Image handling.

```json
{
  "images": {
    "autoResize": true,
    "blockImages": false
  }
}
```

`markdown`
: Markdown rendering behavior.

```json
{
  "markdown": {
    "codeBlockIndent": "  "
  }
}
```

## Notes

Settings are data, not policy. Prefer boring defaults here and put behavior in named extensions. Future you will thank present you, quietly.

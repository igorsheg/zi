---
slug: themes
title: Themes
order: 18
aliases:
  - theme
  - colors
  - theme json
---

# Themes

A theme is a JSON file that names every color zi needs to draw the TUI.

Use themes to make the interface calm enough to live in. Pretty is allowed. Legible is required.

## Locations

zi has built-in `dark` and `light` themes.

Custom themes load from:

```text
~/.zi/agent/themes/
<project>/.zi/themes/
```

Extra theme paths may be listed in `settings.json`:

```json
{
  "themes": ["../zi-themes", "../themes/my-theme.json"],
  "theme": "my-theme"
}
```

A theme path may be a directory or a single `.json` file. Directory loading is shallow: zi reads `.json` files directly inside that directory.

See [Resource discovery](resources.html) for path rules.

## Shape

```json
{
  "name": "my-theme",
  "vars": {
    "base": "#d8dee9",
    "mutedBase": "#6b7280",
    "panel": "#1f2430"
  },
  "colors": {
    "accent": "#8abeB7",
    "border": "mutedBase",
    "borderAccent": "#8abeB7",
    "borderMuted": "mutedBase",
    "success": "#a6da95",
    "error": "#ed8796",
    "warning": "#eed49f",
    "muted": "mutedBase",
    "dim": "#4b5563",
    "text": "base",
    "thinkingText": "mutedBase",
    "userMessageText": "base",
    "customMessageText": "base",
    "customMessageLabel": "#c6a0f6",
    "toolTitle": "#8aadf4",
    "toolOutput": "base",
    "mdHeading": "#8aadf4",
    "mdLink": "#8abeB7",
    "mdLinkUrl": "mutedBase",
    "mdCode": "#f5a97f",
    "mdCodeBlock": "base",
    "mdCodeBlockBorder": "mutedBase",
    "mdQuote": "base",
    "mdQuoteBorder": "mutedBase",
    "mdHr": "mutedBase",
    "mdListBullet": "#8abeB7",
    "toolDiffAdded": "#a6da95",
    "toolDiffRemoved": "#ed8796",
    "toolDiffContext": "mutedBase",
    "syntaxComment": "mutedBase",
    "syntaxKeyword": "#c6a0f6",
    "syntaxFunction": "#8aadf4",
    "syntaxVariable": "base",
    "syntaxString": "#a6da95",
    "syntaxNumber": "#f5a97f",
    "syntaxType": "#eed49f",
    "syntaxOperator": "#c6a0f6",
    "syntaxPunctuation": "base",
    "thinkingOff": "mutedBase",
    "thinkingMinimal": "#a6da95",
    "thinkingLow": "#8abeB7",
    "thinkingMedium": "#eed49f",
    "thinkingHigh": "#f5a97f",
    "thinkingXhigh": "#ed8796",
    "bashMode": "#8aadf4",

    "selectedBg": "panel",
    "userMessageBg": "panel",
    "customMessageBg": "panel",
    "toolPendingBg": "panel",
    "toolSuccessBg": "panel",
    "toolErrorBg": "panel"
  }
}
```

`name`
: Required. This is the value used by the `theme` setting.

`vars`
: Optional object of reusable color values.

`colors`
: Required. Every token must be present.

Color values may be:

- `"#rrggbb"` RGB strings
- integers from `0` to `255` for terminal indexed colors
- variable names from `vars`
- `""` for the terminal default color

Unknown tokens, unknown variables, circular variables, and missing colors are reported as diagnostics.

## Collisions

The first theme with a name wins. Later themes with the same name are skipped and reported as collisions.

Copy a built-in theme first. Change a few colors. Then change a few more. Big-bang themes are how terminals become flashlights.

# theme system

zi custom themes use the pi-mono-compatible JSON shape:

```json
{
  "$schema": "https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json",
  "name": "my-theme",
  "vars": {
    "accent": "#8abeb7",
    "mutedText": "#808080",
    "panelBg": "#282832"
  },
  "colors": {
    "accent": "accent",
    "border": "#5f87ff",
    "borderAccent": "accent",
    "borderMuted": "#505050",
    "success": "#b5bd68",
    "error": "#cc6666",
    "warning": "#ffff00",
    "muted": "mutedText",
    "dim": "#666666",
    "text": "",
    "thinkingText": "mutedText",
    "userMessageText": "",
    "customMessageText": "",
    "customMessageLabel": "#9575cd",
    "toolTitle": "",
    "toolOutput": "mutedText",
    "mdHeading": "#f0c674",
    "mdLink": "#81a2be",
    "mdLinkUrl": "#666666",
    "mdCode": "accent",
    "mdCodeBlock": "#b5bd68",
    "mdCodeBlockBorder": "mutedText",
    "mdQuote": "mutedText",
    "mdQuoteBorder": "mutedText",
    "mdHr": "mutedText",
    "mdListBullet": "accent",
    "toolDiffAdded": "#b5bd68",
    "toolDiffRemoved": "#cc6666",
    "toolDiffContext": "mutedText",
    "syntaxComment": "#6A9955",
    "syntaxKeyword": "#569CD6",
    "syntaxFunction": "#DCDCAA",
    "syntaxVariable": "#9CDCFE",
    "syntaxString": "#CE9178",
    "syntaxNumber": "#B5CEA8",
    "syntaxType": "#4EC9B0",
    "syntaxOperator": "#D4D4D4",
    "syntaxPunctuation": "#D4D4D4",
    "thinkingOff": "#505050",
    "thinkingMinimal": "#6e6e6e",
    "thinkingLow": "#5f87af",
    "thinkingMedium": "#81a2be",
    "thinkingHigh": "#b294bb",
    "thinkingXhigh": "#d183e8",
    "bashMode": "#b5bd68",
    "selectedBg": "#3a3a4a",
    "userMessageBg": "#343541",
    "customMessageBg": "#2d2838",
    "toolPendingBg": "panelBg",
    "toolSuccessBg": "#283228",
    "toolErrorBg": "#3c2828"
  },
  "export": {
    "pageBg": "#18181e",
    "cardBg": "#1e1e24",
    "infoBg": "#3c3728"
  }
}
```

## file locations

zi discovers theme JSON files from runtime roots and theme paths. see [runtime roots](./runtime-roots.md) for root precedence.

common locations:

- user root: `~/.zi/agent/themes/*.json` unless `ZI_CODING_AGENT_DIR` overrides the agent directory
- project root: `<project>/.zi/themes/*.json`
- settings-provided theme paths
- extension-provided runtime roots with `themes/*.json`

when two files use the same `name`, normal resource precedence chooses one and reports a collision diagnostic.

## format rules

- `name` is required and is the selectable theme name.
- `colors` is required.
- every `colors` token listed below is required.
- token names are camelCase pi-mono wire names, not zig enum names.
- old `fg` / `bg` split examples are not valid.
- `vars` is optional.
- a color value may be:
  - `"#RRGGBB"`
  - `""` for the terminal default color
  - an integer `0` through `255` for a 256-color palette index
  - a plain string reference to a key in `vars`
- variable references are plain strings, not CSS `var(...)` calls.
- circular variable references and unknown variables are rejected.
- `export` is accepted for pi-mono compatibility; zi's terminal TUI uses `colors`.

## required color tokens

foreground/text tokens:

```text
accent
border
borderAccent
borderMuted
success
error
warning
muted
dim
text
thinkingText
userMessageText
customMessageText
customMessageLabel
toolTitle
toolOutput
mdHeading
mdLink
mdLinkUrl
mdCode
mdCodeBlock
mdCodeBlockBorder
mdQuote
mdQuoteBorder
mdHr
mdListBullet
toolDiffAdded
toolDiffRemoved
toolDiffContext
syntaxComment
syntaxKeyword
syntaxFunction
syntaxVariable
syntaxString
syntaxNumber
syntaxType
syntaxOperator
syntaxPunctuation
thinkingOff
thinkingMinimal
thinkingLow
thinkingMedium
thinkingHigh
thinkingXhigh
bashMode
```

background tokens:

```text
selectedBg
userMessageBg
customMessageBg
toolPendingBg
toolSuccessBg
toolErrorBg
```

## diagnostics

invalid theme files are skipped and reported as resource warnings. diagnostics include the file path and the repair detail when zi can infer it, for example:

```text
failed to parse theme file: missing required foreground color token 'border'
failed to parse theme file: unknown color token 'borderAccentt'
failed to parse theme file: unknown variable 'panelBackground'
failed to parse theme file: circular variable reference involving 'accent'
```

use the bundled themes as canonical full examples:

- `src/themes/builtin/dark.json`
- `src/themes/builtin/light.json`

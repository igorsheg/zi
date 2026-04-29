# zi(1)

## name

zi - yours-first coding agent

## synopsis

`zi [run-options] [@file ...] [prompt]`

`zi -p [@file ...] [prompt]`

`zi --mode <text|json> [@file ...] [prompt]`

`zi --continue`

`zi --resume`

`zi --session <path|id>`

`zi --list-models [search]`

## description

There are many coding agents. This one is yours.

zi is a local-first coding agent harness for people who want agent help without giving up ownership of their tools. It keeps sessions durable, configuration local, extensions small, and behavior explicit enough to inspect.

You can use zi as-is. You can also teach it your habits one piece at a time: a command, a tool, a prompt rule, a model preference, a bit of UI.

The goal is not to make agent work magical. The goal is to make it dependable.

## philosophy

zi is small on purpose.

A good agent harness should be understandable by one person. It should compose with the tools you already use. It should keep useful history. It should make automation visible enough that you can trust it, change it, or remove it.

Extensions are not a marketplace feature. They are how the tool becomes yours.

Start small. Add one thing. Keep what helps. Delete what does not.

## readers

This manual is written for two readers:

- humans who want to use zi or write extensions
- zi itself, when the user asks: "build me an extension"

When generating an extension, prefer the API documented here and adapt the closest available example. Favor small, explicit behavior over clever machinery.

Agents and other programmatic readers should prefer the Markdown version of each page. Replace the web page suffix with `.md`, for example `cli.html` becomes `cli.md`. When following links from Markdown manually, prefer the adjacent `.md` target when available.

## contents

- [cli model](cli.html#cli-model) — run modes, prompt inputs, session selectors, and flags
- [extension purpose](extensions.html#extension-purpose) — what extensions are for and how zi discovers them
- [extension api: zi table](api.html#extension-api-zi-table) — `zi.register_tool`, commands, providers, events, and spawn
- [context object](context.html#context-object) — `ctx.ui`, `ctx.state`, `ctx.session`, `ctx.models`, and `ctx.ai`
- [extension design rules](guidance.html#extension-design-rules) — guidance for humans and for zi when writing extensions

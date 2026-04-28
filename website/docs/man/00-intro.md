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

There are many coding agents. This one is yours: ask zi to extend itself to best suit your workflow.

zi is a local-first coding agent harness with a terminal UI, durable sessions, explicit batch modes, model selection, and Lua extensions. The consumer surface is deliberately small: the CLI starts, resumes, or batches agent work; extensions add workflow-specific tools, commands, UI, model/provider behavior, prompt rules, and session policy.

This manual is written for two readers:

- humans who want to use zi or write extensions
- zi itself, when the user asks: "build me an extension"

When generating an extension, prefer the API documented here and adapt the closest available example.

## contents

- [cli model](cli.html#cli-model) — run modes, prompt inputs, session selectors, and flags
- [extension purpose](extensions.html#extension-purpose) — what extensions are for and how zi discovers them
- [extension api: zi table](api.html#extension-api-zi-table) — `zi.register_tool`, commands, providers, events, and spawn
- [context object](context.html#context-object) — `ctx.ui`, `ctx.state`, `ctx.session`, `ctx.models`, and `ctx.ai`
- [extension design rules](guidance.html#extension-design-rules) — guidance for humans and for zi when writing extensions

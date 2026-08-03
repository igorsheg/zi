```
░▀▀█░▀█▀
░▄▀░░░█░
░▀▀▀░▀▀▀
```

A coding agent you can build with.

Use it as-is, or teach it one habit at a time: a command, a tool, a prompt rule, a model preference, or a bit of UI.
The goal is dependable agent work you can understand and change.

Zi is developed as a dependable coding-agent building block with an opinionated reference terminal client. Start with the [Zi manual](docs/index.md), then use the focused guides for the [CLI](docs/cli.md), [extensions](docs/extensions.md), [subagents](docs/subagents.md), and [RPC](docs/rpc.md).

## Install

```sh
npm install -g @with-zi/zi
```

## Getting Started

Read the same manual locally in [`docs/`](docs/index.md) or online at https://withzi.dev/man/. For process composition, see the [CLI contract](docs/cli.md) and [versioned RPC protocol](docs/rpc.md).

Zi ships version-matched documentation and copyable examples beside the native executable. Ask Zi to build a skill, extension, or subagent profile and it can read those local files before implementing.

## Build from source

```sh
git clone https://github.com/igorsheg/zi
cd zi
bun install --frozen-lockfile
bun run build
./dist/zi --version
```

## Acknowledgments

First and foremost, thank you to [Mario Zechner](https://github.com/badlogic) for teaching by example how to design systems, harnesses, and agents.

Thank you to [OpenTUI](https://github.com/anomalyco/opentui/) for showing what terminal and TUI software can feel like.

Thank you to [Mitchell Hashimoto](https://x.com/mitchellh) for articulating [The Building Block Economy](https://x.com/mitchellh/status/2041566958681014418).

## License

MIT

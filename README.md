```
░▀▀█░▀█▀
░▄▀░░░█░
░▀▀▀░▀▀▀
```

A coding agent you can build with.

Use it as-is, or teach it one habit at a time: a command, a tool, a prompt rule, a model preference, or a bit of UI.
The goal is dependable agent work you can understand and change.

## Install

```sh
curl -fsSL https://withzi.dev/install | sh
```

## Getting Started

Read the docs at https://withzi.dev/man.

## Build from source

```sh
git clone https://github.com/igorsheg/zi
cd zi
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zi --version
```

## Acknowledgments

First and foremost, thank you to [Mario Zechner](https://github.com/badlogic) for teaching by example how to design systems, harnesses, and agents.

Thank you to [OpenTUI](https://github.com/anomalyco/opentui/) for showing what terminal and TUI software can feel like.

Thank you to [Mitchell Hashimoto](https://x.com/mitchellh) for articulating [The Building Block Economy](https://x.com/mitchellh/status/2041566958681014418).

## License

MIT

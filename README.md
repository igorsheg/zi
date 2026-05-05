```
░▀▀█░▀█▀
░▄▀░░░█░
░▀▀▀░▀▀▀
```

A coding agent you can build with.

Use it as-is, or teach it one habit at a time: a command, a tool, a prompt rule, a model preference, or a bit of UI.
The goal is dependable agent work you can understand and change.

## Install

Prebuilt artifacts are currently published for:

- macOS Apple Silicon (`aarch64-apple-darwin`)
- Linux x86_64 (`x86_64-unknown-linux-musl`)
- Linux arm64 (`aarch64-unknown-linux-musl`)

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/igorsheg/zi/main/scripts/install.sh | sh
```

Install a specific release candidate:

```sh
curl -fsSL https://raw.githubusercontent.com/igorsheg/zi/main/scripts/install.sh | ZI_VERSION=0.1.0-rc.1 sh
```

The intended friendly URL is:

```sh
curl -fsSL https://withzi.dev/install | sh
```

That route will be enabled once the website deployment is configured.

Intel macOS and Windows prebuilt artifacts are not published yet. Build from source for those platforms.

## Build from source

```sh
git clone https://github.com/igorsheg/zi
cd zi
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zi --version
```

zi currently tracks Zig `0.16.0`.

## Docs

Read the docs at https://withzi.dev/man.

## Acknowledgments

First and foremost, thank you to [Mario Zechner](https://github.com/badlogic) for teaching by example how to design systems, harnesses, and agents.

Thank you to [OpenTUI](https://github.com/anomalyco/opentui/) for showing what terminal and TUI software can feel like.

Thank you to [Mitchell Hashimoto](https://x.com/mitchellh) for articulating [The Building Block Economy](https://x.com/mitchellh/status/2041566958681014418).

## License

MIT

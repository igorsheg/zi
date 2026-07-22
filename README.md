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

 ◆ Edit prompt-store.test.ts +3/-3
 │ 39     const prompt = createPromptStore(mode, slash)
 │ 40
 │ 41     try {
 │ 42 −     prompt.draftChanged("/rev", 4)
 │ 43 −     expect(prompt.activatePicker("/rev", 4)).toBe(true)
 │ … middle output · Ctrl+O details
 │ 43 +     expect(prompt.activatePicker("/rev path", 4)).toBe(true)
 │ 44 +     expect(prompt.$state.get().inputEdit).toEqual({ revision: 1, text: "/review path", cursorOffset: 8 })
 │ 45       expect(session.messages).toEqual([])
 │ 46     } finally {
 │ 47       mode.dispose()
 ╰───



 ◆ Run the full TUI test suite · timeout 180s
 │ $ bun run --filter @openzi/tui test
 │ … earlier output · Ctrl+O details
 │ @openzi/tui test:  0 fail
 │ @openzi/tui test:  807 expect() calls
 │ @openzi/tui test: Ran 146 tests across 24 files. [6.11s]
 │ @openzi/tui test: Exited with code 0
 ╰───




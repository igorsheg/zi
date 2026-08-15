# Third-party notices

Zi bundles or depends on third-party software. Each dependency remains under its own license; this file summarizes the primary notices for release artifacts.

## Runtime and agent dependencies

- `@earendil-works/pi-ai` — MIT — Copyright Mario Zechner and contributors
- `@earendil-works/pi-agent-core` — MIT — Copyright Mario Zechner and contributors
- `yuku-parser` and `yuku-codegen` — MIT — Copyright (c) 2026 Yuku
- `@opentui/core` — MIT — Copyright OpenTUI contributors
- `md4x` — MIT — Copyright © 2016-2026 Martin Mitáš; Copyright © 2025-present Pooya Parsa
- `nanostores` — MIT — Copyright Nano Stores contributors
- `string-width` — MIT — Copyright Sindre Sorhus and contributors
- `typebox` — MIT — Copyright Haydn Paterson
- `diff` — BSD-3-Clause — Copyright Kevin Decker and contributors
- `entities` — BSD-2-Clause — Copyright Felix Böhm and contributors
- `ignore` — MIT — Copyright Kael Zhang and contributors
- `proper-lockfile` — MIT — Copyright Moxystudio and contributors
- `yaml` — ISC — Copyright Eemeli Aro

## Bundled source

- OpenCode Merman terminal Mermaid renderer — MIT — Copyright OpenCode contributors — ported from <https://github.com/anomalyco/opencode>; source provenance and license are retained in `packages/tui/src/interactive/transcript/mermaid/`.
- DeepSeek Harness Code Mode logic, subprocess behavior, and shell environment defaults — MIT — Copyright (c) 2026 DeepSeek — adapted from <https://github.com/deepseek-ai/deepseek-harness> at commit `47f943859bef60e4160492346772ded9b24f765a`.

md4x MIT notice:

Copyright © 2016-2026 Martin Mitáš (<https://github.com/mity/md4c>)
Copyright © 2025-present Pooya Parsa <pooya@pi0.io>

This software is a fork of [md4c](https://github.com/mity/md4c) by Martin Mitáš, originally licensed under the MIT License.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

DeepSeek Harness MIT notice:

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Transitive runtime dependencies

Zi's standalone executable is bundled with the pinned Bun runtime and the npm dependency graph locked in `bun.lock`, including provider SDKs used by Pi AI and native/WASM assets used by OpenTUI. The exact resolved versions for a release are the versions in the tagged repository's lockfile and generated GitHub artifact provenance.

## Sources

- Pi: <https://github.com/earendil-works/pi>
- OpenTUI: <https://github.com/anomalyco/opentui>
- md4x: <https://github.com/unjs/md4x>
- Bun: <https://github.com/oven-sh/bun>
- TypeBox: <https://github.com/sinclairzx81/typebox>
- Yuku: <https://github.com/yuku-toolchain/yuku>
- DeepSeek Harness: <https://github.com/deepseek-ai/deepseek-harness>

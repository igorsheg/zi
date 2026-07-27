# Third-party notices

Zi bundles or depends on third-party software. Each dependency remains under its own license; this file summarizes the primary notices for release artifacts.

## Runtime and agent dependencies

- `@earendil-works/pi-ai` — MIT — Copyright Mario Zechner and contributors
- `@earendil-works/pi-agent-core` — MIT — Copyright Mario Zechner and contributors
- `@opentui/core` — MIT — Copyright OpenTUI contributors
- `nanostores` — MIT — Copyright Nano Stores contributors
- `string-width` — MIT — Copyright Sindre Sorhus and contributors
- `typebox` — MIT — Copyright Haydn Paterson
- `diff` — BSD-3-Clause — Copyright Kevin Decker and contributors
- `ignore` — MIT — Copyright Kael Zhang and contributors
- `proper-lockfile` — MIT — Copyright Moxystudio and contributors
- `yaml` — ISC — Copyright Eemeli Aro

## Transitive runtime dependencies

Zi's standalone executable is bundled with the pinned Bun runtime and the npm dependency graph locked in `bun.lock`, including provider SDKs used by Pi AI and native/WASM assets used by OpenTUI. The exact resolved versions for a release are the versions in the tagged repository's lockfile and generated GitHub artifact provenance.

## Sources

- Pi: <https://github.com/earendil-works/pi>
- OpenTUI: <https://github.com/anomalyco/opentui>
- Bun: <https://github.com/oven-sh/bun>
- TypeBox: <https://github.com/sinclairzx81/typebox>

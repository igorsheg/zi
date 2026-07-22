# Shipping Zi

Zi has two distribution boundaries:

- the end-user CLI ships as a native standalone executable built with the pinned Bun version;
- embeddable packages will ship as transpiled ESM and declarations, not as executable bundles.

The executable is always built on its target platform with the workspace-pinned Bun runtime. This keeps Bun's embedded runtime, OpenTUI's native library, and its worker/WASM assets aligned with the host instead of relying on cross-compilation of optional native packages.

## Local production build

The ordinary maintainer loop runs TypeScript directly with `bun run start`. To exercise the exact bundled production shape on the current machine:

```sh
bun run build
./dist/zi
```

On Windows the output is `dist/zi.exe`. The local build compiles to a temporary file, verifies its embedded version, and only then replaces the previous executable. Its version identifies the current commit and a dirty working tree, including untracked files, while `ZI_BUILD_VERSION` can provide an explicit local version. It does not create a release archive.

## Local release artifact

Build, smoke-test, archive, and checksum the current platform:

```sh
bun install --frozen-lockfile
bun scripts/build-release.ts --version 0.1.0
```

The script writes these ignored artifacts under `dist/`:

```text
zi-0.1.0-<os>-<arch>.tar.gz
zi-0.1.0-<os>-<arch>.tar.gz.sha256
```

A requested `--target` must match the current host. Release versions are restricted to SemVer core and prerelease forms so they are safe artifact names. Local and release builds share `scripts/compile-zi.ts`, which refuses to compile unless the running Bun version exactly matches the workspace `packageManager` pin, embeds the version, disables Bun's runtime loading of project `.env`, `bunfig.toml`, and `package.json` files, and runs `zi --version` against the compiled executable. Pi AI intentionally hides Node-only OAuth flows from generic bundlers, so this owner replaces its one opaque loader with bundler-visible literal imports for Anthropic, GitHub Copilot, and OpenAI Codex while preserving lazy loading; it fails if the pinned dependency no longer matches. A standalone regression test derives request authentication through all three implementations. The release builder then archives and checksums that executable.

## GitHub delivery

`.github/workflows/ci.yml` runs the complete repository check for pull requests and `main`.

Pushing a tag such as `v0.1.0` starts `.github/workflows/release.yml`. It:

1. runs the complete check once;
2. builds macOS arm64/x64, Linux arm64/x64, and Windows x64 on native runners;
3. smoke-tests and archives each executable;
4. verifies and combines SHA-256 checksums;
5. creates GitHub build-provenance attestations;
6. publishes one GitHub release only after every target succeeds.

A SemVer prerelease tag such as `v0.2.0-rc.1` creates a prerelease. The tag is the product-version source; package versions do not control executable releases. The final job deploys through the GitHub `release` environment, where repository settings can require approval without changing the workflow.

```sh
git tag -s v0.1.0 -m "Zi v0.1.0"
git push origin v0.1.0
```

Before the first public release, add third-party notices and configure macOS notarization and Windows signing. GitHub attestations prove workflow provenance but do not replace platform signatures.

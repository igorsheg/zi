# Release packaging direction

Zi has two release channels with different owners:

1. **GitHub Releases** publish native standalone executables for direct download.
2. **npm** will provide the developer install path and a future SDK boundary.

The GitHub executable remains the source artifact. npm packaging should wrap those same per-platform executables instead of rebuilding or downloading arbitrary assets during install.

## Patterns to copy

- **Platform package split**: follow the `esbuild`/`rollup`/`biome` shape: one small top-level CLI package depends on optional per-platform packages. Install selects the current platform through npm's native `os`/`cpu` filters.
- **No network postinstall**: avoid installer scripts that fetch release assets. They fail behind proxies, complicate provenance, and are harder to audit.
- **Pinned automation**: keep GitHub Actions pinned by SHA, with minimal permissions per job and release publishing behind the `release` environment.
- **Provenance**: publish GitHub artifact attestations for archives and npm provenance for packages through OIDC (`id-token: write`, `npm publish --provenance`).
- **Pack tests**: every package path needs `npm pack --dry-run --json`, install-from-tarball smoke tests, and `zi --version` verification before publish.

## npm package shape

Target package names need one final ownership decision before publish:

- top-level CLI: prefer `zi` if available;
- platform packages: prefer `@zi/zi-<target>` if the npm scope is owned, otherwise use an owned scope such as `@igorsheg/zi-<target>`;
- SDK packages: keep private `@zi/coding-agent`/`@zi/tui` names until an owned public scope exists.

The top-level package should contain:

```text
package.json
bin/zi.js          # tiny platform resolver
README.md
LICENSE
```

Each platform package should contain:

```text
package.json       # os/cpu constrained, no lifecycle scripts
bin/zi[.exe]       # executable built by the native release matrix
LICENSE
THIRD_PARTY_NOTICES.md
```

The resolver should only locate the installed optional package for `process.platform`/`process.arch`, then replace the current process with the native executable. If the optional package is missing, it should print a short reinstall diagnostic rather than downloading a binary.

## GitHub release hardening

The current release workflow already has the right spine: verify once, build on native runners, smoke-test, archive, checksum, attest, and publish after every target succeeds.

Before the first public release:

- add `THIRD_PARTY_NOTICES.md` generated from the dependency graph and bundled OpenTUI assets;
- decide whether Windows artifacts should stay `.tar.gz` or additionally publish `.zip`;
- configure macOS signing/notarization and Windows signing;
- run a prerelease tag through the `release` environment;
- document install and update commands in `README.md` after the npm package name is final.

## npm publish workflow

Add a separate workflow after the GitHub archive flow is proven:

1. trigger on the same SemVer tag;
2. run the complete check;
3. build or download the attested native archives;
4. assemble one platform package per archive with exact version matching the tag;
5. assemble the top-level CLI package with optional dependencies on the platform packages;
6. run `npm pack --dry-run --json` for every package;
7. install the packed top-level package in a clean temp project and run `zi --version` plus `zi --help`;
8. publish platform packages first, then the top-level package, with `npm publish --provenance`.

Package `files` allowlists should be explicit. No package should include source tests, local config, session data, or build caches.

## Migration note

The rename moves product state from `$HOME/.openzi/agent` and `<cwd>/.openzi` to `$HOME/.zi/agent` and `<cwd>/.zi`. Before a public release, add a one-time documented manual migration command for dogfood users; do not auto-move credentials or sessions without an explicit user action.

# Release packaging direction

Zi has two release channels with different owners:

1. **GitHub Releases** publish native standalone executables for direct download.
2. **npm** provides the developer install path and a future SDK boundary.

The GitHub executable remains the source artifact. npm packaging should wrap those same per-platform executables instead of rebuilding or downloading arbitrary assets during install.

## Patterns to copy

- **Platform package split**: follow the `esbuild`/`rollup`/`biome` shape: one small top-level CLI package depends on optional per-platform packages. Install selects the current platform through npm's native `os`/`cpu` filters.
- **No network postinstall**: avoid installer scripts that fetch release assets. They fail behind proxies, complicate provenance, and are harder to audit.
- **Pinned automation**: keep GitHub Actions pinned by SHA, with minimal permissions per job and release publishing behind the `release` environment.
- **Provenance**: publish GitHub artifact attestations for archives and npm provenance for packages through OIDC (`id-token: write`, `npm publish --provenance`).
- **Pack tests**: every package path needs `npm pack --dry-run --json`, install-from-tarball smoke tests, and `zi -V` verification before publish.

## npm package shape

The owned npm scope is `@with-zi`:

- top-level CLI: `@with-zi/zi`;
- platform packages: `@with-zi/zi-<target>`;
- SDK packages: private source packages use `@with-zi/coding-agent` and `@with-zi/tui` until their public boundary is ready.

`scripts/build-npm-packages.ts` assembles these packages from the native GitHub release archives. The top-level package contains:

```text
package.json
bin/zi.js          # tiny platform resolver
README.md
LICENSE
THIRD_PARTY_NOTICES.md
```

Each platform package should contain:

```text
package.json       # os/cpu constrained, no lifecycle scripts
bin/zi[.exe]       # executable built by the native release matrix
LICENSE
THIRD_PARTY_NOTICES.md
```

The resolver only locates the installed optional package for `process.platform`/`process.arch`, then runs the native executable. If the optional package is missing, it prints a short reinstall diagnostic rather than downloading a binary.

## GitHub release hardening

The current release workflow verifies once, builds on native runners, smoke-tests, archives, packages npm tarballs, verifies a local npm install, checksums, attests, and publishes GitHub release assets only after every target succeeds.

Before a stable public release:

- expand `THIRD_PARTY_NOTICES.md` from a maintained summary to a generated dependency-graph notice;
- decide whether Windows GitHub artifacts should stay `.tar.gz` or additionally publish `.zip`;
- configure macOS signing/notarization and Windows signing.

The alpha release path has been exercised end-to-end: native artifacts, GitHub release publication, npm package publication, provenance, install smoke, and trusted publishing are in place.

## npm publish workflow

The tag workflow builds npm tarballs and publishes them from the protected `npm` environment through npm trusted publishing. The alpha bootstrap used a short-lived `NPM_TOKEN` only to create the packages; the permanent workflow relies on `id-token: write` and `npm publish --provenance`.

1. trigger on the same SemVer tag;
2. download the `npm-packages` artifact from the release run;
3. publish platform packages first, then the top-level package, with `npm publish --provenance --access public`;
4. publish under the default `latest` dist-tag for both prereleases and stable releases;
5. verify `npm view @with-zi/zi@latest version` matches the tag.

Trusted publishing must stay configured for every `@with-zi/zi*` package with repository `igorsheg/zi`, workflow `release.yml`, environment `npm`, and the `npm publish` action.

Package `files` allowlists should be explicit. No package should include source tests, local config, session data, or build caches.

## Migration note

The rename moves product state from `$HOME/.openzi/agent` and `<cwd>/.openzi` to `$HOME/.zi/agent` and `<cwd>/.zi`. README documents the optional copy commands for dogfood users. Do not auto-move credentials or sessions without an explicit user action.

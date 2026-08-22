# Vendored md4x source

This directory contains the parser and ANSI renderer subset of md4x 0.0.29.

- Source: https://github.com/unjs/md4x
- Revision: `3e3036f272b925c9a3d191a93b5155577b3bc1b6`
- License: MIT, retained at `../licenses/md4x.txt`
- Emoji shortcode support: disabled. The generated table is retained because Zig analyzes the import, but it is not linked.

The snapshot includes only the production dependency closure for `md_ansi` and
the parser files reached by its Zig tests. Zi does not vendor md4x's CLI,
JavaScript packages, WASM and NAPI adapters, YAML implementation, or unrelated
renderers.

Do not edit these files as ordinary Zi source. Refresh them from the pinned
upstream repository and update the revision and third-party notice together.

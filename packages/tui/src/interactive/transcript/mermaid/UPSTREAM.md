# Merman provenance

This directory ports OpenCode's terminal Mermaid renderer from:

- Repository: https://github.com/anomalyco/opencode
- Package: `packages/merman`
- Commit: `c581b59b7f0c235555226900158feab43bf64ded`
- License: MIT; see `LICENSE.opencode`

Zi keeps the parser, layout, routing, drawing, and OpenTUI Markdown adapter together under the transcript owner. OpenCode's plugin registration and palette adapter are intentionally omitted: Mermaid is a built-in Zi transcript capability, and Zi supplies its own theme colors and rendering bounds.

Local behavior changes belong in `markdown.ts`. Keep parser and renderer changes traceable to upstream when syncing later Merman fixes.

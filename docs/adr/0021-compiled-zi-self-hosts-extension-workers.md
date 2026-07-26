# ADR 0021: Compiled Zi self-hosts extension workers

## Status

Accepted.

## Context

Zi must load repository-owned TypeScript extensions without letting an extension crash or block the coding-agent process and terminal owner loop. Release artifacts are standalone Bun executables, so the main alternatives were to self-spawn that executable in an internal worker mode or distribute a separate worker requiring an installed Node runtime.

A release-shaped probe compiled the full Zi CLI entrypoint and exercised external TypeScript loading, an async factory, a Node built-in, extension-local dependency resolution, isolated stdout and stderr, a dedicated protocol pipe, attributed exceptions, deliberate process exit, infinite-loop termination, and clean exit. Bun's direct extra-file-descriptor APIs passed on macOS and Linux but failed on Windows. Using Bun's `node:child_process.spawn()` compatibility API with an extra stdio pipe, and `node:fs` descriptor I/O in the worker, passed with Bun 1.3.14 on all release targets: macOS arm64/x64, Linux arm64/x64, and Windows x64. The confirming run was [GitHub Actions 30218801769](https://github.com/igorsheg/zi/actions/runs/30218801769).

## Decision

Each non-empty extension generation self-spawns the current compiled Zi executable in an internal extension-worker mode. The worker uses Bun's external TypeScript module loading and normal module resolution, so extensions may import Node built-ins and dependencies from their own package hierarchy without a separate build step or installed Node runtime.

The `ExtensionHost` creates workers through `node:child_process.spawn()` rather than Bun's direct subprocess file-descriptor interface. Host-to-worker protocol frames use child stdin; worker-to-host frames use a dedicated extra pipe; child stdout and stderr remain separate bounded extension log streams. Worker descriptor writes use `node:fs`. Production framing, validation, queue bounds, deadlines, and generation transitions remain owned by `ExtensionHost`; this ADR selects only the runtime and portable process transport.

The worker process is a fault-containment and lifecycle boundary, not a security sandbox. Extensions retain the user's operating-system authority, and forced worker termination guarantees cleanup only for processes and pipes owned by `ExtensionHost`, not detached extension descendants.

## Consequences

- Zi release archives remain self-contained and do not acquire a Node runtime dependency or separately versioned worker asset.
- The compiled entrypoint must recognize the internal worker mode before ordinary CLI dispatch.
- Every supported release target must retain a compiled acceptance test for external TypeScript, local dependency resolution, the dedicated pipe, crash containment, and bounded hang termination.
- Direct Bun subprocess descriptor APIs are not used for extension protocol transport unless a future cross-platform probe supersedes this decision.
- The temporary runtime probe and its workflow are deleted now that their evidence is recorded.

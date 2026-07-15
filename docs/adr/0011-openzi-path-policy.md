# ADR 0011: One cwd-bound owner defines OpenZi paths

## Status

Accepted.

## Context

OpenZi previously derived paths independently in runtime construction, resource loading, and session storage. The default global directory was `$HOME/.openzi/agent`, project-local `.openzi/` resources had no owner, settings were memory-only, and the built-in Pi model registry had no OpenZi credential store.

Pi coding-agent at `0e6909f0` establishes the behavior to preserve: one global agent directory, a cwd-local configuration directory, global authentication and sessions, layered global/project settings, ancestor instruction discovery, and cwd-specific services rebuilt from a resumed session's stored cwd. Relevant sources are `src/config.ts`, `src/utils/paths.ts`, `src/core/settings-manager.ts`, `src/core/auth-storage.ts`, `src/core/resource-loader.ts`, `src/core/session-manager.ts`, and `src/core/agent-session-services.ts`.

OpenZi deliberately uses a simpler product path requested for this recreation: `$HOME/.openzi` is the global directory. It does not retain Pi's additional `agent/` segment.

## Decision

`packages/coding-agent/src/paths.ts` owns an immutable `OpenZiPaths` value for one effective cwd. Runtime construction creates it only after opening an explicit session file, because a resumed session's header cwd is authoritative. Cwd-bound services consume that same value rather than accepting independent cwd/global-directory strings.

The default layout is:

```text
$HOME/.openzi/
  auth.json
  settings.json
  sessions/<encoded-absolute-cwd>/*.jsonl
  AGENTS.md
  SYSTEM.md
  APPEND_SYSTEM.md
  extensions/
  prompts/
  skills/
  themes/

<effective-cwd>/.openzi/
  settings.json
  SYSTEM.md
  APPEND_SYSTEM.md
  extensions/
  prompts/
  skills/
  themes/
```

`OPENZI_AGENT_DIR` replaces the complete global directory. It does not affect the project directory. Leading `~` is expanded for admitted path inputs; relative custom session directories resolve against the effective cwd. Other relative runtime paths must likewise be resolved once at their admitting boundary, not later against mutable process state.

The current policies are:

- **Settings:** defaults are overlaid by valid global settings, valid project settings, then runtime/session/CLI overrides. `updateGlobal()` writes global settings; `updateProject()` writes project settings. Missing, loaded, and invalid scopes are explicit: malformed or oversized files produce diagnostics and are excluded without preventing startup, while writes refuse to overwrite invalid data. Reads and serialized writes are bounded, and locked read-modify-write preserves fields unknown to this version. If `<cwd>/.openzi` is the global directory (for example, cwd is `$HOME`), the identical file is loaded once and both write APIs update that one scope.
- **Authentication:** credentials are global only at `auth.json`. `FileCredentialStore` implements Pi AI's credential-store contract with bounded cross-process locking, bounded input/output and provider count, redacted listing, atomic writes, and owner-only file permissions. Runtime model factories receive this exact store so model requests and authentication mutations share one owner. A CLI/API runtime key is a request-scoped in-memory override for one inferred model provider; it takes precedence through Pi AI stream options and never mutates `auth.json` or settings.
- **Sessions:** default journals remain global and are partitioned by encoded canonical cwd. `SessionManager.create()` requires `OpenZiPaths`; `SessionManager.open()` canonicalizes an explicit file. Opening a journal does not relocate it, and its parent remains the active session directory unless the caller supplies a custom directory.
- **Resources:** global instructions load first, followed by `AGENTS.md`/`CLAUDE.md` files from filesystem root to effective cwd. Project `.openzi/SYSTEM.md` and `.openzi/APPEND_SYSTEM.md` take precedence over their global equivalents. Project configuration is rooted at the effective cwd; OpenZi does not search ancestors for another `.openzi/` directory.

There is no mutable global path registry. `OpenZiPaths` contains no I/O or lifecycle state, and each settings, credential, session, or resource owner remains responsible for its own files and transitions.

## Consequences

- All cwd-sensitive services agree after session resume.
- Global state is directly under `$HOME/.openzi`; the obsolete `$HOME/.openzi/agent` location is not read or migrated.
- Embedders can replace the full global directory or session directory without changing project resolution.
- Project settings and system prompts are currently trusted when the caller admits the cwd, matching Pi's default trusted construction. A future project-trust capability must gate these owners together rather than adding per-loader exceptions.
- New persisted resources must add their derivation to `OpenZiPaths` and consume that value; they may not join `.openzi` independently.

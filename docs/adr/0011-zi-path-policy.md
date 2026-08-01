# ADR 0011: One cwd-bound owner defines Zi paths

## Status

Accepted.

## Context

Zi previously derived paths independently in runtime construction, resource loading, and session storage. Project-local `.zi/` resources had no owner, settings were memory-only, and the built-in Pi model registry had no Zi credential store. The first version of this decision then flattened global state into `$HOME/.zi`, despite Zi's earlier use of an `agent/` boundary.

Pi coding-agent at `0e6909f0` establishes the behavior to preserve: one global agent directory, a cwd-local configuration directory, global authentication and sessions, layered global/project settings, ancestor instruction discovery, and cwd-specific services rebuilt from a resumed session's stored cwd. Relevant sources are `src/config.ts`, `src/utils/paths.ts`, `src/core/settings-manager.ts`, `src/core/auth-storage.ts`, `src/core/resource-loader.ts`, `src/core/session-manager.ts`, and `src/core/agent-session-services.ts`.

Pi's extra `agent/` segment separates coding-agent-owned settings, credentials, sessions, and resources from other user-wide Pi capabilities. Zi retains that product/agent boundary rather than making the product root itself a coding-agent directory.

## Decision

`packages/coding-agent/src/paths.ts` owns an immutable `ZiPaths` value for one effective cwd. Runtime construction creates it only after opening an explicit session file, because a resumed session's header cwd is authoritative. Cwd-bound services consume that same value rather than accepting independent cwd/global-directory strings.

The default layout is:

```text
$HOME/.zi/
  agent/
    auth.json
    trust.json
    settings.json
    sessions/<encoded-absolute-cwd>/*.jsonl
    AGENTS.md
    SYSTEM.md
    APPEND_SYSTEM.md
    extensions/
    prompts/
    skills/
    themes/

<effective-cwd>/.zi/
  settings.json
  SYSTEM.md
  APPEND_SYSTEM.md
  extensions/
  prompts/
  skills/
  themes/
```

`ZI_AGENT_DIR` replaces the complete global directory. It does not affect the project directory. CLI `--agent-dir` overrides it. `ZI_SESSION_DIR` supplies a custom session directory and is overridden by CLI `--session-dir`. Leading `~` is expanded for admitted path inputs; relative custom session directories resolve against the effective cwd. Other relative runtime paths must likewise be resolved once at their admitting boundary, not later against mutable process state. See [ADR 0020](0020-cli-invocation-resolves-once-from-explicit-layers.md) for CLI resolution.

The current policies are:

- **Settings:** defaults are overlaid by valid global settings, valid project settings, then invocation-local construction overrides. Model preferences use Pi's `defaultProvider`, `defaultModel`, and `defaultThinkingLevel` fields; resumed journal context never enters the settings layers. `updateGlobal()` writes global settings; `updateProject()` writes project settings. Missing, loaded, and invalid scopes are explicit: malformed or oversized files produce diagnostics and are excluded without preventing startup, while writes refuse to overwrite invalid data. Reads and serialized writes are bounded, and locked read-modify-write preserves fields unknown to this version. If an explicit `ZI_AGENT_DIR` makes `<cwd>/.zi` the global directory, the identical file is loaded once and both write APIs update that one scope.
- **Authentication:** credentials are global only at `auth.json`. `FileCredentialStore` implements Pi AI's credential-store contract with bounded cross-process locking, bounded input/output and provider count, redacted listing, atomic writes, and owner-only file permissions. Runtime model factories receive this exact store so model requests and authentication mutations share one owner. A CLI/API runtime key is a request-scoped in-memory override for one inferred model provider; it takes precedence through Pi AI stream options and never mutates `auth.json` or settings.
- **Project trust:** canonical cwd decisions are global only at `trust.json`. `ProjectTrustStore` bounds and validates persisted input, serializes atomic updates, and applies the nearest stored cwd or parent decision. Exact project settings and resource paths that require admission derive from the same `ZiPaths`; contextual `AGENTS.md`/`CLAUDE.md` discovery remains separate. When an explicit global directory equals the project `.zi` directory, that root is user-admitted global configuration, does not prompt for project trust, and is discovered only with global scope. Runtime gating arrives as one coordinated extension-infrastructure slice rather than per-loader switches.
- **Sessions:** default journals remain global and are partitioned by encoded canonical cwd. `SessionManager.create()` requires `ZiPaths`; `SessionManager.open()` canonicalizes an explicit file. Opening a journal does not relocate it, and its parent remains the active session directory unless the caller supplies a custom directory.
- **Resources:** global instructions load first, followed by `AGENTS.md`/`CLAUDE.md` files from filesystem root to effective cwd. Project `.zi/SYSTEM.md` and `.zi/APPEND_SYSTEM.md` take precedence over their global equivalents. Skills, prompt templates, and subagent profiles load from the exact global and project resource directories; a project resource shadows a same-named global resource, canonical duplicate paths load once, and collisions remain visible as diagnostics. Project configuration is rooted at the effective cwd; Zi does not search ancestors for another `.zi/` directory.
- **Project file search:** each `AgentSession` receives a `ProjectFileSearch` constructed from the same immutable `ZiPaths`. Its Git subprocess and bounded fallback walk run with the exact effective cwd, never ambient process cwd, and expose only validated project-relative matches. Search has no persisted index or startup work; session disposal cancels its active operation.

`ResourceLoader.load()` performs bounded discovery and returns a new immutable `SessionResources` value; it does not retain a mutable current catalog. `AgentSession` owns the snapshot admitted to its conversation so its system prompt, command descriptors, and input expansion cannot observe different discovery generations. Explicit skill invocation deliberately reads the discovered file path again, preserving Pi's progressive-disclosure behavior while applying Zi's file bound.

There is no mutable global path registry. `ZiPaths` contains no I/O or lifecycle state, and each settings, credential, session, or resource owner remains responsible for its own files and transitions.

## Consequences

- All cwd-sensitive services agree after session resume.
- Coding-agent global state lives under `$HOME/.zi/agent`, leaving `$HOME/.zi` available as the user-wide Zi product root.
- Files from the short-lived flattened `$HOME/.zi` layout are not scanned or migrated implicitly; callers can move them or set `ZI_AGENT_DIR=$HOME/.zi` explicitly.
- Embedders can replace the full global directory or session directory without changing project resolution.
- Project settings and system prompts remain admitted by default until the project-trust resolver is integrated. The persisted trust owner and protected-configuration detection are present, but no loader reads them independently; runtime gating must switch every project configuration owner together.
- New persisted resources must add their derivation to `ZiPaths` and consume that value; they may not join `.zi` independently.

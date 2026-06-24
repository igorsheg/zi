# File Completion PRD

## Problem Statement

Zi's `@file` completion is currently implemented as a small in-house filesystem scan. It matches Zi's product behavior well, but every request performs blocking filesystem work and the ranking is intentionally simple. We investigated replacing it with FFF's C library, or calling an external tool such as `fd`, but both options add more machinery than the current use case justifies.

From the user's perspective, `@file` completion should stay fast, deterministic, and responsive in large projects without requiring an external binary, Rust/Cargo toolchain, dynamic library lookup, or a second search runtime. It should preserve today's completion behavior while improving repeated-query performance and ranking quality.

## Solution

Build a Zi-owned file completion index inside `coding_agent` and keep the public completion behavior unchanged.

The index should be owned by `SessionRuntime`, scoped to the current project cwd, and queried by the existing file completion request path. It should build lazily on the first `@file` completion request for a session/project slot, using the existing completion worker/coalescing path rather than blocking session startup. Once built, it should keep a bounded resident path table. Ready-index queries should also use the existing completion worker path so `SessionRuntime.step()` never performs project-size ranking work on the TUI foreground path. Walking/indexing stays in Zig. Ranking can initially improve the current matcher, and may later use a small ported fuzzy scorer if that pays rent.

Do not vendor FFF for `@file` completion. Do not require `fd` or any other external child process for the default path. FFF can be reconsidered later as a broader agent search/grep subsystem, not as a drop-in replacement for composer file completion.

## User Stories

1. As a Zi user, I want `@file` completion to return quickly after the first project scan, so that typing file mentions feels responsive.
2. As a Zi user, I want completion behavior to remain deterministic, so that results do not jump around unexpectedly.
3. As a Zi user, I want `src/` to list direct children, so that scoped path browsing remains predictable.
4. As a Zi user, I want a unique directory alias such as `agent/` to descend into that directory, so that I can type partial paths naturally. Alias descent applies only when literal direct listing does not resolve; directory aliases are found from indexed directory leaf names, exact leaf matches beat fuzzy matches, and only one alias resolution step is performed.
5. As a Zi user, I want ambiguous directory aliases to show directory choices, so that I can disambiguate manually.
6. As a Zi user, I want dotfiles hidden until I type a dot or an explicit dot-path scope, so that noisy hidden files do not pollute normal completion.
7. As a Zi user, I want ignored directories such as `.git`, `.zig-cache`, `zig-out`, `node_modules`, and `vendor` skipped, so that completions focus on useful project files.
8. As a Zi user, I want completion to work without installing `fd`, FFF, Cargo, or any other extra tool, so that Zi remains self-contained.
9. As a Zi user, I want completion to behave consistently across print, RPC, and TUI clients, so that the mailbox protocol remains the only client boundary.
10. As a Zi user, I want large repositories to have bounded completion memory use, so that Zi does not grow without limit.
11. As a Zi user, I want large repositories to degrade clearly when caps are reached, so that missing results are reported as truncation rather than silently corrupting state.
12. As a Zi user, I want file completion to preserve valid UTF-8 boundaries, so that UI and protocol strings remain valid.
13. As a Zi user, I want stale indexes to be refreshed only through an explicit owner path, so that file changes do not race query reads. The first implementation does not add watchers, timers, or automatic refresh; the index rebuilds on session/project slot replacement and can later gain an explicit refresh command if needed.
14. As a frontend implementer, I want the existing file completion event shape to stay stable, so that TUI and RPC adapters do not need a new protocol.
15. As a maintainer, I want one owner for the project file index, so that index lifetime and mutation are obvious.
16. As a maintainer, I want one mutation path for index rebuilds, so that query workers cannot mutate shared state unexpectedly.
17. As a maintainer, I want bounded resident state with named limits, so that the feature follows Zi's runtime discipline.
18. As a maintainer, I want tests at the current completion behavior seam, so that implementation can change without locking tests to helper functions.
19. As a maintainer, I want no default external child process dependency, so that completion does not inherit process timeout, cancellation, and packaging problems.
20. As a maintainer, I want vendored code limited to a small ranking algorithm only if needed, so that Zi does not import an entire search runtime for composer completion.
21. As a maintainer, I want FFF evaluated separately for search/grep tools, so that a broader subsystem decision is not smuggled into `@file` completion.
22. As a maintainer, I want the existing blocking worker path respected, so that SessionRuntime remains the mailbox owner and client-facing event order stays stable.
23. As a maintainer, I want allocation failures to propagate as operational failures, so that failed indexing does not corrupt the session owner.
24. As a maintainer, I want deinit to release all indexed path memory, so that session replacement and shutdown do not leak.
25. As a maintainer, I want query results capped by the existing completion item limit, so that public events remain bounded.

## Implementation Decisions

- Keep walking and indexing in Zi-owned Zig code. The default file completion path must not depend on `fd`, FFF, Cargo, or a dynamically loaded library.
- Do not vendor FFF for this feature. FFF does walking, indexing, ranking, frecency, grep, git integration, and watching, but it brings a Rust/Cargo build, C ABI ownership, platform link concerns, and behavior that does not map exactly to Zi's scoped completion UX.
- Treat FFF as a possible future `coding_agent` search/grep service, not as a replacement for composer `@file` completion.
- Add a long-lived project file completion index owned by the mailbox host. The owner should be the same runtime owner that already coalesces file completion requests and emits public completion events.
- Build the index lazily on the first `@file` completion request for a session/project slot. Do not scan during session open. While the first build is in flight, preserve the existing pending-file-completion coalescing behavior and answer the latest relevant query when the index becomes ready. The first iteration should wait for the full bounded index build before emitting file-completion results; do not add partial-result streaming or index-progress protocol. Build failure is an operational completion failure: enqueue rejection for the active request, keep the session alive, store a compact failed state, and allow retry on the next distinct file-completion query.
- Keep ready-index ranking/query work on the existing completion worker path. The mailbox owner installs and replaces indexes, but `SessionRuntime.step()` must not synchronously scan or rank across the project-sized index. Query workers may read an immutable, generation-stable index view while `completion_load` is active and return an owned bounded result; they must not mutate owner state. `SessionRuntime` must join or cancel any active completion load before replacing or deinitializing the index.
- Scope the index to the current project cwd/session slot. Session replacement must build or select the next slot through the owner path and deinit the old index during normal slot cleanup.
- Preserve the existing public result shape: query text, bounded completion items, and truncated flag. Internal APIs may break during the refactor; do not keep compatibility shims or fallback scan paths for private helper shapes.
- Preserve existing completion semantics for scoped paths, directory aliases, hidden files, ignored directories, path labels, details, and deterministic ordering where relevant. Unique directory alias descent should be derived from indexed directory paths: if a literal scoped listing such as `agent/` cannot be resolved and exactly one indexed directory has a matching leaf, list that directory's children; if multiple directories match, return the directory choices. Hidden files and directories should be retained in the index, except ignored subtrees, because dotfile visibility is query-dependent; normal queries hide dot entries, while explicit dot queries or dot-path scopes reveal them.
- Use a bounded resident path table. The first implementation should be a flat immutable table of valid UTF-8 project-relative paths plus entry kind, backed by one bounded path byte buffer. Store paths without a leading `./`; store directory paths without a trailing slash and add `/` only when producing completion items. Initial caps should be `index_entry_count_max = 20_000`, `index_path_bytes_max = 2 * 1024 * 1024`, and `index_path_bytes_per_entry_max = client_protocol.completion_id_bytes_max`. When entry or byte caps are reached, stop adding entries and mark the index truncated. Oversized valid paths should be skipped and mark the index truncated; invalid UTF-8 and permission/stat failures should be skipped without marking truncation.
- Index mutation must happen only at an owner-controlled apply/rebuild site. Query workers may read snapshots or owned immutable views; they must not mutate SessionRuntime state directly.
- Start with a simple in-memory ranking implementation that improves current substring/subsequence behavior without adding a dependency. Keep directory browsing deterministic: direct children only, directories first, lexical tie-breaks, with existing unique directory alias descent and ambiguous alias choices preserved. For non-empty leaf searches, use deterministic scoring categories such as exact leaf, leaf prefix, word/camel/path-boundary prefix, leaf substring, fuzzy subsequence, full-path substring, shorter-path bonus, and a small directory bonus. If ranking quality remains poor, consider porting a small fuzzy scorer such as an fzy-style algorithm to Zig.
- If a small fuzzy scorer is introduced, vendor only the ranking algorithm or port it directly. Do not vendor a full finder/indexer unless a broader search subsystem proves the seam.
- Keep direct directory listing behavior local. A query ending in `/` is product policy for composer completion, not generic fuzzy search. With the flat index, derive direct children at query time from stored path slash positions and deduplicate synthesized child directories in result-local state; do not add a tree/trie for the first implementation.
- Avoid child process fallback for the default path. An optional debug/prototype path may call `fd` or `git ls-files`, but it must not be required for shipped behavior.
- A git-aware file source may be considered later, but it should still feed the Zi-owned bounded index and preserve non-git fallback behavior.
- Keep the first ignore policy as a small built-in ignored-directory name list local to file completion, matching today's behavior: `.git`, `.zig-cache`, `zig-cache`, `zig-out`, `node_modules`, `.cache`, `.direnv`, `.venv`, and `vendor`. Do not add `.gitignore` parsing in the first iteration.
- The slowest resource is filesystem scanning. Scanning should be amortized across queries and should never happen unbounded inside a frontend owner-loop turn.

## Implementation Order

1. Refactor current scan logic behind a new `file_completion.Index` and query API while keeping externally visible completion behavior tests passing. Initially, build the index and query it inside the existing completion worker.
2. Move `SessionRuntime` to own explicit file-index state: lazy build on first `@file` request, pending-query coalescing while building/querying, ready queries through a worker borrowing an immutable index view.
3. Improve ranking with deterministic scoring categories while keeping direct directory browsing stable.
4. Remove the old per-request recursive scan path rather than keeping compatibility layers, fallback paths, or shims. Breaking private APIs is allowed; the stable contract is the public completion event behavior.
5. Add cap, failure, ignored-directory, invalid-UTF-8, and pending-coalescing tests.

## Testing Decisions

- Test at the existing completion behavior seam: submit/build file completion for a temporary project tree and assert public result behavior.
- Prefer existing file completion tests as prior art: direct child listing, unique directory alias descent, ambiguous directory choices, and dotfile visibility.
- Add tests for bounded index truncation: when entry or byte caps are reached, results remain valid and truncation is reported.
- Add tests for deterministic ordering in direct child listing and stable ranking tie-breaks.
- Add tests for ignored directories so that `.git`, build caches, dependency directories, and configured ignored names do not enter the index.
- Add tests for invalid UTF-8 filenames or oversized paths degrading safely rather than crashing or producing invalid protocol strings.
- Add tests for build failure/cap behavior where feasible: individual permission/stat failures are skipped, caps produce a ready truncated index/result, and operational build failure does not tear down the session.
- Add tests for session/runtime ownership behavior at the highest available seam: pending file completion coalescing should still deliver only the latest relevant query result.
- Do not test private helper existence. Tests should assert externally visible completion items, truncation, and event delivery behavior.
- If ranking changes, tests should avoid overfitting exact scores. Assert broad ordering rules and deterministic tie-breaks.

## Out of Scope

- Vendoring FFF's C library for composer completion.
- Requiring `fd`, ripgrep, git, Cargo, or any external binary for default completion.
- Adding grep/content search.
- Adding frecency, query history, or file access tracking.
- Adding filesystem watchers, automatic refresh timers, or partial index refresh in the first iteration.
- Replacing TUI/frontend completion protocol.
- Building a generic project-wide search subsystem.
- Cross-language dynamic library loading or prebuilt binary packaging.

## Further Notes

The recommended seam is a single `coding_agent` file completion index owned by `SessionRuntime` and queried through the existing completion load path. This preserves the current client protocol while allowing the implementation behind completion results to move from per-request scan to amortized indexed queries.

The guiding decision is simple: Zi needs composer `@file` completion, not a full search engine. Build the smallest correct system first. If future agent tools need path search, grep, frecency, git annotations, or live watching, revisit FFF or a similar subsystem as a separate product boundary with its own ownership, bounds, and shutdown contract.

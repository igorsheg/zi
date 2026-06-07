# Builtin Tool Parity Acceptance Criteria

This document defines when Zi's builtin tools are considered aligned enough with
pi-mono. Alignment means matching useful behavior and UX, not porting pi-mono's
architecture.

## Global contract

All builtin tools must satisfy these criteria:

- Tool policy stays in `src/coding_agent/tools` or `src/coding_agent/tool_output_policy.zig`.
- Runtime remains mechanism only: process, cancellation, bounded capture, and drain.
- TUI remains agent-agnostic. Tool/session mapping lives in `src/coding_agent/interactive.zig`.
- Every resident buffer has a named cap and tested overflow behavior.
- Operational input errors return actionable tool output or typed tool errors; they do not crash owner loops.
- Programmer errors fail fast with assertions where appropriate.
- Paths resolve through shared coding-agent path policy; no tool-local cwd containment copies.
- File mutation goes through `FileMutationQueue` only.
- Tool result text is valid UTF-8.
- Truncation details are structured and accurate enough for UI/status rendering.
- `zig build test`, `zig build`, `ziglint`, and `zig fmt --check src` pass.

## Bash

Accepted when:

- Runs in configured cwd with explicit environment.
- Supports configured shell path and command prefix.
- Streams bounded live output.
- Preserves observed stdout/stderr interleaving in final result.
- Final output is tail-truncated to 2000 lines or 50 KiB.
- Timeout, cancellation, nonzero exit, signal/stopped/unknown, and hard output limit are marked as tool errors through structured details.
- Timeout/cancel/output-limit preserve partial output and append status text.
- Truncation metadata includes total/output lines and bytes, max limits, truncatedBy, lastLinePartial, and firstLineExceedsLimit.
- No unbounded output accumulator exists.

Known defer is acceptable only if documented:

- full-output spill file path
- exact 100ms bash-local wall-clock throttle
- generic spawn hook

## Read

Accepted when:

- Uses shared path normalization and existing-path containment.
- Text reads are bounded by input and output caps.
- Offset/limit behavior is explicit and tested.
- Head truncation reports accurate line/byte metadata.
- User-requested limit continuation is not misreported as byte/line truncation.
- Offset beyond EOF reports an actionable operational error.
- Invalid UTF-8 is handled operationally, not leaked into TUI text.
- Image attachments for supported png/jpeg/gif/webp are returned with a text note; APNG is not treated as supported PNG.

Optional/deferred:

- image resizing
- model-vision-specific tool-time policy

## Write

Accepted when:

- Uses shared creatable-path resolution.
- Runs through `FileMutationQueue`.
- Content size is bounded before mutation.
- Parent directory creation and atomic write happen under the mutation guard.
- Result details are consistent and tested, including path and bytes written if exposed.
- TUI preview does not duplicate final content.

## Edit

Accepted when:

- Uses shared existing-path resolution.
- Runs through `FileMutationQueue`.
- Supports exact unique non-overlapping replacements.
- Rejects empty oldText, missing text, duplicate matches, overlap, no-op output, and oversized output with actionable messages.
- CRLF/BOM files can be matched using normalized text and are restored with original line endings/BOM.
- Successful result exposes bounded diff metadata:
  - display diff
  - unified patch
  - firstChangedLine
  - replacement count
- No full-file streamed output is required for normal success once diff metadata exists.

Deferred unless proven needed:

- fuzzy quote/dash/whitespace matching
- remote edit operations

## LS

Accepted when:

- Path is optional and defaults to `.`.
- Limit is optional and capped by config.
- Output is sorted deterministically.
- Empty directory emits a clear message.
- Directory/symlink suffixes are stable and tested.
- Entry vs byte truncation reasons are accurate.
- Sentinel notices never exceed configured output caps.
- Paths use shared existing-path resolution.

## Find

Accepted when:

- Path is optional and defaults to `.`.
- Limit is optional and capped by config.
- Traversal has explicit visited/result caps.
- Output is deterministic for non-truncated result sets.
- `.git` and `node_modules` are ignored/pruned by explicit coding-agent policy.
- No-match output is explicit.
- Entry/files/bytes truncation reasons are accurate.
- Existing substring/name semantics are documented unless glob parity is implemented.

Deferred unless needed:

- full `.gitignore` parsing
- external `fd` dependency
- full glob semantics

## Grep

Accepted when:

- Path is optional and defaults to `.`.
- Limit is optional and capped by config.
- Traversal/file collection is explicitly bounded.
- Search order is deterministic for non-truncated result sets.
- `.git` and `node_modules` are ignored/pruned.
- Literal search works; ASCII `ignoreCase` works if exposed.
- No-match output is explicit.
- Long matching lines are UTF-8-safe truncated and counted.
- Invalid UTF-8 file content cannot produce invalid tool result text.
- Files/matches/bytes/file-size truncation reasons are accurate.

Deferred unless needed:

- regex mode
- context lines
- ripgrep/.gitignore parity

## TUI/tool UX

Accepted when:

- Tool chrome uses open-box shape with separately styled chrome/title/body.
- Tool presentation comes from coding-agent tool metadata.
- Streaming output is sanitized before transcript ingestion.
- Final output is not duplicated after streamed output.
- Write/edit/bash previews are bounded.
- TUI source does not import `coding_agent`, `agent`, `ai`, or `runtime`.

## Done definition

All gaps are considered closed when:

1. Every non-deferred item above has focused tests.
2. Deferred items are listed in this document with rationale.
3. Full gates pass:

```sh
zig build test
zig build
ziglint
zig fmt --check src
```

4. No new boundary violation is introduced.
5. No unbounded resident buffer, queue, traversal, diff, or encoded output remains without a named cap and tested overflow behavior.

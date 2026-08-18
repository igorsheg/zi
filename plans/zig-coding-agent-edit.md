# Add bounded exact multi-edit

**Status:** Implemented and verified
**References:** Pi `73414d08b94d7db46d3fa66582c8fe3b02dabf72`; ZigAI as the Zig implementation model
**Scope:** Exact, all-or-nothing edits for existing UTF-8 files through the existing OpenAI-compatible and OpenAI Codex paths

## Intent

`AgentSession` can inspect and completely rewrite files. This slice adds precise edits without exposing a transient single-replacement interface or copying Pi's TUI diff metadata.

The public shape follows Pi's current `edits[]` contract. Every replacement is matched against the same original file, must be unique, and must not overlap another replacement. All matches are admitted before one write occurs, so a semantic failure leaves the file unchanged.

## Interface

```json
{ "path": "src/main.zig", "edits": [{ "oldText": "const old = true;", "newText": "const updated = true;" }] }
```

Success:

```text
Successfully replaced 1 block(s) in src/main.zig.
```

`oldText` is non-empty and exact after line-ending normalization. `newText` may be empty. Replacements are located in the original content, sorted by source position, checked for overlap, and applied in reverse/source order without incremental matching.

## Text behavior

- Validate the source as UTF-8.
- Preserve an initial UTF-8 BOM but exclude it from matching.
- Normalize CRLF and lone CR to LF for matching.
- Normalize `oldText` and `newText` the same way.
- Restore the source file's first observed newline style when writing.
- Reject missing text, duplicate text, empty `oldText`, overlapping/nested edits, and a final no-op.

Pi's fallback fuzzy normalization for trailing whitespace, NFKC, smart quotes, dashes, and special spaces is deliberately deferred. The model-visible contract remains exact.

## Bounds

- Raw arguments: 1 MiB.
- Path: 4,096 bytes.
- Source file: 8 MiB.
- Final file including BOM/restored line endings: 8 MiB.
- Replacements per call: 64.

Malformed input and ordinary filesystem/semantic failures are bounded model-visible failures. OOM, cancellation, and deadline expiry remain fatal. Cancellation is checked before reading, after reading, and immediately before mutation. Once the final write succeeds, the operation settles as success without another fallible or cancellation step.

## Ownership and program design

Add `src/coding_agent/tools/EditTool.zig` as one deep concrete executor. It owns parsing, bounded reading, text normalization, match admission, transformation, restoration, and one settled write.

Extend the existing stable allocation:

```zig
const Tools = struct {
    read: ReadTool,
    write: WriteTool,
    edit: EditTool,
};
```

`AgentSession` keeps the same lifecycle: allocate tool storage, admit erased views, deinitialize `Agent`, then destroy storage. No registry, generic patch engine, public diff type, filesystem adapter, or global mutation queue is added.

## Instructions

The fixed coding policy says:

- read an existing file before editing;
- use `edit` for precise changes to existing files;
- combine disjoint changes to one file in one call;
- keep each `oldText` small but unique and exact;
- never overlap or nest replacements;
- use `write` only for new files or complete rewrites;
- do not claim shell access.

## Behavior tests

1. One unique replacement.
2. Multiple disjoint replacements matched against the original file.
3. Untouched content preservation.
4. LF edit text against CRLF source with CRLF restoration.
5. UTF-8 BOM preservation.
6. Missing, duplicate, empty-oldText, overlap, and no-op rejection.
7. No partial write when any replacement fails.
8. Argument, path, source, final-result, and edit-count bounds.
9. Relative, absolute, and parent-traversal paths.
10. Filesystem failures and pre-cancellation.
11. `AgentSession` read → edit → read loop with exact persisted bytes, instruction propagation, and canonical history.

## Deferred

Fuzzy Unicode/whitespace matching, diff/patch metadata, TUI previews, backups, rollback, atomic replacement, cross-session mutation coordination, shell execution, and broader providers are outside this slice.

## Acceptance

- A supported model can inspect an existing file, apply one or more exact validated replacements, and read back the exact result.
- Semantic failures never partially apply admitted replacements.
- Final files remain readable by the bounded `read` tool.
- Tool pointers and session policy remain stable and truthful.
- Build, debug and ReleaseSafe tests, lint, diff checks, and focused review pass.

**Verification:** `zig build`; 89/89 debug and ReleaseSafe tests; `ziglint`; `git diff --check`; independent re-review with no findings.

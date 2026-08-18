# Add bounded file writes

**Status:** Implemented and verified
**References:** Pi `73414d08b94d7db46d3fa66582c8fe3b02dabf72`; ZigAI as the Zig implementation model
**Scope:** Create and completely rewrite UTF-8 files through the existing OpenAI-compatible and OpenAI Codex coding-agent paths

## Intent

`AgentSession` can inspect files but cannot yet perform coding work. This slice adds Pi's `write` behavior without introducing partial edits, shell execution, provider expansion, or a generic filesystem framework.

A successful write creates missing parent directories, creates or completely overwrites the target, and reports the number of UTF-8 bytes written. Relative paths resolve through the session directory; absolute paths and `..` remain allowed because the coding agent has Pi-like trusted local authority.

## Ownership and program design

Two erased tool contexts require stable storage after `AgentSession.init` returns. One heap allocation owns both concrete implementations:

```zig
const Tools = struct {
    read: ReadTool,
    write: WriteTool,
};

allocator: std.mem.Allocator,
tools: *Tools,
agent: Agent,
```

`AgentSession` allocates `Tools`, admits views over `tools.read` and `tools.write`, deinitializes `Agent`, then destroys `Tools`. There is no registry or manager.

```diff
 src/coding_agent/tools/WriteTool.zig
+  cwd-bound concrete write executor

 src/coding_agent/AgentSession.zig
-  read_tool: *ReadTool
+  tools: *Tools
~  admit read and write
~  truthful read/write coding instructions
```

## Model-visible contract

Schema fields:

- required `path: string` — relative or absolute target path
- required `content: string` — complete file contents
- no additional properties

Description:

`Write content to a file. Creates the file if it doesn't exist, overwrites it if it does, and creates parent directories automatically.`

Success:

```text
Successfully wrote 123 bytes to src/main.zig
```

Zi reports UTF-8 bytes rather than Pi's JavaScript UTF-16 string length.

## Bounds and failures

- Raw tool arguments are limited to 1 MiB before JSON parsing.
- Paths are non-empty and limited to 4,096 bytes.
- JSON parsing rejects invalid UTF-8 path or content strings before filesystem mutation.
- Empty content is valid and truncates or creates an empty file.
- Malformed arguments and ordinary directory/write failures are bounded model-visible failures.
- OOM, cancellation, and deadline expiry remain fatal.
- Cancellation is checked before directory creation and immediately before the final write. Once the write succeeds, the operation settles as success without another fallible or cancellation step.

The generic agent already executes admitted calls serially. Its controlled execution uses `std.Io.Select.cancelDiscard`, which blocks until outstanding work settles, so this slice does not add a mutation queue. Per-path coordination waits for actual parallel mutation pressure.

## Instructions

The fixed session policy now says:

- use `read` to inspect files and continue truncated reads with `offset`;
- use `write` only for new files or complete rewrites;
- read an existing file before overwriting it;
- do not claim edit or shell capabilities.

A dynamic prompt builder remains deferred while every session admits the same fixed tools.

## Behavior tests

1. Create a relative file and missing parent directories.
2. Overwrite an existing file exactly.
3. Write empty content.
4. Write through an absolute path.
5. Reject malformed, missing, extra, empty-path, overlong-path, and oversized arguments.
6. Return directory-target failures to the model.
7. Honor pre-cancellation without filesystem mutation.
8. Run `write` then `read` through `AgentSession`; verify the following model requests receive the write result and exact persisted bytes, instructions remain present, and canonical history contains both tool interactions without instruction messages.

## Deferred

Partial edits, diffs, backups, rollback, atomic replacement, permission policy, TUI rendering, generic filesystem adapters, mutation queues, and broader providers are outside this slice.

## Acceptance

- A supported model can create or completely rewrite a UTF-8 file and read back the exact bytes in one session.
- All input and output remain bounded by their owning modules.
- Tool implementation pointers remain stable for the session lifetime.
- Instructions truthfully describe the admitted read/write surface.
- Build, debug and ReleaseSafe tests, lint, diff checks, and focused review pass.

**Verification:** `zig build`; 81/81 debug and ReleaseSafe tests; `ziglint`; `git diff --check`; independent review with no findings.

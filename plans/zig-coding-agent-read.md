# Start the Zig coding-agent with bounded file reading

**Status:** Implemented and verified
**References:** Pi `73414d08b94d7db46d3fa66582c8fe3b02dabf72`; ZigAI as the Zig implementation model
**Scope:** First coding-agent vertical slice; no provider expansion
**Verification:** `zig build`; 72/72 debug and ReleaseSafe tests; `ziglint`; `git diff --check`

## Product intent

The Zig model and generic agent layers can already stream OpenAI-compatible and OpenAI Codex responses through a provider-independent tool loop. The next slice proves that this substrate can support coding-agent behavior rather than accumulating model-layer features without a product consumer.

A caller will construct one client-independent `AgentSession` bound to a working directory and either supported model. A scripted or real model can call `read`, receive bounded file contents, and continue to a streamed final response. The session exposes the generic agent's canonical history; it does not copy it.

This slice handles UTF-8 text files. Image reads, system-prompt assembly, persistence, retries, compaction, model switching, CLI modes, and TUI behavior remain later slices.

## Reference decisions

Pi specifies the observable read behavior:

- Tool name `read`.
- Required `path`; optional one-based `offset` and positive `limit`.
- Relative and absolute paths are accepted. Relative paths resolve through the session working directory; `..` is not artificially confined.
- Output keeps complete lines and is bounded to 2,000 lines or 51,200 bytes, whichever is reached first.
- User limits produce an actionable continuation offset.
- An offset beyond the file reports the requested offset and total line count.
- Ordinary file and argument failures become model-visible tool failures; cancellation, timeout, and allocation failure terminate the run.

Zi deliberately does not copy these incidental Pi behaviors:

- Negative, fractional, and zero offsets or limits accepted by a permissive TypeBox number schema.
- Inconsistent trailing-newline line counts between selection and truncation.
- A first-line overflow message that recommends `bash` before the Zig coding-agent exposes a bash tool.
- macOS screenshot-name heuristics, `file://`, `@`, and home expansion before a Zig path owner exists.
- Pi-TUI rendering, syntax highlighting, collapsed previews, and key hints.

ZigAI supplies the implementation shape:

- A concrete cwd-bound read implementation erased through the existing `agent.Tool` seam.
- Explicit `std.Io`, allocator, cancellation, and deadline flow.
- Borrowed requests and a bounded per-call result copied into Agent-owned canonical history.
- One named owner and one `deinit` boundary for session resources.

## Existing owners

- `src/ai` owns model/provider/protocol/transport behavior.
- `src/agent/Agent.zig` owns run state, canonical history, limits, model invocation, tool dispatch, and streaming.
- `src/agent/Tool.zig` owns the erased tool contract and admitted catalog.
- The new `AgentSession` owns coding-agent composition and the concrete read-tool lifetime.
- The caller owns the selected `Model` implementation and working-directory handle; both outlive the session.

`AgentSession` will not introduce another history, tool catalog, model registry, event stream, or run state.

## Program design

### File tree

```diff
 src/
+├── coding_agent/
+│   ├── AgentSession.zig
+│   ├── root.zig
+│   └── tools/
+│       └── ReadTool.zig
 └── root.zig
```

`ReadTool` stays internal to `coding_agent` until a second real caller requires direct construction.

### `AgentSession`

```zig
const AgentSession = @This();

allocator: std.mem.Allocator,
read_tool: *ReadTool,
agent: Agent,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    cwd: std.Io.Dir,
    limits: agent.RunLimits,
    events: ?Agent.EventSink,
) !AgentSession

pub fn deinit(self: *AgentSession) void
pub fn prompt(self: *AgentSession, input: []const u8) Agent.RunError![]const u8
pub fn promptWithControl(self: *AgentSession, input: []const u8, control: Agent.RunControl) Agent.RunError![]const u8
pub fn promptStream(self: *AgentSession, input: []const u8, sink: Agent.StreamSink) Agent.RunError![]const u8
pub fn messages(self: *const AgentSession) []const ai.Message
pub fn state(self: *const AgentSession) Agent.State
```

The read implementation is allocated separately so the generic tool catalog never retains a pointer into a movable `AgentSession` value. `deinit` releases the generic agent first, then destroys the read implementation it borrowed.

The working-directory `std.Io.Dir` is borrowed. `AgentSession` never closes it.

### `ReadTool`

```zig
const ReadTool = @This();

cwd: std.Io.Dir,

pub fn asTool(self: *ReadTool) agent.Tool

pub fn execute(
    self: *ReadTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    control: agent.Tool.RunContext,
    arguments_json: []const u8,
) agent.ToolFatalError!agent.ToolExecution
```

The model-visible definition is text-only for this slice:

```text
Read a UTF-8 text file. Paths may be relative to the session working directory or absolute. Output is limited to 2000 lines or 50KB, whichever is reached first. Use offset and limit to continue through large files.
```

Arguments are decoded once at the tool boundary into:

```zig
const Arguments = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
};
```

`path` must be non-empty. Present offsets and limits must be greater than zero. Unknown fields and malformed JSON are rejected as model-visible failures.

### Read and truncation flow

```text
AgentSession.prompt[Stream]
  Agent.run[Stream]
    model emits read call
    Tool catalog resolves read
    ReadTool decodes semantic arguments
    ReadTool checks cancellation
    cwd opens and reads the requested file with std.Io
    ReadTool validates UTF-8
    ReadTool selects offset/limit
    ReadTool retains complete lines under 2,000 lines and 51,200 bytes
    ReadTool checks cancellation
    Agent deep-copies the result into canonical history
    model receives tool result and produces final text
```

The first implementation may read at most 8 MiB into its per-call arena. A larger file returns a bounded model-visible failure. This prevents a local file from causing unbounded allocation while leaving the common source-file path direct. A later streaming scanner may remove this file-size limit without changing the tool contract.

Line semantics are coherent and explicit:

- Lines are separated by `\n`; `\r` remains part of CRLF content.
- A terminal newline is preserved but does not create another numbered line.
- An empty file returns empty content for offset 1.
- Output never contains a partial UTF-8 sequence or partial line.

Continuation text follows Pi where the behavior is intentional:

```text
[Showing lines 1-2000 of 2500. Use offset=2001 to continue.]
[Showing lines 1-N of 500 (50.0KB limit). Use offset=N+1 to continue.]
[90 more lines in file. Use offset=11 to continue.]
Offset 100 is beyond end of file (3 lines total)
```

A selected first line larger than 51,200 bytes returns a read-only diagnostic stating that the line exceeds the 50.0KB limit; it does not recommend an unavailable tool.

## Vertical implementation slices

### Slice A: tool behavior

Implement `ReadTool` and inline behavior tests for:

- Exact relative and absolute UTF-8 reads.
- Empty files, terminal newline, and CRLF.
- Offset, limit, and offset-plus-limit.
- Line and byte truncation with exact continuation messages.
- Oversized first line.
- Missing file, directory, invalid UTF-8, malformed arguments, and the 8 MiB input bound.
- Pre-cancelled execution.

Verification: `zig build test` and `ziglint` pass with only the new tool imported by its module test block.

### Slice B: coding-agent composition

Implement `AgentSession`, export `coding_agent` from `src/root.zig`, and add one integration scenario:

1. A temporary working directory contains `src/main.zig`.
2. `ScriptedModel` requests `read` with a relative path, then returns final text.
3. `AgentSession.promptStream` completes through the existing stream path.
4. Canonical history contains user request, tool call, real file result, and final response.
5. The second model request sees the real file contents through the ordinary tool-result path.

Verification: `zig build test`, `ziglint`, and inspection of the focused diff.

## Acceptance

This slice is complete when:

- `zi.coding_agent.AgentSession` works with any existing `ai.Model`, including OpenAI-compatible and OpenAI Codex model views.
- The model can read a real UTF-8 file through the existing provider-independent tool loop.
- Read output follows the reviewed Pi-derived bounds and continuation behavior.
- The session owns no duplicate canonical state.
- Tool implementation storage remains stable for the complete session lifetime.
- All allocations and borrowed resources have one documented owner.
- `zig build test` and `ziglint` pass.

## Deferred pressure

The next slices should be selected by coding-agent behavior, not provider breadth: system instructions, `write`, `edit`, `bash`, print mode, persistence, model switching/handoff, and retry. The generic model layer changes only when one of those slices demonstrates a concrete need.

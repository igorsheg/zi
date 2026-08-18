# Propagate coding-agent instructions

**Status:** Implemented and verified
**References:** Pi `73414d08b94d7db46d3fa66582c8fe3b02dabf72`; ZigAI as the Zig implementation model
**Scope:** Read-only coding policy for the existing OpenAI-compatible and OpenAI Codex paths

## Intent

`AgentSession` currently exposes a real read tool, but the generic `Agent` sends no instructions. Scripted models call the tool because tests prescribe the call; real models do not yet receive a truthful coding-agent identity or read policy.

This slice makes coding policy an `AgentSession` responsibility and carries borrowed immutable instructions through `Agent` into every `ModelRequest`. Instructions remain outside canonical conversation history.

## Ownership

- `AgentSession` owns the coding-agent policy and its lifetime.
- `Agent` borrows an immutable instruction slice and attaches it to every model request.
- Provider codecs retain their existing responsibility for wire encoding.
- `History` remains the sole owner of canonical user, assistant, and tool messages; it never receives instructions.

The initial policy has static lifetime. Dynamic prompt generations will become `AgentSession`-owned allocations only when admitted tools and project resources require them.

## Program design

```diff
 src/agent/Agent.zig
+  instructions: []const []const u8
~  init(..., instructions, tools, ...)
~  invokeModel -> ModelRequest.instructions

 src/coding_agent/AgentSession.zig
+  static truthful read-only coding instructions
~  Agent.init(..., &coding_instructions, ...)

 src/ai/testing.zig
~  replace context-free request callback with an instance-scoped observer
```

The policy says only what the current surface supports:

- Act as a coding agent.
- Inspect relevant files before drawing conclusions.
- Use `read` rather than guessing file contents.
- Continue truncated reads with `offset`.
- Do not claim to modify files because no mutation tool is available.

It does not mention write, edit, bash, skills, compaction, or other unavailable capabilities.

## Behavior tests

1. The first request receives the coding instructions.
2. The request after a read tool result receives the same instructions and the real tool result.
3. A later prompt in the same session receives the same instructions.
4. Canonical history remains only user, assistant, and tool traffic.
5. OpenAI Chat encodes instruction entries as system messages.
6. OpenAI Codex joins instruction entries in its `instructions` field.
7. Generic agents constructed with no instructions preserve current behavior.

## Acceptance

- Instructions propagate through every request without provider branches.
- `AgentSession` is the coding-policy owner.
- No instruction is persisted as a canonical message.
- Both supported protocols encode the propagated policy through their existing codecs.
- Build, debug and ReleaseSafe tests, lint, and diff checks pass.

**Verification:** `zig build`; 72/72 debug and ReleaseSafe tests; `ziglint`; `git diff --check`; independent review with no findings.

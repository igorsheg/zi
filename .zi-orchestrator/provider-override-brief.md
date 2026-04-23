You are the implementing agent for the next extension v2 slice in /Users/igors/workspace/dev/personal/zi.

Model: use openai-codex/gpt-5.4 for this task.

## Mission
Close the next highest-value runtime-truth gap in extension v2 around provider overrides by validating and, if needed, fixing **provider override precedence and restoration semantics**.

This is on the critical path for:
- zi-fex (extension system v2 epic)
- zi-fex.2 (runtime roots / discovery / precedence / settings package seam)

## Why this slice now
Recent work already landed:
- commands api cutover
- providers api cutover
- provider claim model metadata retention
- visible model catalog rebuild
- claim-backed provider auth config
- claim-backed provider oauth login
- built-in provider override-only claims

The next thing we need is **truthful precedence / collision / restoration behavior**, especially for built-in visible providers and generation teardown flows. Do not widen into auth_header, custom stream handlers, extension-defined oauth callbacks, or general UI work.

## Read first
Read these before changing code:
1. /Users/igors/workspace/dev/personal/zi/docs/runtime-roots.md
2. /Users/igors/workspace/dev/personal/zi/docs/extensions-providers.md
3. /Users/igors/workspace/dev/personal/zi/.beads/issues.jsonl around zi-fex and zi-fex.2 if needed
4. /Users/igors/workspace/dev/personal/zi/src/ai/provider.zig
5. /Users/igors/workspace/dev/personal/zi/src/coding_agent/extensions/api.zig
6. /Users/igors/workspace/dev/personal/zi/src/coding_agent/extensions/runner.zig
7. /Users/igors/workspace/dev/personal/zi/src/coding_agent/model_registry.zig

## Scope
Audit the current implementation of provider claims and built-in provider overrides against the contract, then implement the smallest truthful fix if there is a gap.

Prioritize these behaviors:
1. **provider-name precedence is deterministic**
   - claims resolve by provider name first
   - built-in visible providers (`anthropic`, `openai`, `openrouter`, `openai-codex`) do not leak overrides across other providers in the same api family
2. **restoration is deterministic**
   - unregister restores the next surviving claimant if one exists
   - otherwise restores the baseline built-in provider
3. **generation teardown is truthful**
   - removing claims for one generation does not drop surviving claims from another generation
   - after teardown, runtime provider view and visible model catalog both reflect the surviving winner
4. **visible model truth stays honest**
   - built-in override-only claims should preserve the built-in visible provider identity where the current contract says they should
   - claim-backed visible models should still publish the honest provider identity

## Strong hint
There are already relevant tests in:
- src/ai/provider.zig
- src/coding_agent/extensions/api.zig
- src/coding_agent/model_registry.zig

Use those as anchors. The best outcome is probably:
- 1-3 focused boundary tests total
- plus the smallest implementation fix needed

Remember project testing policy:
- no test spray
- max 3-5 tests per task
- every test name states behavior
- boundary tests only

## What not to do
- Do not widen into new provider surface area (`auth_header`, `modifyModels`, custom oauth callbacks, custom stream handlers)
- Do not refactor unrelated extension subsystems
- Do not paper over a mismatch with docs-only changes if runtime behavior is still wrong
- Do not add compatibility shims

## Deliverable
Either:
A. a minimal code fix + focused tests that make provider override precedence/restoration truthful
or
B. if the runtime is already truthful, add only the minimum missing focused tests that prove it and report clearly that no implementation change was needed

## Validation
Run only focused validation for touched behavior. Likely candidates:
- zig test src/ai/provider.zig
- zig test src/coding_agent/extensions/api.zig
- zig test src/coding_agent/model_registry.zig
If those direct file invocations are not the right form in this repo, use the smallest equivalent targeted command(s).

## Report back
When done, send a message back to orchestrator pane %9 using tmux, exactly one short line, including:
- DONE or BLOCKED
- files changed
- tests run

Example:
`tmux send-keys -t %9 "DONE provider override slice | files: ... | tests: ..." Enter`

Then stop.

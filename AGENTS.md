Issue tracking: `bd prime`

## Reference Code

pi-mono is cloned locally at `.references/pi-mono/`. When you need to reference pi-mono source (types, implementations, patterns), always use local reads/greps against `.references/pi-mono/` - never the github tools. The code is on disk.

opentui is cloned locally at `.references/opentui/`. When you need to reference opentui source (zig TUI patterns, buffer/renderer/utf8), always use local reads/greps against `.references/opentui/` - never the github tools. The code is on disk.

## Testing

**NO test spray.** we do not generate tests per-function. we test behavior at boundaries.

- **max 3-5 tests per task.** if you need more, the task is too big or you're testing implementation.
- **every test name states the behavior it verifies.** `test "session round-trips all 9 entry types"` not `test "parseEntry works"`.
- **a test that can't break when behavior changes shouldn't exist.**

# Durable counter extension

This extension demonstrates Zi's durable session operations:

- `getSessionEntries()` restores extension state during `session_start`;
- `appendEntry()` records model-invisible state;
- `sendMessage()` queues a displayed, model-visible custom message while a tool is running.

Copy `index.ts` into `$HOME/.zi/agent/extensions/durable-counter/index.ts` or a trusted `<cwd>/.zi/extensions/durable-counter/index.ts`.

The counter is scoped to one Zi session. Compaction may fold old conversation messages, but the bounded custom-state history remains available when that session resumes.

# Durable counter extension

This extension demonstrates commands, tools, and durable session operations:

- `getSessionEntries()` restores extension state during `session_start`;
- `appendEntry()` records model-invisible state;
- `/counter show|increment|reset` changes state and returns transient, model-invisible local feedback;
- the `increment_counter` model tool queues a displayed, model-visible custom message.

Copy `index.ts` into `$HOME/.zi/agent/extensions/durable-counter/index.ts` or a trusted `<cwd>/.zi/extensions/durable-counter/index.ts`.

The counter is scoped to one Zi session. Compaction may fold old conversation messages, but the bounded custom-state history remains available when that session resumes or after `/reload` replaces the extension worker.

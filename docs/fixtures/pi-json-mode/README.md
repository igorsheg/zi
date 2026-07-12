# Pi JSON-mode characterization fixtures

Behavioral authority: `.references/pi` commit
`81de5702c6816538ea97d05d9060fe435b80bf35`.

`metadata.json` records the pinned source and permitted nondeterministic
normalization. `event-orders.json` records normalized order and `key-sets.json`
records exact required/optional field names from the pinned agent-loop,
agent-session, print-mode source, and their focused tests. Repeated
`message_update` events are represented by one label; no other records are
coalesced.

Source/test characterization established these details that matter to Zi:

- print mode writes the current session header before subscribing, including
  the header owned by an in-memory session;
- JSON assistant failures remain a zero-status event stream, while text mode
  returns non-zero and writes the assistant error to stderr;
- retry recovery calls `agent.continue()`, so later retry lifecycles do not
  replay the original user message;
- successful retry emits `auto_retry_end` while handling the successful
  assistant `message_end`, before that run's `turn_end` and `agent_end`;
- `agent_settled` occurs once after retry and automatic compaction policy;
- `entry_appended` is emitted for extension custom entries, not ordinary
  persisted message entries, so Zi does not emit it for normal prompts.

No disagreement between the pinned source and its focused tests was found.
Pi-only extension, session-name, and tree event sources remain unsupported and
are intentionally absent from Zi fixtures.

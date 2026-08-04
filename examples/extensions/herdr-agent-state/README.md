# Herdr agent-state extension

This extension reports a Zi interactive session to a Herdr pane through Herdr's local socket API. It maps:

- `agent_start` to `working`;
- `agent_settled` to `idle`.

It also reports the Zi session identity on `session_start`. Journaled sessions include `agent_session_path`; in-memory sessions include only `agent_session_id`. Reports use `source: "herdr:zi"` and `agent: "zi"`.

## Install

Copy `index.ts` into `$HOME/.zi/agent/extensions/herdr-agent-state/index.ts`:

```bash
mkdir -p "$HOME/.zi/agent/extensions/herdr-agent-state"
cp examples/extensions/herdr-agent-state/index.ts \
  "$HOME/.zi/agent/extensions/herdr-agent-state/index.ts"
```

Herdr must launch Zi with its normal integration environment:

```text
HERDR_ENV=1
HERDR_SOCKET_PATH=<Herdr socket path>
HERDR_PANE_ID=<pane id>
```

The extension remains dormant unless all three values are present, and it ignores Zi's text, JSON, RPC, and embedded modes. Delivery uses newline-delimited JSON over the Unix socket or Windows named pipe, a 500 ms first attempt, one 1500 ms retry, monotonic sequence numbers, and latest-state coalescing. Socket failures are observational and do not fail an agent turn.

Zi does not report Herdr's `done` state; Herdr derives it from an unseen idle transition. Zi also does not report `blocked`, because Zi does not yet expose an authoritative user-attention lifecycle.

Herdr can display `zi` as a custom reported agent. Exact process-exit cleanup, `herdr agent start --kind zi`, and journal restoration additionally require Herdr to recognize Zi as an agent process.

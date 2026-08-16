# Orchestrate a recursive agent

This extension registers `/delegate-evidence`. The command uses the same six-operation `zi.agents` API as Code Mode and spawns one built-in `explorer`; it does not register a profile or hidden instruction layer.

Copy the directory to:

```text
$HOME/.zi/agent/extensions/recursive-agent/
```

Alternatively place it under `<cwd>/.zi/extensions/recursive-agent/` and trust that project configuration. Start a session or run `/reload`, then invoke `/delegate-evidence <question>`.

The command returns the durable path immediately. Final agent content arrives as session mail, and `zi.agents.wait()` can observe that activity without consuming the completion. See [`docs/subagents.md`](../../../docs/subagents.md) for recursive lineage, built-in types, execution overrides, and bounds.

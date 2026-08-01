# Programmatic subagent profile

This extension declares one `finder` profile. Zi admits it into the same catalog as Markdown profiles and, when child execution is available, exposes the standard subagent tools automatically. The extension registers no glue tool.

Copy the directory or `index.ts` into a global extension location:

```text
$HOME/.zi/agent/extensions/subagents/index.ts
```

Alternatively place it under `<cwd>/.zi/extensions/subagents/index.ts` and trust that project configuration. Start a new Zi session or run `/reload`, then ask Zi to list the admitted subagent profiles or delegate a bounded search. The model-facing catalog will contain `list_subagent_profiles`, `spawn_subagent`, and the other standard orchestration tools.

The omitted model and thinking fields inherit the parent session's current selections. See [`docs/subagents.md`](../../../docs/subagents.md) for the Markdown counterpart, precedence, bounds, and lifecycle contract.

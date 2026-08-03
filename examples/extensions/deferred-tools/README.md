# Deferred tools extension

Registers a small catalog while exposing only `tool_search` initially. Calling `tool_search` with a query containing `rule` activates `repository_rule` before the next model step.

Run it without installing dependencies:

```bash
zi --extension ./examples/extensions/deferred-tools/index.ts
```

Runtime selection is scoped to this extension. Reload restores the registration defaults.

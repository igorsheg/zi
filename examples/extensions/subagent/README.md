# Reviewer subagent type

A declarative extension that adds a `reviewer` type to Zi's native subagent tools. The extension supplies only the type's description and instructions; Zi owns child processes, RPC, lifecycle, and shutdown.

## Use

Load the extension directly:

```sh
zi --extension /absolute/path/to/examples/extensions/subagent
```

Then ask Zi to delegate a review, or call `spawn_subagent` with `type: "reviewer"`.

To install it for one project, copy `index.ts` to:

```text
<project>/.zi/extensions/reviewer/index.ts
```

The reviewer is instructed to inspect without editing and to return findings with paths and line numbers.

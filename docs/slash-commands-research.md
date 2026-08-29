# Slash-command research

Status: awaiting review

References:

- hax product and behavior: `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- zig-ai Zig design reference: `e2c5aef5f93015322891028a2048a217e7081687`

## Goal

Add hax's interactive command layer without turning the REPL into a collection of
special cases. hax defines observable behavior. zig-ai informs Zig 0.16 ownership,
erased interfaces, registry design, and tests.

The first useful product milestone is `/help`, `/model`, `/effort`, and `/provider`.
It must leave ordinary prompts and the provider-independent agent loop unchanged.

## Current Zi flow

`src/cli/PrintRun.zig` is the process composition root. It owns startup config,
`ProviderRuntime.Owned`, tools, the session, durability, renderers, and terminal
state. It passes borrowed dependencies into `Interactive.run`.

`src/cli/Interactive.zig:367` runs the REPL. A submitted line is borrowed from an
owned terminal result at line 396, sanitized, copied into the session at line 427,
and then sent through `agent.Loop.run`. There is no interception point for commands.
Every non-empty line currently becomes model context.

The interactive provider and model are fixed fields in `Interactive.Inputs`. A
command cannot replace them safely for the next turn. Effort has a dynamic source,
but provider, model metadata, image policy, prompt assembly, tools, compaction, and
session selection all depend on the startup selection.

Useful existing seams:

- `src/terminal/Picker.zig:233` is a reusable synchronous normal-buffer picker.
- `src/cli/SessionPicker.zig` shows how to adapt domain values to borrowed picker
  items with an arena and a parallel source-index map.
- `src/agent/Session.zig:153` can reconfigure owned selection metadata while keeping
  conversation items.
- `src/SessionDurability.zig:141` coordinates selection changes between the live
  session and append log.
- `src/ProviderRuntime.zig` owns stable provider configuration and erased provider
  handles, but does not support general provider replacement.
- `src/ToolRuntime.zig` can update run effort, but not provider or model.
- Codex can enumerate models. The shared catalog and local-discovery paths currently
  reduce model data to exact lookup or reconciliation rather than retaining a
  provider-neutral model list.
- `sort_models` configuration already exists, but no selection path consumes it.

## hax behavior to preserve

The registry in hax `src/slash.c:86` defines lookup and help order. Dispatch starts
at `slash_dispatch` on line 266.

Parsing:

- A command begins only when `/` is byte zero.
- The name is non-empty and contains ASCII letters, digits, `_`, or `-`.
- Names are case-sensitive.
- Whitespace ends the name. Leading argument whitespace is removed; the remainder
  is borrowed unchanged.
- `/`, `/help.txt`, absolute paths, and malformed command tokens remain ordinary
  prompts.
- A valid unknown command is consumed and reports an error.
- A known no-argument command with an argument is consumed and reports bad usage.
- Consumed command lines enter prompt recall but never model context or session
  conversation items.

Selection:

- `/model` enumerates the live provider's models, handles unsupported, failed,
  empty, singleton, and multi-model results separately, then selects effort.
- Model rows preserve provider order or use hax's `model_id_order` policy from
  `src/model_sort.c:83`. Advisory limitations dim rows but do not make them
  unselectable.
- `/effort` includes a distinct `default` choice and uses model/provider metadata.
- `/provider` probes registered providers, lets unavailable entries remain
  selectable, constructs a candidate, and runs model then effort selection before
  committing it.
- Cancellation and failure leave the old live provider, model, effort, metadata,
  preset, and config tiers intact.
- Successful explicit selection exits the active preset, updates the live session,
  persists provider/model/effort, and announces the resulting selection.
- Persistence failure keeps the live choice and warns that it applies only to the
  current run.
- Selection metadata reaches a recorded session only when a later conversation item
  is appended. Opening and cancelling selectors must not modify history.

The C implementation's global config pointers, empty-string sentinels, locale-aware
`isalnum`, and temporary global metadata replacement are not contracts to copy.

## zig-ai guidance

zig-ai keeps registries and dispatchers small and explicit:

- `src/model.zig:267` uses a borrowed declaration plus `*anyopaque` and function
  pointers for erased tools.
- `src/capability.zig:136` uses an ordered borrowed registry with deterministic
  validation and owned resolution results.
- `src/agent.zig:5493` validates duplicate names before execution.
- `src/agent.zig:5683` performs exact case-sensitive lookup.
- Static declaration order stays explicit. This is better for help order and aliases
  than namespace reflection from `src/reflect.zig:160`.
- Runtime data is prepared for one operation in a bounded arena. Static declarations
  remain allocation-free.
- Events and callback inputs are borrowed only during synchronous delivery. Anything
  retained becomes explicitly owned.
- Tests use tiny local implementations behind erased interfaces, verify that failed
  preflight never invokes a handler, and cover allocation failure for owned plans.

For Zi, this points to an explicit compile-time command descriptor array, a tiny
erased synchronous handler, exact lookup, startup validation, tagged dispatch
outcomes, and bounded per-dispatch ownership. We should not import zig-ai's JSON
schema, policy pipeline, reflection, or concurrent tool machinery into slash commands.

## Architectural constraints

1. `agent` must not know commands or CLI selection. It should still receive one
   immutable provider turn snapshot.
2. `Interactive.run` should only decide whether a line is a command or prompt. It
   should not own provider reconstruction or command-specific policy.
3. The process-level command owner must have a stable address and outlive the REPL.
4. Provider changes need candidate ownership and commit-on-success semantics. Never
   destroy the current runtime before the candidate, model, effort, prompt, tools,
   session, and durability updates are known to be valid.
5. A per-turn runtime snapshot should borrow provider, model, metadata, effort, and
   image policy only until `agent.Loop.run` returns.
6. Generic model enumeration belongs in `ai`, not `cli`. Picker formatting and model
   sorting belong outside providers.
7. Configuration persistence is currently read-oriented. Hax-compatible durable
   selection needs an explicit bounded state writer rather than ad hoc JSON edits in
   command handlers.
8. Nested raw terminal ownership needs a PTY test. `RawLineInput.read` restores the
   prompt mode before returning, so a synchronous picker between prompts is viable.

## Proposed direction for planning

The code shape to test in the next artifact is:

- a pure `cli/Slash.zig` parser and ordered registry;
- one erased command-dispatch callback in `Interactive.Inputs`, called after UTF-8
  sanitation and before `Session.addUser`;
- one per-turn runtime snapshot callback so `Interactive` does not retain stale
  provider or model values;
- a process-owned interactive command coordinator that owns candidate selection and
  commits changes across runtime, prompt, tools, compaction, session, durability, and
  persistent selection;
- a provider-neutral owned model-list contract in `ai`;
- a pure hax-compatible model-order module;
- terminal adapters that convert domain entries into borrowed `Picker.Item` values.

## Open decisions

1. Should the first implementation stop after `/help` plus the parser seam, then add
   selectors, or should `/help`, `/model`, `/effort`, and `/provider` land as one
   larger capability? I recommend two commits in one milestone: command dispatch and
   `/help`, followed by transactional selectors.
2. Hax persists successful selection as the new default. Zi has no general state
   writer yet. I recommend adding the narrow selection writer in this milestone so
   we do not ship knowingly different behavior.
3. Provider model enumeration is uneven. I recommend a tagged result that preserves
   `unsupported`, `failed`, and `models`, with adapters added provider by provider.
   A provider without enumeration should keep hax's explanatory fallback rather than
   receive a fabricated catalog list.
4. Runtime replacement can use a stable owner containing an optional current runtime
   plus candidate runtime. The program-design stage must prove pointer stability and
   rollback ordering before implementation.

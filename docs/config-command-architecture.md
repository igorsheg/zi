# Config command system architecture

Status: approved

References:

- `docs/config-command-research.md`
- `docs/config-command-product.md`
- `docs/preset-save-architecture.md`
- `docs/slash-commands-architecture.md`

## Boundary

`/config` is one process-local transaction:

1. Inspect or validate one registered setting.
2. Prepare a complete run-tier candidate.
3. Derive one typed runtime-policy snapshot from that candidate.
4. Publish the run tier and runtime policy without failure.
5. Let consumers sample the new policy at their next defined boundary.

The command never writes a persistent document. It does not use `ConfigWriter`, `StateWriter`, or
`AtomicReplace`.

The hard part is not parsing `/config`. It is replacing startup copies with explicit policy sources so
all 21 editable settings tell the truth.

## Architectural decisions

1. `config.Settings` remains the only registry and type authority.
2. `config.Selection` remains the owner of the process run tier. It gains a generic prepared override
   operation but keeps preset and selection behavior unchanged.
3. A new CLI-owned `RuntimeConfig.Owner` holds one self-contained typed snapshot for all editable
   settings. It coordinates candidate preparation and publication.
4. Turn, selection, compaction, image, and display consumers sample the snapshot at operation boundaries.
   Provider and tool owners receive validated value policies through infallible between-operation setters.
5. Cross-module policy access uses module-owned value types and setters. No inward module imports `cli`,
   and no erased policy interface remains unused.
6. The snapshot contains value types only. Editable string settings become enums, so publication needs
   no allocation or cleanup.
7. The current run document and policy snapshot publish in one non-failing critical section. No command,
   turn, request, or tool operation can observe the intermediate assignments.
8. Config inspection has a separate bounded read path. It never duplicates an unbounded environment
   value merely to clip it later.
9. Existing selection and preset transactions continue to own provider, model, effort, prompts, and
   active preset tint. Runtime policy reads active preset tint through the stable startup owner.
10. Persistent config caches and provider definitions are not rebuilt because no persistent bytes
    change.

## Component map

```text
config.Settings
  ordered registry
  metadata, secrecy, editability
  validation, canonical choices, hints
  bounded source-aware inspection
          |
          v
config.Selection
  owns run and conversation documents
  prepares one generic run-key candidate
  publishes candidate without allocation
          |
          v
cli.StartupConfig.Owner
  stable owner of Selection and config documents
  exposes fresh Store and active preset tint
          |
          v
cli.RuntimeConfig.Owner
  owns current typed RuntimeConfig.Snapshot
  prepares Snapshot from prospective Store
  coordinates run-document + Snapshot publication
          |
          +-------------------+--------------------+------------------+
          v                   v                    v                  v
 ai.RequestPolicy.Policy  tool.RuntimePolicy.Policy  interactive policy  display policy
 retained provider plan   retained tool defaults     turn/max/context     theme/width/mode
 retry + idle limits      launch-time task copies    image/compact/sort   reasoning
          |
          v
cli.ConfigCommand.Source
  bounded inspect
  apply clear or canonical value
          |
          v
cli.ConfigCommand
  syntax, picker rows, diagnostics, preseed outcome
          |
          v
cli.InteractiveCommands -> cli.Interactive -> terminal.RawLineInput
```

`RuntimeConfig.Owner` is orchestration, so it belongs in `cli`. It imports inward policy value types from
`ai`, `agent`, `config`, `render`, `terminal`, and `tool`. Provider and tool modules expose their own
validated value publication methods; they do not import `cli`.

## Registry authority

`src/config/Settings.zig` extends each static row with the metadata already present in pinned Hax:

```text
choices
example
editable
secret
```

Zi keeps its existing dedicated `bool` kind. The public behavior still uses `on|off` choices. A
tri-state string row declares `auto|on|off` explicitly.

The registry owns:

- exact key lookup;
- 63-byte key policy for `/config`;
- editable versus read-only classification;
- secret classification;
- accepted choices and canonical spellings;
- integer, size, and duration bounds;
- exact value hints;
- raw validity checks used by inspection;
- conversion of a validated value into the typed runtime snapshot.

The CLI does not keep a second list of mutable keys or type grammars. A compile-time or test-time golden
check confirms that exactly the approved 21 rows are editable and exactly the API-key rows are secret.

Selection-command guidance remains CLI knowledge because `/provider`, `/model`, `/effort`, and `/preset`
are not configuration-layer concepts.

## Bounded inspection

Current `Store.read` returns an owned complete string. That is correct for ordinary configuration
consumers but wrong for a command that promises clipped output from potentially large environment
values.

The config layer adds a bounded inspection operation with this logical result:

```text
source
presence: unset | empty | value
redacted
invalid
owned display bytes
clipped
```

The operation resolves the same six tiers and provider-binding rules as `Store.read`. It differs only
in materialization:

- secrets become `set` or `unset` before copying;
- JSON strings are validated from their borrowed node and copied only to the display budget;
- environment strings are validated while borrowed and copied only to the display budget;
- integer, real, and boolean JSON scalars format through a fixed local buffer;
- object and array values remain absent under the existing scalar-setting contract;
- clipping preserves UTF-8 and complete visible escape spellings;
- source and invalid status describe the full value, not the clipped prefix.

Resolution logic must not be forked. `Store` should expose one internal candidate walk used by both the
complete owned read and bounded inspection. This keeps precedence, empty handling, default sentinel,
and provider binding identical.

`ConfigCommand` receives redacted display data. Raw secret bytes never cross into CLI picker storage or
formatting.

## Run-tier ownership

`config.Selection` already owns the run document used by CLI selection and preset overlays. `/config`
adds a generic prepared override there rather than creating a competing run tier.

The operation changes exactly one registry key:

- canonical value means set one flat run member;
- `default` means delete that run member;
- every unrelated run member remains unchanged;
- provider, model, effort, preset, prompt, and preset tint rules are not invoked;
- an active preset is not exited.

The candidate is a complete owned `Document` under `Document.runtime_limits`. Preparation clones the
current effective run document, applies one member, and validates the resulting root before returning.
No mutation occurs during preparation.

The prepared object can derive a prospective `Store`. `RuntimeConfig` uses that store to resolve the
entire typed snapshot before either object publishes.

### Stable store rule

Long-lived mutable consumers must not retain a copied `Store` that predates creation of the first owned
run document. They instead use the typed `RuntimeConfig` sources or request a fresh store from
`StartupConfig.Owner` at the start of a selection transaction.

Read-only provider-definition and persistent-config consumers may keep their existing stable config and
state document borrows. They do not consume `/config`-editable keys after startup.

This avoids broadening `Selection` into a global callback registry and resolves the optional run-document
address problem identified in research.

## Typed runtime snapshot

`RuntimeConfig.Snapshot` is the single coherent policy value for the 21 editable rows. It contains no
allocator-owned slices.

Logical fields are:

```text
display
  markdown
  show_reasoning
  display_width policy
  configured theme choice
  configured tint choice
  tint source is explicit run override

selection and turn
  sort_models: auto | on | off
  manual_context_limit
  image_input: auto | on | off
  max_turns

compaction
  enabled
  threshold

tools
  output cap
  bash default timeout
  bash maximum timeout
  bash termination grace
  bash background yield
  task wait timeout
  task maximum running

request
  maximum retries
  retry base delay
  streaming idle timeout
```

Preparing a snapshot resolves every field from the prospective store, not only the changed key. This
has three benefits:

1. `default` correctly exposes and validates the next lower tier.
2. A lower invalid value gets the same typed fallback as startup.
3. Publication cannot combine one new field with stale interpretations of another field.

Numeric conversion into `usize`, `u16`, `u8`, and agent loop limits happens during preparation. A
platform-width or module-limit failure rejects the candidate before publication.

### Theme and preset tint

The snapshot retains configured theme and tint choices plus whether tint came from the run tier. It does
not copy active preset tint.

When a display consumer asks for the effective theme, `RuntimeConfig.Owner` combines:

```text
explicit run tint
  else active preset tint from StartupConfig.Owner
  else resolved configured tint
```

with the resolved theme choice and fixed terminal capability facts captured at startup. This preserves
preset transitions without requiring `/preset` to republish the runtime snapshot.

All returned theme strings are static or borrowed from stable owners for the synchronous call.

## Runtime policy publication

`ai.RequestPolicy.Policy` and `tool.RuntimePolicy.Policy` are small value types. `RuntimeConfig` resolves
and validates the complete values from the prospective store before publication. The main interactive
thread then copies them into the retained provider and tool owners between operations. These setters are
infallible for a validated policy and assert that no synchronous tool callback is active.

Provider-plan publication holds the existing plan lock, updates retry and idle limits, and retains
Anthropic reasoning visibility so a later catalog rebuild reapplies it. Provider selection rebuilds use
the current RuntimeConfig policy directly. Fixed-purpose catalog, auth, discovery, and account-usage
requests keep their dedicated timeout contracts.

Tool publication updates defaults for later read, Bash, task-admission, and wait operations. Each
background task copies model-output and termination-grace limits into its entry at launch. Later changes
therefore affect new operations without resizing or reinterpreting running tasks. No background callback
reads `RuntimeConfig.Owner`, and no tool imports `cli` or `config`.

### Turn and selection policy

The current `Interactive.TurnSource` already supplies one coherent selection snapshot per user turn. It
expands to include runtime max turns or pairs with a small turn-policy source sampled at the same point.
The eventual program design should choose one representation, but there must be one sample before
`agent.Loop.run`.

The live selection owner combines its provider/model metadata with the current runtime snapshot:

- `max_turns` maps zero to Zi's existing unlimited interactive ceiling;
- manual context limit combines with current model metadata;
- image policy combines with current model support;
- sort policy combines `auto` with the provider's ordering preference.

The model picker samples sort policy when it builds rows. Dynamic image resolution samples image policy
before it resolves current catalog metadata. Stats and compaction sample the same manual context policy.

### Compaction policy

`AutoCompact` stops owning fixed `enabled` and `threshold` values. It samples them at the start of each
automatic compaction check. Provider, model, prompt, effort, and metadata remain selection-derived
values updated by existing `LiveViews` publication.

Manual `/compact` is unaffected by `compact.auto`, as it is today.

## Interactive display policy

Display policy is read at safe boundaries between streams. No style is changed while a renderer owns an
active turn.

### Rendering mode

Both Markdown and plain interactive renderers remain process-owned. A small dynamic renderer selector
samples `markdown` before each turn and returns one erased renderer for that complete turn. The selected
renderer handles begin, event delivery, close, error check, and tool observer for that turn.

Changing `markdown` therefore changes the next assistant turn without reallocating renderers or
switching one mid-stream.

Replay paths use the same current mode at replay start.

### Reasoning visibility

Markdown, plain, replay, and provider request paths sample one `show_reasoning` value for their operation.
Renderer setters run before a turn or replay starts. The AI request source uses the same published
snapshot.

### Width

Existing width-source interfaces remain the main mechanism. Their implementations stop retaining one
startup `DisplayColumns.Policy` and instead resolve the current runtime display-width policy.

The dynamic width reaches:

- raw prompt editing;
- config and selection pickers;
- command help and diagnostics;
- Markdown and plain wrapping;
- replay and history rendering;
- stats and banners;
- frame and spinner layout.

A component that currently stores `DisplayColumns.Policy` by value gains an optional erased source with
the existing value as fallback. This preserves library tests and noninteractive callers.

### Theme and tint

Components sample effective theme before an operation that emits styled output:

- command row or diagnostic;
- prompt repaint;
- picker invocation;
- renderer turn or replay;
- spinner show;
- banner render.

Main-thread wrappers update local renderer fields only while inactive. Spinner receives a copied theme
through its synchronized show/update path; its background painter never reads `RuntimeConfig.Owner`.

The `/config` success line is rendered after publication and therefore uses the new theme. Cooked mode
continues to force unstyled output even though the source has a theme.

## RuntimeConfig owner

`cli.RuntimeConfig.Owner` is heap-stable or address-stable for the lifetime of every policy source. It
owns:

- a pointer to `StartupConfig.Owner`;
- the current typed `Snapshot`;
- fixed terminal theme-resolution facts;
- no persistent file path;
- no config or state document;
- no provider, tool, renderer, or terminal owner.

It provides three classes of operation:

1. Bounded inspection through a fresh `StartupConfig.store()`.
2. Candidate preparation from a setting update.
3. Read-only policy source methods.

It does not format command output or invoke pickers.

### Initialization order

After `StartupConfig.finish` and before provider construction:

```text
StartupConfig.Owner exists
  RuntimeConfig resolves initial Snapshot from StartupConfig.store
  ProviderConfig receives initial ai request-policy value
  provider runtime is constructed
  ToolRuntime receives initial tool-policy value
  RunSelection and Interactive receive turn-policy source
  raw display components receive display-policy sources
  InteractiveCommands receives ConfigCommand.Source
```

`RuntimeConfig.Owner` outlives every borrower. Provider, tool, render, terminal, and command owners are
deinitialized before it.

Print and one-shot modes may use the same initial snapshot as fixed policy. They do not expose the slash
command but keeping one resolution path prevents interactive and one-shot startup drift.

## Publication transaction

A direct change follows this sequence:

```text
ConfigCommand
  find registry row
  validate and canonicalize borrowed input
  RuntimeConfig.prepare(row, update)
    StartupConfig.prepareSetting(update)
      Selection clones and changes run document
    prospective Store from prepared document
    resolve complete RuntimeConfig.Snapshot
    validate all module bounds and conversions
    allocate bounded confirmation inspection from prospective Store
  RuntimeConfig.publish(prepared)
    install new Snapshot
    publish prepared Selection run document
    return retired run document
  destroy retired document after publication
  copy validated policies into retained live owners
  render the prepared confirmation
```

The core RuntimeConfig publish section performs only assignments and moves. Candidate confirmation is
allocated before it. The following provider/tool/display fan-out copies already validated values between
operations and has no recoverable error.

The order of the two assignments is not externally observable because:

- slash commands run synchronously between turns;
- no provider request or tool launch overlaps command execution;
- background tasks use copied launch policy;
- spinner background work does not read the runtime owner;
- command confirmation occurs after both assignments.

Old document cleanup happens after the new document and snapshot are visible.

## Command architecture

A new `src/cli/ConfigCommand.zig` owns the product flow but no live process state. It depends on:

- `config.Settings` for registry metadata and value grammar;
- a small erased `ConfigCommand.Source` for inspect and apply;
- `SelectionPicker.Runner` for both picker stages;
- the existing borrowed preseed command outcome;
- a writer and style source supplied by `InteractiveCommands`.

`InteractiveCommands` adds the registry row and a forwarding handler. It continues to own help order,
command framing, styled writing, and the dedicated-command mapping.

The source returns typed mutually exclusive outcomes. It does not return raw config documents or expose
`RuntimeConfig.Owner` fields.

### Direct path

The direct path parses without allocation. It inspects or validates before building any user-facing
message. Invalid input is escaped directly into bounded output.

A mutation failure before publication maps to the product's unchanged diagnostic. `OutOfMemory` remains
an error return so the interactive owner can unwind normally; it is never converted into a successful
handled command.

### Picker path

The broad picker uses one invocation-scoped arena or owned row set capped at 256 KiB. Rows borrow static
registry labels and descriptions when possible. Derived detail bytes are redacted and bounded before
retention.

The broad picker never includes provider rows. It retains a parallel registry-index map so a selected
row does not trust display text as identity.

The choice picker uses static choice slices plus at most one bounded exact-value seed. Tint preview uses
the current effective base theme. Cancellation from either picker returns `.handled` without output.

Picker data dies before mutation begins. After a user selects a setting, direct mutation repeats
inspection and validation through the source rather than trusting a stale row detail.

## Preseed ownership

`ConfigCommand` returns borrowed preseed bytes only through synchronous command outcome delivery.
`Interactive` immediately calls `PromptInput.queuePreseed`, and `RawLineInput` copies them into its
bounded one-shot owner.

For a dynamic preseed, the command owns temporary formatting storage until the synchronous execute call
returns. No picker row or inspection allocation is borrowed after its owner is destroyed.

Cooked input's optional adapter discards the seed synchronously, preserving the completed
`/preset-save` behavior.

## Failure domains

| Failure | Owner | Published state |
| --- | --- | --- |
| unknown or long key | ConfigCommand | unchanged |
| read-only key | ConfigCommand | unchanged |
| invalid value or bound | config.Settings | unchanged |
| bounded inspection overflow | ConfigCommand/source | unchanged |
| run candidate allocation or validation | config.Selection | unchanged |
| snapshot resolution or conversion | RuntimeConfig | unchanged |
| picker allocation or cancellation | ConfigCommand/picker | unchanged |
| preseed allocation | RawLineInput | old seed retained |
| command output before publication | CLI writer | unchanged |
| final confirmation write after publication | CLI writer | coherent new state remains published |

Policy sampling during later operations cannot fail for values already in the snapshot. Operation-owned
allocation and I/O failures remain failures of that later operation, not delayed `/config` validation.

## Cooked and terminal modes

The same command registry and RuntimeConfig source serve both modes.

Cooked mode has no picker runner and uses an unstyled writer:

- bare `/config` returns handled silently;
- direct inspection and mutation work;
- policy still changes the current process;
- generated preseed is discarded;
- no ANSI bytes are emitted.

TTY mode reuses `terminal.Picker` in the normal buffer. Picker and input terminal ownership do not
overlap: `RawLineInput.read` restores cooked terminal state before slash execution, then a synchronous
picker owns raw mode and restores it before returning.

No component enters the alternate screen.

## Bounds and sensitive data

Architectural limits are:

```text
registry rows                  61 static rows
editable rows                  21 static rows
direct key                     63 bytes
displayed value subject        4096 escaped bytes
picker retained data           256 KiB
config and state input         1 MiB each
runtime document               Document.runtime_limits
preseed                        existing prompt limit
picker viewport                existing 12 rows
```

Budget checks use overflow-safe addition. Picker preparation stops before publishing a partial row set.

Inspection redacts secrets in `config` before allocation. CLI buffers that hold non-secret configuration
values are wiped before free because system prompts and endpoints may still be private. Control-byte
escaping happens before terminal output and clipping never emits a partial escape sequence.

## ConfigWriter remains preset-scoped

`ConfigWriter` is intentionally unchanged.

Broadening it would incorrectly imply that `/config` persists settings, trigger unrelated fingerprint
and cache rules, and create a second transaction whose failure modes Hax does not expose for this
command.

`RuntimeConfig` reads the stable config document through `StartupConfig.store` but cannot mutate or
publish it. Provider definition and preset enumeration generations therefore remain unchanged after
every `/config` operation.

## Dependency direction

Allowed dependencies:

```text
config.Settings -> config.Store, config.Document
config.Selection -> config.Store, config.Document, config.Preset
ProviderConfig/ProviderRuntime -> ai.RequestPolicy value publication
ToolRuntime -> tool.RuntimePolicy value publication
cli.RuntimeConfig -> config + ai/tool/agent/render/terminal policy types
cli.ConfigCommand -> config.Settings + CLI picker/source seams
cli.InteractiveCommands -> cli.ConfigCommand
cli.PrintRun -> all CLI composition owners
```

Forbidden dependencies:

- `config` importing CLI, render, terminal, tool, or provider implementations;
- `ai` importing config or CLI;
- `tool` importing config or CLI;
- render or terminal importing config or CLI;
- `ConfigCommand` owning `StartupConfig`, provider, tool, renderer, or filesystem state;
- `RuntimeConfig` writing config or state files;
- individual consumers retaining a copied config `Store` for mutable policy;
- background workers borrowing `RuntimeConfig.Owner`.

Outside callers continue to import module roots rather than leaf files. New inward policy files are
exported and registered through `ai/root.zig` and `tool/root.zig`. New CLI files are registered by the
CLI test root.

## Verification boundaries

Architecture-level verification must cover:

1. `config`: registry metadata, validation and canonicalization, source parity, bounded inspection,
   redaction, generic run candidate, allocation failure, and non-exiting preset behavior.
2. `ai`: retained request policy, Anthropic reasoning display across catalog rebuilds, retry and idle
   changes, and no policy reads from transport worker threads.
3. `tool`: validated between-operation publication, launch-time capture for background tasks, later wait
   defaults, output bounds, and running-task stability.
4. `render` and `terminal`: dynamic mode, theme, reasoning, and width only between operations; normal
   buffer restoration; no source read from spinner background work.
5. `cli.RuntimeConfig`: initial snapshot parity, prospective-store resolution, allocation-free coherent
   publication, lower-tier fallback, active preset tint precedence, and every failure leaving old state.
6. `cli.ConfigCommand`: direct syntax, exact diagnostics, broad and choice picker order, secret absence,
   retained budget, silent cancellation, and preseed lifetime.
7. `cli.Interactive`: borrowed outcome delivery, command admission, cooked discard, and next-turn max
   turn policy.
8. Built binary: all 21 settings through the highest reachable behavior, plain cooked output, PTY
   picker and display refresh, no persistent file changes, and no alternate-screen sequences.

The program design must turn these boundaries into vertical slices. No slice may mark a row editable
before its policy publication path and built-binary effect are in place.

## Architecture decisions requiring approval

1. Keep the run document in `config.Selection`; do not create a second runtime config store.
2. Add `cli.RuntimeConfig.Owner` as the one typed policy snapshot and publication coordinator.
3. Sample CLI-local policies at operation boundaries; publish provider/tool value policies through
   infallible module-owned setters between operations.
4. Keep `ai.RequestPolicy` and `tool.RuntimePolicy` as value and validation seams, without unused erased
   interfaces.
5. Treat provider-generation HTTP as the `http.*` runtime boundary; fixed-purpose catalog, auth,
   discovery, and usage operations retain their dedicated timeout policies.
6. Keep both renderers alive and select one per turn instead of rebuilding them on each Markdown change.
7. Resolve effective theme dynamically from runtime choice, explicit run tint, and active preset tint.
8. Add a bounded config inspection path that shares Store resolution rather than copying then clipping.
9. Leave `ConfigWriter`, `StateWriter`, provider caches, and preset caches untouched.

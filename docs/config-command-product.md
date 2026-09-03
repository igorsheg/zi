# Config command product contract

Status: approved

Reference:

- `docs/config-command-research.md`

## Problem

Zi resolves typed configuration from CLI overrides, resumed conversations, environment variables,
state, `config.json`, and registry defaults. Once the process starts, users cannot inspect that
resolution or change ordinary runtime policy without restarting.

Dedicated commands already own provider, model, effort, and preset selection. `/config` fills the
remaining gap. It explains where a setting came from and changes settings that Zi can apply safely to
the running process.

## User outcome

A user can inspect one setting:

```text
/config compact.threshold
```

and see its value and source:

```text
compact.threshold = 85 (default)
```

They can change it for the current process:

```text
/config compact.threshold 75
```

and receive confirmation:

```text
compact.threshold = 75 (run)
```

They can clear that process override:

```text
/config compact.threshold default
```

The lower-precedence value becomes effective again. No persistent file changes.

In a terminal, bare `/config` opens a searchable setting picker. Choice settings can be changed from a
second picker. Exact numeric input is prefilled into the next prompt when needed.

## Command registration

The help registry places `/config` after `/preset-save` and before `/compact`:

```text
/config  view or change settings (optional: key value)
```

The command has no alias and accepts an optional argument.

## Syntax

The accepted forms are:

```text
/config
/config KEY
/config KEY VALUE
```

`KEY` is the first whitespace-delimited token after `/config`. Zi skips whitespace before `VALUE` and
then treats the complete remaining tail as the value.

Trailing value whitespace remains literal:

```text
/config markdown off
```

is valid, while:

```text
/config markdown off␠␠␠
```

where `␠` denotes a space, passes three trailing spaces after `off` and is invalid.

Extra words are also part of the value rather than separate arguments. `/config markdown off extra`
therefore fails typed validation.

A key may contain at most 63 bytes. Zi does not trim, case-fold, or rewrite keys.

## Registry boundary

The command exposes the 61 settings in Zi's current ordered registry. It does not add settings whose
underlying product capability does not exist.

These pinned Hax settings remain absent:

```text
keep_awake
notify
providers.openrouter.referer
providers.openrouter.title
trace
```

Bare `/config` hides all `providers.*` rows. A specific registered provider row remains queryable by
key. This includes secret API key rows, which are always redacted.

Registry order controls picker order. The picker does not sort settings and does not add category
header rows.

## Runtime-editable settings

The following 21 settings are editable through `/config`:

| Setting | Accepted values |
| --- | --- |
| `markdown` | boolean aliases |
| `show_reasoning` | boolean aliases |
| `sort_models` | `auto` or boolean aliases |
| `context_limit` | positive size |
| `display_width` | `auto`, `terminal`, or an integer from 20 through 4096 |
| `theme` | `auto`, `dark`, `light`, `ansi`, or `off` |
| `tint` | `teal`, `violet`, `rose`, or `sage` |
| `compact.auto` | boolean aliases |
| `compact.threshold` | integer from 1 through 100 |
| `max_turns` | nonnegative integer |
| `image_input` | `auto` or boolean aliases |
| `tool_output_cap` | positive size |
| `bash.timeout` | nonnegative duration |
| `bash.timeout_max` | nonnegative duration |
| `bash.timeout_grace` | duration from 0 through 300000 milliseconds |
| `bash.background_yield` | nonnegative duration |
| `task.wait_timeout` | nonnegative duration |
| `task.max_running` | integer from 1 through 64 |
| `http.max_retries` | integer from 0 through 100 |
| `http.retry_base` | duration of at least 1 millisecond |
| `http.idle_timeout` | nonnegative duration |

Every other registered setting is read-only through `/config`.

Zi must not mark an entry editable until changing it updates every live owner promised below. The
command is incomplete if it accepts a value that only changes inspection output.

## Value grammar

Boolean aliases are case-insensitive:

```text
on off
true false
yes no
1 0
```

Display normalizes valid booleans to `on` or `off`.

Strict enum choices are case-insensitive on input and use canonical lowercase spelling in the run
override and confirmation. For example, `LIGHT` becomes `light`.

Integers are complete base-10 values. Negative integers are invalid for every editable setting.

Sizes are a positive integer with an optional binary suffix:

```text
64
64k
1M
```

`k` and `m` are case-insensitive and multiply by 1024 and 1024 squared.

Durations are a nonnegative integer with one of these forms:

```text
2
500ms
2s
10m
1h
```

A missing suffix means seconds. Units are case-insensitive.

Only exact lowercase `default` has clearing semantics. `Default`, `DEFAULT`, or a value with trailing
whitespace goes through ordinary validation.

## Direct inspection

`/config KEY` prints:

```text
KEY = VALUE (SOURCE)
```

`SOURCE` is one of:

```text
run
conversation
env
state
config
default
```

Values display as follows:

- secret values display as `set` or `unset`;
- booleans display as `on` or `off`;
- valid tri-state values display as `auto`, `on`, or `off`;
- no value displays as `unset`;
- a meaningful explicit empty string displays as `(empty)`;
- other values retain their resolved spelling after safe terminal escaping and clipping.

If a non-secret configured value is present but invalid for its registry row, Zi shows the raw value
and marks it:

```text
compact.threshold = banana (config, invalid)
```

Typed consumers continue to use their safe fallback. The inspection line does not replace the raw
value with that fallback.

### Read-only guidance

A key-only query is allowed for every registered row.

Selection settings add a dedicated-command hint:

```text
provider = openai (config)
  change it with /provider
```

The mappings are:

| Key | Command |
| --- | --- |
| `provider` | `/provider` |
| `model` | `/model` |
| `effort` | `/effort` |
| `preset` | `/preset` |

Other read-only rows add:

```text
  read-only at runtime — set ZI_ENV_VAR or config.json and restart to change
```

## Direct mutation

`/config KEY VALUE` checks the request in this order:

1. The key fits the 63-byte limit.
2. The key exists in Zi's registry.
3. The row is runtime-editable.
4. `default` clears the run override, or the complete value passes the row grammar and bounds.
5. Every affected live policy can be prepared without changing published state.
6. The run override and all live policies publish as one logical change.
7. Zi prints the resulting inspection line.

A successful value outranks conversation, environment, state, config, and default values for the rest
of the process. It does not change any persistent tier.

A successful `default` removes only the run override for that key. Resolution then exposes the next
eligible lower tier.

Changing an ordinary setting does not exit an active preset. An explicit runtime value simply outranks
the preset's lower-tier or derived value where that setting participates. Existing dedicated selection
commands keep their current preset-exit behavior.

## Activation timing

All 21 editable settings must affect the running process.

Display changes apply before command confirmation returns:

- `markdown` switches subsequent assistant rendering between Markdown and plain rendering.
- `show_reasoning` changes reasoning visibility for subsequent streamed and replayed output.
- `theme` recolors the prompt, command output, pickers, spinner, Markdown, plain output, replay, and
  future banners without entering an alternate screen.
- `tint` updates identity coloring. An explicit run tint outranks an active preset tint.
- `display_width` changes the next prompt, picker, frame, renderer, replay, stats, and help layout.

Other settings apply at the next relevant use:

| Settings | First affected operation |
| --- | --- |
| `sort_models` | next `/model` picker |
| `context_limit` | next context calculation, stats render, compaction check, or request |
| `image_input` | next request or image-tool capability decision |
| `compact.auto`, `compact.threshold` | next automatic compaction check |
| `max_turns` | next model round-trip limit check |
| tool and bash settings | next new tool call |
| `task.wait_timeout` | next task wait that omits a timeout |
| `task.max_running` | next background-task admission |
| HTTP retry settings | next HTTP request |

Existing running subprocesses and tasks retain the limits under which they started. A settings change
does not cancel, resize, or reinterpret them.

## Bare command picker

In an interactive terminal, `/config` opens a normal-buffer picker titled:

```text
configuration
```

The picker shows non-provider registry rows in registry order. Each row has:

- key label;
- resolved value and source detail;
- `invalid` marker when applicable;
- registry description;
- grammar or bounds when they add useful information;
- dim styling for read-only rows.

The initially selected row is the first shown registry row. Search and navigation follow the existing
terminal picker.

Escape, Ctrl-C, Ctrl-G, EOF, terminal read failure mapped to cancellation, or choosing no row closes the
picker without output or state change.

Selecting a read-only row prints its inspection and guidance.

Selecting an editable row behaves according to its type:

- choice-only rows open a choice picker;
- rows without choices prefill exact input in the next prompt;
- numeric rows with symbolic choices open a choice picker containing those choices and
  `exact value...`.

## Choice picker

The choice picker title is:

```text
KEY — DESCRIPTION
```

Its first row is:

```text
default
Clear the runtime override and use the environment, saved configuration, or built-in default
```

Choice rows follow registry order. The current exact choice is selected initially. Tint rows use their
preview colors.

Choosing `default` clears the run override. Choosing another choice applies it immediately. Cancellation
is silent and changes nothing.

A numeric choice picker adds:

```text
exact value...
```

with an example description when the registry has one. `display_width` uses:

```text
Enter an exact value such as 100
```

If the current value is a valid exact number, it becomes the prefilled value. If the current value is a
symbolic choice or invalid, the registry example is used.

## Exact-input preseed

A free-form or `exact value...` selection returns to the prompt and preloads:

```text
/config KEY VALUE
```

When no seed value exists, it preloads `/config KEY ` with a trailing space. The cursor starts at the
end.

The seed is copied synchronously into the input owner, bounded by the existing prompt limit, replaces
an earlier seed only after successful allocation, and is consumed once. If the next read is cooked,
Zi discards the seed.

## TTY and cooked behavior

When stdin and stdout are interactive terminals:

- bare `/config` uses the normal-buffer picker;
- choice and exact-input handoffs work;
- display changes refresh the existing normal-buffer interface;
- no alternate-screen sequence is emitted.

When either side is not a terminal:

- bare `/config` is a silent handled command;
- `/config KEY` inspects normally;
- `/config KEY VALUE` mutates normally;
- output is plain and contains no ANSI sequences;
- no picker runs;
- no stale preseed reaches a later TTY read.

## Diagnostics

Unknown keys report:

```text
unknown setting 'KEY' — /config lists them
```

A key token longer than 63 bytes reports:

```text
unknown setting 'KEY'
```

A write to a dedicated selection row reports:

```text
'provider' can't be changed from /config — use /provider
```

The key and command vary according to the mapping above.

A write to another read-only row reports:

```text
'KEY' can't be changed at runtime — set ZI_ENV_VAR or config.json and restart
```

Invalid values report:

```text
invalid value 'VALUE' for KEY (expected: HINT, or default)
```

Hints use these forms:

```text
on|off
auto|on|off
auto|terminal, or a whole number from 20 to 4096; e.g. 100
a whole number from 1 to 100
a size like 64k or 1M
a duration like 2s or 500ms
```

If Zi cannot prepare the complete live change after validation, it reports:

```text
couldn't change 'KEY' — keeping the current settings
```

The old run override and every live policy remain unchanged. Allocation failures still return through
the existing error path after cleanup; the process must not panic.

All inserted keys, values, environment variable names, and diagnostics are control-byte escaped.

## Output and retention bounds

Direct command output may render at most 4,096 escaped bytes from any one resolved value or invalid
input value. Longer text is clipped with `...` without splitting UTF-8 or an escape spelling.

The no-argument picker may retain at most 256 KiB of derived labels, details, and descriptions for one
invocation. Registry count is statically bounded. If row preparation would exceed the retained budget,
Zi reports the generic unchanged failure and does not open a partial picker.

Visible picker rows remain subject to the terminal picker's cell and line clipping. Secret values are
redacted before either byte accounting or formatting.

These are intentional safety limits where Hax is unbounded.

## Persistence and file safety

`/config` never writes:

- `config.json`;
- `state.json`;
- session metadata;
- preset definitions;
- provider-definition caches.

It does not invoke `ConfigWriter`, `StateWriter`, or `AtomicReplace`. File permissions, symlinks,
external edits, malformed roots, and rename failures cannot enter the mutation path.

Existing persistent bytes remain untouched. Unknown keys, nested objects, scalar descriptions, and any
other accepted JSON content survive byte-for-byte because no persistent document is serialized.

## Failure atomicity

Before publication, Zi may allocate, parse, validate, resolve defaults, construct render policy, and
prepare replacement tool or transport policy. None of those steps may change the visible run setting or
a live owner.

Publication makes the prepared run override and all affected policy values visible without allocation,
I/O, callbacks, or recoverable validation. Zi retires old owned values afterward.

Validation failure, allocation failure, policy preparation failure, picker cancellation, or preseed
allocation failure leaves the current setting and every consumer unchanged. A final terminal write
failure after publication is an output failure; it does not attempt to roll back an already coherent
live change.

## Privacy and terminal safety

Secret registry rows display only `set` or `unset`, regardless of source. They never enter picker detail,
validation diagnostics, retained command buffers, or history through command-generated output.

Other values use visible escapes for control bytes, including newline, carriage return, tab, Escape,
and NUL. A configured value cannot inject terminal control sequences or create extra diagnostic lines.

TTY rendering stays in the normal terminal buffer. Cooked output stays ANSI-free and line-oriented.

## Success criteria

The capability is complete when:

1. `/help` lists `/config` in the required position and wording.
2. The picker contains every non-provider Zi registry row in exact registry order.
3. Direct lookup reports exact source labels, secret redaction, empty values, and invalid markers.
4. Every read-only row rejects mutation with the correct dedicated-command or restart guidance.
5. Every editable grammar accepts its valid boundary values and rejects malformed, overflowed, and
   out-of-range values.
6. `default` reveals each lower precedence tier correctly.
7. All 21 editable settings update every promised live consumer at the stated time.
8. Any preparation failure leaves the run store and all live consumers unchanged.
9. Picker and preseed cancellation are silent and one-shot.
10. Cooked direct commands work without ANSI, while cooked bare `/config` is silent.
11. TTY pickers and display refresh use only the normal buffer and restore terminal state.
12. Large values, environments, diagnostics, picker rows, and preseeds remain within stated bounds.
13. `config.json`, `state.json`, presets, and provider caches remain byte-for-byte unchanged.
14. Focused tests and built-binary probes use only `./zig-out/bin/zi`.
15. The ready gate is reported honestly on both the active host and the documented Linux filesystem
    baseline.

## Non-goals

This capability does not:

- edit arbitrary JSON;
- persist runtime setting changes;
- add `/config-save` or another persistence command;
- add unsupported Hax settings or their product capabilities;
- replace `/provider`, `/model`, `/effort`, or `/preset`;
- make system prompt, context construction, recording, catalog, transcript, shell selection, or provider
  definition rows live-editable;
- rewrite malformed configuration;
- reload externally edited files;
- change existing task or subprocess limits after launch;
- add an alternate-screen UI;
- add plugins, MCP, Node.js, bun, npm, or TypeScript.

## Product decisions

1. `/config` is a typed process-override command and inspector, not persistent JSON editing.
2. Zi exposes its current 61-row registry. Unsupported Hax capabilities remain absent.
3. Exactly 21 current rows are runtime-editable. Completion requires truthful activation for all 21.
4. Provider rows are hidden from the broad picker but remain directly queryable.
5. Selection rows remain owned by their dedicated commands.
6. Invalid persistent values show their raw spelling, source, and `invalid` marker.
7. Only exact lowercase `default` clears an override. Trailing value whitespace remains literal.
8. Ordinary config changes do not exit an active preset.
9. Bare cooked `/config` is silent for Hax parity.
10. Picker cancellation is silent. Preparation failure is explicit and atomic.
11. Zi narrows Hax with escaped output, a 4,096-byte per-value display bound, a 256 KiB picker retention
    bound, and the existing `display_width` maximum of 4096.
12. `/config` does not use or broaden `ConfigWriter`.

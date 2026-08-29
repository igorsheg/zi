# Slash-command product contract

Status: awaiting review

## Problem

Zi's interactive session can send prompts and resume conversations, but it cannot
change provider settings after startup. It even tells llama.cpp users to use
`/model`, which does not exist. Users must quit, reconstruct the command line, and
start or resume again.

## First milestone

Add these commands to the interactive REPL:

- `/help`
- `/provider`
- `/model`
- `/effort`

A command runs between turns. It never reaches the model and never appears as a
conversation item. It remains available in prompt recall, matching hax.

This milestone does not add `/new`, `/resume`, `/undo`, `/fork`, `/compact`, preset
or config commands, task and usage commands, clipboard commands, or managed login.
Those will extend the same registry after the selection commands prove the design.

## Command recognition

Zi matches hax:

- `/` must be the first byte of the submitted line.
- Names use ASCII letters, digits, `_`, and `-`, with exact case-sensitive lookup.
- Whitespace ends the name and separates an optional argument.
- A malformed command-shaped line such as `/`, `/help.txt`, or an absolute path is
  sent as an ordinary prompt.
- A valid but unknown command is consumed and prints
  `unknown command: /NAME. type /help for the list.`
- Arguments to these four no-argument commands are consumed and print
  `/NAME takes no arguments.`
- Empty submissions retain their existing pause and interruption behavior.

## `/help`

`/help` prints the commands that Zi actually supports, in registry order, followed
by the currently supported interactive shortcuts. It wraps to the configured
terminal width and stays in the normal terminal buffer.

During this incremental port, Zi will not advertise hax commands until their
handlers land. The final command set and ordering will match hax.

## `/model`

`/model` works against the current provider.

- With no provider, it asks the user to choose one with `/provider`.
- While fetching, it shows `fetching models...`.
- Unsupported enumeration, fetch failure, no models, one model, and multiple models
  produce distinct hax-compatible outcomes.
- One model skips the model picker.
- Multiple models open `select a model`.
- Rows identify the wire model ID and show available context, image, price,
  capability, and provider-description facts.
- Advisory limitations dim a row but do not prevent selection.
- Provider order is preserved when configured. Otherwise Zi uses hax's model order.
- If the chosen model has effort levels, Zi asks for effort before committing.
- Cancelling either picker keeps the entire previous selection.

## `/effort`

`/effort` shows levels supported by the current model and provider.

- The first item is `default`, meaning the provider chooses.
- A literal provider level called `none` stays distinct from `default`.
- Models or providers without selectable effort report the same explanatory outcome
  as hax and leave the current selection untouched.
- Cancellation changes nothing.

## `/provider`

`/provider` lists registered providers by display label.

- Zi checks availability before showing the picker.
- Unavailable providers remain visible and selectable, with a dim reason.
- Selecting one triggers a final availability check.
- A new provider remains a candidate while model and effort selection run.
- Cancellation or any setup failure leaves the current provider and conversation
  untouched.
- Re-selecting the current provider continues to model selection without rebuilding
  it.
- A provider that cannot enumerate models may still use a safe configured or provider
  default.

## Successful selection

After the final choice, Zi:

1. switches the live provider, model, and effort together;
2. exits any active preset, matching hax explicit-selection behavior;
3. rebuilds model-dependent prompt and tool policy before the next request;
4. keeps the existing conversation items;
5. records the new selection for subsequent session items and resume;
6. writes the new default selection to persistent state;
7. prints a concise switch notice outside model context.

If persistent state writing fails, the live selection remains active. Zi warns once
that the choice applies only to this run. A failed live reconfiguration does not
partially change the selection.

## Terminal behavior

All selectors use Zi's normal-buffer picker. Search, cancellation, resize handling,
configured theme, display width, and terminal restoration follow the session picker.
No selector enters the alternate screen.

## Acceptance checks

- Ordinary prompts beginning with malformed slash syntax still reach the mock
  provider unchanged.
- Known, unknown, and bad-usage command lines never reach the provider or session
  conversation.
- `/help` output matches the supported registry and terminal width.
- Scripted picker probes cover model acceptance, effort cancellation, provider
  failure, and full provider-model-effort commit.
- The request after a successful switch uses the selected provider, model, metadata,
  effort, prompt, and tool policy.
- A recorded session resumes with the switched selection.
- Allocation and persistence failures preserve the old live selection unless the
  live commit completed, in which case persistence failure produces the run-only
  warning.
- PTY probes confirm normal-buffer rendering and terminal restoration on success,
  cancellation, and error.

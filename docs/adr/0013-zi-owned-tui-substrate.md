# adr 0013: zi owns the tui terminal substrate

status: accepted

date: 2026-06-02

supersedes in implementation:

- adr 0009 where it says libvaxis remains the terminal mechanism.
- adr 0010 where it says Zi uses libvaxis for terminal/render substrate.
- adr 0011 in full. The zio-selectable bridge discipline remains, but the
  bridge is no longer a libvaxis bridge.

## context

The previous TUI spike proved that Zi needs a strict boundary between terminal
mechanism, retained rendering primitives, product state, and coding-agent
session policy. It also showed that keeping libvaxis as the terminal substrate
kept too many sharp edges and behavioral surprises in the lowest layer.

Zi has now reset `src/tui` to substrate, infra, and primitive modules only. The
old product TUI and coding-agent TUI owner/mode were removed. Interactive mode
is temporarily unavailable until the new substrate and product owner loop are
rebuilt on firmer ground.

OpenTUI is a useful reference for retained rendering discipline, cell buffers,
output staging, and benchmark-oriented terminal rendering. It is not a port
target. Zi does not copy OpenTUI's FFI-shaped API, global allocator model, event
bus, audio, logger, editor stack, or product framework.

## decision

Zi owns its terminal substrate.

The current TUI layering is:

```text
src/tui/substrate
  terminal lifecycle, raw mode, terminal size, ANSI helpers, input bytes/events

src/tui/infra
  bounded cell buffers, output staging, renderer frame diffing

src/tui/primitive
  colors, styles, rectangles, text width policy

src/tui/product
  absent until substrate/infra primitives are solid
```

`src/tui` must not import coding-agent product/session policy. Integration with coding-agent will be rebuilt later as one small coding-agent
TUI integration file, after the TUI substrate and product layer have clear
contracts.

## reference use

Zi takes these ideas from OpenTUI:

- retained cell buffers;
- double-buffer/diff rendering;
- bounded output staging before terminal writes;
- explicit color/style value types;
- frame lifecycle discipline;
- text width as an explicit primitive;
- tests and benchmarks for rendering behavior.

Zi rejects these OpenTUI mechanisms for now:

- verbatim vendoring;
- FFI/export API;
- global allocator;
- event bus or emitter-driven mutation;
- audio;
- logger and memory registry;
- generic editor/view/component framework;
- TypeScript-shaped object model.

## runtime relationship

`src/runtime` remains mechanism, not TUI policy.

Terminal input integration should eventually follow Zi's normal runtime shape:

```text
terminal read operation
  -> runtime backend/completion
  -> bounded queue/channel
  -> owner drain
  -> ProductApp.apply
```

There must be no global TUI runtime, hidden task spawning, callback reentrancy,
unbounded event queue, or sleep-polling loop. If runtime lacks a narrow terminal
readiness/completion primitive, it may be extended only at the runtime mechanism
boundary.

Terminal output remains single-owner and synchronous at the render/apply site
until blocking output is measured as a real problem. Renderer output is staged
into a bounded buffer before terminal state is committed.

## invariants

- `src/tui/substrate`, `src/tui/infra`, and `src/tui/primitive` must not import
  `coding_agent`, `agent`, `ai`, session, provider, tool, persistence, auth, or
  model-selection modules.
- Substrate, infra, and primitive modules must not mention transcript,
  composer, assistant, user, tool, system, prompt, model, or session concepts.
- Every queue, buffer, loop, and output staging area has a named bound or an
  explicit owner-provided capacity.
- Terminal lifecycle is explicit: enter, render/write, restore.
- Deinit restores terminal state after partial initialization.
- Rendering consumes a frame/cell buffer and does not mutate product state.
- Renderer commits its current buffer only after output has been staged and
  written according to the renderer's failure contract.
- Product state will be mutated only through a future owner `apply` path.
- Coding-agent events will enter TUI only through public events, snapshots, and
  explicit commands/effects.

## next implementation order

1. Make terminal lifecycle real: raw mode, alternate screen, cursor visibility,
   size query, and cleanup after partial failure.
2. Finish renderer contracts: style/color ANSI emission, cursor movement,
   resize/clear policy, and output failure behavior.
3. Expand semantic-free input parsing with bounded escape sequence handling.
4. Add runtime terminal event integration only after substrate input is real.
5. Rebuild `src/tui/product` around composer buffer/view, transcript
   document/viewport, immutable frame construction, and command-only mutation.
6. Rebuild coding-agent TUI integration as one small file that observes and
   requests through public `sdk.zig` / `AgentSessionRuntimeHost` boundaries.

## rejected alternatives

- Keep libvaxis vendored and wrap around its sharp edges. The reset exists
  because the mechanism was not boring enough at Zi's ownership boundary.
- Vendor OpenTUI core verbatim. This would import a larger architecture than Zi
  needs and replace one hard-to-reason-about substrate with another.
- Rebuild product widgets immediately. Product semantics must not define the
  substrate.
- Add generic buffer/view/surface registries now. Those are product and future
  extension mechanisms; they must be earned by concrete owners.
- Put coding-agent session policy in `src/tui`. TUI renders and requests;
  coding-agent/session owners mutate policy.

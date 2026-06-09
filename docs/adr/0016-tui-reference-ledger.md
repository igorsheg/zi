# adr 0016: tui reference ledger for earned borrowing

status: accepted

date: 2026-06-07

## context

ADR 0013 says Zi owns its TUI terminal substrate. That remains the decision.
The point of this ADR is narrower: keep a reference ledger for terminal and UI
ideas that Zi may borrow later when a concrete need appears.

This is not a vendoring plan. It is a "steal when you get there" list with
source locations, so future work starts from known examples without importing a
foreign runtime, framework, or product model.

Reference revisions:

- libvaxis: `rockorager/libvaxis@a367b89da09bfe5e1b628501940de5b4f858f5f3`
- ZigZag: `meszmate/zigzag@e16e2523972d174d7ca9783631cc90e2609fa55e`

## decision

Zi continues to own `src/tui`:

```text
tui/substrate   terminal lifecycle, raw mode, size query, ANSI, input decoding
tui/infra       bounded cells, output staging, renderer diffing
tui/primitive   color, style, rect, text policy
tui/product     ProductApp command/effect owner
```

When improving these areas, consult the references below. Borrow behavior,
tests, protocol constants, and edge-case handling. Do not copy framework shape,
mutation paths, app loops, widget ownership, or extension authority.

## libvaxis references

Use libvaxis as the terminal-protocol reference.

| Need | Reference | What to steal | What not to steal |
| --- | --- | --- | --- |
| ANSI/query constants | `src/ctlseqs.zig:1-17`, `src/ctlseqs.zig:27-46`, `src/ctlseqs.zig:53-61`, `src/ctlseqs.zig:76-103` | Exact terminal sequences and naming for queries, in-band resize, sync output, bracketed paste, CSI-u, alt screen, SGR colors. | A global terminal feature matrix before Zi has feature consumers. |
| Terminal reset discipline | `src/Vaxis.zig:118-188` | Reset every enabled mode on deinit: cursor, SGR, kitty keyboard, mouse, bracketed paste, alt screen, color updates, in-band resize. | Optional cleanup semantics that allow app exit to skip freeing; Zi deinit frees and restores. |
| Resize handling | `src/Vaxis.zig:190-221`, `src/Loop.zig:38-51`, `src/Loop.zig:103-112`, `src/Parser.zig:529-551` | Resize as an owner-drained event; full buffer rebuild and full redraw after size change; in-band resize `CSI 48 ; h ; w ; hpix ; wpix t`. | Signal callback directly mutating render/product state. |
| Capability query flow | `src/Vaxis.zig:251-324`, `src/Vaxis.zig:326-367` | Batch queries, mark query window, apply environment fallbacks, enable only detected features. | Blocking futex query flow unless Zi has a bounded owner wait and timeout. |
| Synchronized output | `src/ctlseqs.zig:31-33`, `src/Vaxis.zig:841-842` | Mode 2026 set/reset around render output if measured useful. | Always enabling sync output without terminal support and tests. |
| Input parser state | `src/Parser.zig:30-53`, `src/Parser.zig:56-79`, `src/Parser.zig:329-345` | Parser returns `{ event, n }`; incomplete sequences return `n = 0`; unknown complete sequences are consumed. | Propagating parser errors out of Zi's owner loop for operational input. |
| Ground input/graphemes | `src/Parser.zig:81-145`, `src/unicode.zig:14-65`, `src/GraphemeCache.zig:5-19` | Ctrl/key mapping, UTF-8/grapheme boundary detection, bounded grapheme scratch storage. | Treating invalid UTF-8 chunks as fatal in streamed/product input. |
| Bracketed paste | `src/ctlseqs.zig:44-46`, `src/event.zig:14-16`, `src/Parser.zig:447-448`, `src/Parser.zig:894-930` | Paste start/end events and OSC 52 paste test cases. | Unbounded paste payloads; Zi must cap, drop, or backpressure. |
| Kitty keyboard | `src/ctlseqs.zig:53-55`, `src/Vaxis.zig:845-850`, `src/Parser.zig:555-575`, `src/Parser.zig:955-1014` | CSI-u enable/pop, capability response, modifier/event-type parsing, release-event tests. | Exposing terminal-specific key protocol above `tui/substrate`. |
| Capability events | `src/event.zig:21-29`, `src/Parser.zig:184-207`, `src/Parser.zig:490-496`, `src/Parser.zig:561-564` | Model capability reports as typed internal substrate events. | Letting capability events become product commands directly. |
| Window/text wrapping reference | `src/Window.zig:29-52`, `src/Window.zig:268-303`, `src/Window.zig:379-427`, `src/Window.zig:564-577` | Clamped child geometry and grapheme-boundary wrapping tests. | Vaxis windows as Zi extension surfaces. |

## ZigZag references

Use ZigZag as a product/API inspiration reference only. It is a framework, not a
substrate for Zi.

| Need | Reference | What to steal | What not to steal |
| --- | --- | --- | --- |
| Virtual list shape | `src/components/virtual_list.zig:1-28`, `src/components/virtual_list.zig:80-132`, `src/components/virtual_list.zig:140-170`, `examples/virtual_list.zig:1-20`, `examples/virtual_list.zig:50-70` | Cursor/offset/viewport vocabulary; visible-item-only rendering; 100k item example as pressure reference. | Renderer returning allocated strings; external selection placeholder; unbounded item ownership. |
| Command palette ergonomics | `src/components/command_palette.zig:1-7`, `src/components/command_palette.zig:20-34`, `src/components/command_palette.zig:36-63`, `src/components/command_palette.zig:134-140` | Command records with id/label/description/shortcut; key result enum; clone-at-boundary ownership. | Stringly internal dispatch; palette owning Zi command execution authority. |
| Keybinding/help API | `src/components/keybinding.zig:12-23`, `src/components/keybinding.zig:25-45`, `src/components/keybinding.zig:48-89`, `src/components/keybinding.zig:100-113` | Structured key binding + display text + help projection. | Keymaps mutating ProductApp outside `apply(Command)`. |
| Constraint layout examples | `src/layout/flex.zig:24-38`, `src/layout/flex.zig:69-84`, `src/layout/flex.zig:90-110`, `examples/flex_layout.zig:45-90` | Constraint vocabulary and dashboard example when Zi earns richer surfaces. | Full flexbox engine before a second concrete layout owner proves it. |
| Snapshot testing | `src/testing/snapshot.zig:1-16`, `src/testing/snapshot.zig:25-33`, `src/testing/snapshot.zig:35-89`, `src/testing/snapshot.zig:119-140` | Normalized snapshot assertions and ANSI stripping as one test mode. | Golden files as the only render correctness proof; Zi still needs cell/ANSI/PTY tests. |
| Style compression | `src/style/compress.zig:1-8`, `src/style/compress.zig:33-107`, `src/style/compress.zig:110-140` | Style-state diffing if Zi's renderer output is measured too verbose. | Post-processing ANSI strings as the primary renderer architecture. |
| Component catalog | `README.md:11-25`, `src/root.zig:143-145`, `src/root.zig:209-231`, `src/root.zig:361-368` | Product ideas for future extension slots: virtual lists, command palette, tables, viewport, help, style utilities. | A widget framework or Elm runtime inside `src/tui`. |

## borrowing rules

Before borrowing from either project, answer in code:

```text
what can go wrong?
what is the maximum bound?
who owns each resource?
where is mutation allowed?
which errors are programmer vs operational?
which invariant must always hold?
what must future maintainers not remember?
```

Borrowed behavior must enter Zi through one of these owners:

- `tui/substrate` for terminal protocol and semantic-free input;
- `tui/infra` for cell buffers, renderer output, and staging;
- `tui/primitive` for value types and text policy;
- `tui/product` for command/effect-owned product behavior;
- a frontend adapter outside `coding_agent` and `tui` for agent-session integration.

It must not introduce:

- a second TUI event loop;
- callbacks that mutate product state;
- unbounded queues, paste buffers, output strings, or layout caches;
- terminal cells as an extension API;
- framework messages above Zi's command/effect boundary;
- direct imports from `tui` to `runtime`, `agent`, `ai`, or `coding_agent`.

## consequences

Future work can use proven examples without reopening the substrate decision on
each feature. The ledger is allowed to age; when a referenced line moves, use the
recorded commit as the stable source and update this ADR only when Zi actually
borrows the idea.

## rejected

### Vendor libvaxis now

Rejected. libvaxis is the better terminal reference, but Zi already owns a small
substrate. Vendoring libvaxis would import another terminal owner and reopen ADR
0013.

### Vendor ZigZag now

Rejected. ZigZag is a useful framework reference, but its Elm/runtime/string-view
model conflicts with Zi's retained renderer, `ProductApp.apply`, zio select loop,
and future extension boundary.

### Keep references informal

Rejected. Informal references are forgotten or rediscovered. A small ledger with
commit-pinned file/line references is cheaper than repeated archaeology.

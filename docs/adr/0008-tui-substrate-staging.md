# adr 0008: stage the tui substrate around proven owners

status: accepted

date: 2026-06-01

## context

zi needs a tui that can grow into an extensible agent workspace. The likely
future vocabulary is buffer, view, surface, slot, command, event, and stable
handle. Neovim, OpenTUI, and Zag all validate parts of that direction.

The risk is building a general substrate before zi has enough product pressure
to prove each primitive. A generic buffer registry, surface tree, extension hook
system, or editor-grade text buffer would add ownership and performance costs
before the current tui needs them.

## decision

zi will adopt the separation model, not a wholesale reference architecture:

```text
Buffer
  owns domain data and bounds
  has no terminal or layout authority

View
  owns projection state such as viewport, cursor, focus, and follow-tail
  reads buffers and produces bounded visible content

Surface
  owns composition participation for a frame rectangle
  renders a view without becoming durable state

Slot
  is a bounded extension contribution point
  extensions request; tui owners mutate

Command/Event
  is the public mutation and observation boundary

Handle
  is a stable generational id when a resource crosses the extension boundary
```

The first implemented primitive is transcript-shaped, not generic:

```text
Transcript
  bounded resident transcript data
  monotonic content_version

TranscriptView
  scroll/follow-tail projection state
  visible-row selection bounded by viewport rows
```

The renderer asks the view for visible transcript items. It does not walk or
mutate transcript storage directly.

## bounds

- resident transcript item count and bytes remain bounded by `Transcript`.
- transcript view work is bounded by viewport rows.
- scroll commands move by a named fixed row count.
- extension-visible handles are deferred until there is an extension-visible
  resource owner.

## reference use

OpenTUI is a rendering and text-layout discipline reference. zi may borrow
ideas such as content epochs, dirty layout records, width-aware text handling,
and bounded renderer caches. zi will not copy OpenTUI's FFI-shaped API, full
rope/editor stack, or renderer architecture before those costs are justified.

Zag is a closer extension-substrate reference. zi may borrow stable
generational handles, owner registries, command registration semantics, and
hook/event ownership when extensions become real. zi will not add those
registries speculatively.

## rejected alternatives

- build a Neovim-style buffer/window/tab model now. This is editor-first and
  too broad for the current agent workspace.
- vendor OpenTUI's core renderer now. This would move too much machinery into
  zi before the terminal behavior has proven insufficient.
- add generic `BufferRegistry`, `ViewRegistry`, or `SurfaceRegistry` before a
  second concrete owner needs the abstraction.
- expose terminal cells or raw pointers to future extensions. This bypasses tui
  ownership, clipping, z-order, and deterministic testing.

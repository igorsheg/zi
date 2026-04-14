# TUI

zi's TUI is a reusable terminal UI framework, not ad-hoc string rendering.

## Core model

The basic unit is a component.

A component should own one presentation concern and participate in a shared framework for:
- measurement
- rendering
- input handling
- focus
- cursor reporting

Composition belongs in containers and the composition root, not inside random widgets.

## Focus and overlays

Focus is global and explicit.

Overlays temporarily capture focus and then restore it. They are part of the TUI model, not special cases implemented inside individual components.

This keeps pickers, dialogs, and future extension UI predictable.

## Inline vs overlay UI

Not every chooser is an overlay.

Use overlays for transient modal surfaces.
Use inline composition when the UI is part of the editor flow, such as autocomplete.

That distinction matters because it keeps layout, focus, and measurement honest.

## Editor philosophy

The editor should be split into separate concerns:
- **buffer** — text and edit semantics
- **view** — wrapping, viewport, cursor mapping
- **chrome/component shell** — borders, status, composition with autocomplete

Rendering should consume cached view state, not rediscover layout every frame.

## Wrapping philosophy

Shared low-level wrap primitives are good.
A single generic layout authority for every surface is not.

Surfaces should own their own layout policy:
- editors care about cursor-addressable structure
- transcript/text/markdown care about presentation

So the reusable layer should provide wrap mechanics, while each surface owns its layout semantics.

## Transcript philosophy

The transcript is retained UI state.
It should render from stable semantic items and published snapshots, not reconstruct meaning on every paint.

## Picker philosophy

Reusable pickers should separate:
- list navigation/rendering
- picker chrome and search
- fuzzy matching logic

That keeps them composable across overlays, inline flows, and future extension UI.

## Cross-refs

- `runtime.md` — ownership and snapshot rules
- `theme-system.md` — theme semantics for TUI surfaces

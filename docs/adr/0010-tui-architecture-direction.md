# adr 0010: use libvaxis substrate with store/view separation

status: partially superseded by adr 0013

date: 2026-06-01

## supersession note

ADR 0013 replaces this ADR's libvaxis substrate decision. The surviving
principles are retained truth versus views, deterministic frame construction,
command-only product mutation, bounded surfaces/slots when earned, and strict
separation between TUI product code and coding-agent session policy.

## context

Zi's TUI is being rebuilt from the substrate upward. The highest-value product
surfaces are the composer and transcript, but starting directly with product
widgets risks locking Zi into a toy implementation and then retrofitting real
runtime, viewport, and extension primitives later.

Zi should decide the architectural direction before transcript and composer
types lock in. Three external systems are useful references:

- libvaxis provides the terminal mechanism Zi already vendors.
- Neovim proves the long-term value of separating retained truth from views.
- OpenTUI shows useful retained render discipline and frame lifecycle thinking.

None of those projects is a port target. Zi needs a small, Zi-native TUI
architecture shaped around the coding-agent product, zio runtime ownership, and
future extension requests.

## decision

Zi's TUI architecture is:

```text
Use libvaxis for terminal/render substrate.
Borrow Neovim's Buffer/View/Window separation.
Borrow OpenTUI's retained render tree discipline selectively.
Do not clone any of them.
```

The internal direction is:

```text
Terminal
  libvaxis lifecycle, input, resize, cells, styles

Stores
  composer store, transcript document store, surfaces store

Views
  viewport/cursor/selection/focus over stores

Layout
  deterministic shell composition, slots, constraints

Projection
  product state -> render rows/surfaces

Renderer
  libvaxis draw calls only
```

## libvaxis

Use libvaxis as the terminal engine.

Take:

- raw terminal lifecycle
- keyboard, mouse, and resize events
- cell grid rendering
- clipping and window APIs
- style and color model
- terminal feature handling

Do not wrap libvaxis into a fake framework. Zi's `substrate` hides lifecycle
sharp edges and ownership details, but product rendering may use libvaxis
concepts where they fit.

## neovim

The useful Neovim lesson is conceptual, not implementation-specific:

```text
Buffer != Window != Tabpage
```

For Zi, that becomes:

```text
TranscriptDocument != TranscriptViewport != Surface
ComposerBuffer != ComposerView != ShellSlot
```

Zi must separate retained truth from views and layout. Extensions can request
changes to documents, buffers, and surfaces without owning layout or render
lifecycle.

Stable identifiers are separate from display order. Transcript blocks,
surfaces, slots, and future tabs/panes use stable ids; insertion or display
numbers may change.

## opentui

OpenTUI is useful for retained renderables and performance-oriented rendering,
but its architecture is shaped around a TypeScript API, FFI boundary, and Zig
native core. That is not Zi's shape.

Take:

- retained object and renderable discipline
- frame lifecycle
- benchmark mindset
- separation between public API objects and native rendering core

Do not take:

- component framework as Zi's core
- FFI-driven object model
- generic app framework abstractions

## zi core abstractions

Zi's TUI core abstractions are:

```text
Buffer
  retained mutable content, bounded, one owner

Document
  ordered blocks/items with stable ids

Viewport
  scroll/follow-tail/visible range over a document

Surface
  renderable rectangular product area with layer/order

Slot
  named bounded contribution point for built-ins/extensions

Frame
  immutable render input for one draw pass

Command
  only mutation path

Effect
  request to outside world: submit prompt, cancel run, open palette, etc.
```

Composer is a `Buffer + View`.

Transcript is a `Document + Viewport + Projection`.

Popovers, toasts, palette, autocomplete, and future extension UI are `Surface`s
in `Slot`s.

Extensions submit `Command`s and `Surface` contributions; they do not mutate
stores directly.

## frame rule

State mutation and rendering are separate phases.

The frame loop is:

```text
terminal event / agent event / extension request
  -> command queue
  -> ProductApp.apply()
  -> update stores/views
  -> build Frame
  -> render Frame with libvaxis
```

No callback may mutate product state during render. No extension owns layout.
No transcript row cache is source of truth.

## invariants

- libvaxis owns terminal mechanism.
- Zi does not build a second terminal framework above libvaxis.
- stores are retained truth; rows and cells are projections.
- each store has one owner and one mutation path.
- views own viewport, cursor, selection, focus, and follow-tail policy.
- layout is deterministic and does not mutate stores.
- surfaces render in deterministic `(layer, insertion_index)` order.
- slots are named, bounded contribution points.
- commands are the public mutation path for built-ins and future extensions.
- effects are explicit requests to outside systems.
- rendering consumes an immutable frame.
- product code may depend downward on primitive/substrate code; substrate and
  primitives must not import product policy.

## consequences

Composer and transcript work should start by building the primitives they need:

```text
primitive/text
primitive/buffer
primitive/document
primitive/viewport
primitive/render_list
product/composer
product/transcript
```

The first product implementation should prove:

- bounded composer input
- owned prompt submission
- stable transcript block ids
- streaming assistant deltas mutating one open block
- viewport follow-tail behavior
- deterministic row projection
- command-only mutation

The extension system should not be implemented yet, but the built-in product
path must use the same command, slot, surface, and frame rules future extensions
will use.

## rejected alternatives

- clone Neovim's implementation model. Zi needs the separation principle, not a
  text editor core.
- clone OpenTUI's component/FFI architecture. Zi is already Zig-native and does
  not need a TypeScript-shaped object model.
- hide libvaxis behind a generic framework. This duplicates the dependency Zi
  already chose and creates a second terminal abstraction.
- start from product MVP widgets and retrofit primitives later. This risks
  making transcript/composer semantics the substrate.
- let extensions mutate stores or layout directly. Extensions request; owners
  mutate.

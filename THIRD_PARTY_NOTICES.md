# Third-party notices

Zi depends on and adapts behavior from the projects listed below. The complete
license texts are retained under `third_party/licenses/`.

## Build dependency

- uucode 0.2.0, revision `8ad04b756f85a5ba1ac8d2b8cb48d0946f06b630`
  - Source: https://github.com/jacobsandlund/uucode
  - License: MIT
  - Its generated tables use Unicode data under the Unicode License v3.
  - Its UTF-8 implementation includes work by Bjoern Hoehrmann under the MIT
    license.

## Adapted source behavior

- fx, revision `5ed3be1b67e59b6607f09f69581107d70fa6d243`
  - Source: https://github.com/vercel-labs/fx
  - License: Apache-2.0
  - `src/tui/markdown/` adapts the incremental Markdown presentation processor
    and its parser and renderer leaf modules. `src/tui/transcript/Store.zig`
    adapts the bounded ordered semantic-entry store design. `src/tui/terminal/`
    adapts the normal-buffer cursor admission behavior.
    `src/tui/assistant/user_message_card.zig`,
    `src/tui/footer/presentation.zig`, `src/tui/footer/surface_frame.zig`,
    `src/tui/tools/tool_presentation.zig`, `src/tui/transcript/Runtime.zig`,
    `src/tui/transcript/painter.zig`,
    `src/tui/transcript/tool_group_projection.zig`,
    `src/tui/render_engine/transcript_blocks.zig`,
    `src/tui/render_engine/FooterLayout.zig`,
    `src/tui/render_engine/frame_builder.zig`,
    `src/tui/render_engine/frame_plan.zig`,
    `src/tui/render_engine/TerminalRenderer.zig`, and `src/tui/Screen.zig` adapt
    semantic transcript ownership, connected user-turn rails, grouped and
    action-oriented tool status, paint-time reflow, footer surface assembly,
    compact-until-full frame composition, owned-band synchronized publication,
    physical-scroll shadow update, and normal-buffer transcript finality from
    fx's corresponding presentation, transcript, footer, frame-builder, and
    terminal-diff owners.

- OpenTUI, revision `6f7833d09773b88cf5984b2a4e7bc428e1f8ffcb`
  - Source: https://github.com/anomalyco/opentui
  - License: MIT
  - `src/terminal_render/Text.zig` adapts terminal grapheme segmentation and
    display-width behavior from `packages/native/src/utf8.zig`.

## Design references only

Pi and ZigAI remain design references. Zi does not bundle their source.

- Pi: https://github.com/earendil-works/pi
- ZigAI: https://github.com/Kludex/zigai

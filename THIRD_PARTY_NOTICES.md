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
  - `src/smol/markdown/` adapts the incremental Markdown presentation processor
    and its parser and renderer leaf modules. `src/smol/transcript/Store.zig`
    adapts the ordered raw-entry store design. `src/smol/terminal/` adapts the
    normal-buffer cursor admission behavior.

- OpenTUI, revision `6f7833d09773b88cf5984b2a4e7bc428e1f8ffcb`
  - Source: https://github.com/anomalyco/opentui
  - License: MIT
  - `src/terminal_render/Text.zig` adapts terminal grapheme segmentation and
    display-width behavior from `packages/native/src/utf8.zig`.

## Design references only

Pi and ZigAI remain design references. Zi does not bundle their source.

- Pi: https://github.com/earendil-works/pi
- ZigAI: https://github.com/Kludex/zigai

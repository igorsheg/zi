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

## Vendored source

- md4x 0.0.29, revision `3e3036f272b925c9a3d191a93b5155577b3bc1b6`
  - Source: https://github.com/unjs/md4x
  - License: MIT
  - `third_party/md4x/` contains the parser and ANSI renderer subset used for
    terminal Markdown presentation. md4x is a fork of md4c and retains Martin
    Mitáš's and Pooya Parsa's copyright notices. The vendored heal source also
    preserves its attribution to Vercel's remend implementation.

## Adapted source behavior

- OpenTUI, revision `6f7833d09773b88cf5984b2a4e7bc428e1f8ffcb`
  - Source: https://github.com/anomalyco/opentui
  - License: MIT
  - `src/terminal_render/Text.zig` adapts terminal grapheme segmentation and
    display-width behavior from `packages/native/src/utf8.zig`.

## Design references only

Pi, ZigAI, and fx remain design references. Zi does not bundle their source.

- Pi: https://github.com/earendil-works/pi
- ZigAI: https://github.com/Kludex/zigai
- fx: https://github.com/vercel-labs/fx

#!/usr/bin/env bash
set -euo pipefail

zig build test >/dev/null
zig run -O ReleaseFast src/tui_render_bench.zig

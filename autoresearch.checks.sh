#!/bin/bash
set -euo pipefail
zig build test
zig build
ziglint
zig fmt --check src

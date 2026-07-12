#!/usr/bin/env sh
set -eu

prefix=${1:-"$HOME/.local"}
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$repo_dir"
zig build -Doptimize=ReleaseFast --prefix "$prefix"
printf 'installed zi to %s/bin/zi\n' "$prefix"

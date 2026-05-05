#!/usr/bin/env sh
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: $0 FILE..." >&2
  exit 2
fi

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$@"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$@"
else
  echo "error: neither shasum nor sha256sum found" >&2
  exit 1
fi

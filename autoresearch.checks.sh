#!/usr/bin/env bash
set -euo pipefail

zig build test >/tmp/zi-autoresearch-test.log 2>&1 || {
  tail -80 /tmp/zi-autoresearch-test.log
  exit 1
}
zig build >/tmp/zi-autoresearch-build.log 2>&1 || {
  tail -80 /tmp/zi-autoresearch-build.log
  exit 1
}
zig fmt --check src >/tmp/zi-autoresearch-fmt.log 2>&1 || {
  cat /tmp/zi-autoresearch-fmt.log
  exit 1
}

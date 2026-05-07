#!/usr/bin/env sh
set -eu

version="${1:-0.0.0-local}"

case "$version" in
  v*)
    echo "error: version must not include leading v: $version" >&2
    exit 2
    ;;
  "")
    echo "error: version must not be empty" >&2
    exit 2
    ;;
esac

uname_s=$(uname -s)
uname_m=$(uname -m)

case "$uname_s:$uname_m" in
  Darwin:arm64) dist_target="aarch64-apple-darwin" ;;
  Darwin:x86_64) dist_target="x86_64-apple-darwin" ;;
  Linux:x86_64) dist_target="x86_64-unknown-linux-musl" ;;
  Linux:aarch64|Linux:arm64) dist_target="aarch64-unknown-linux-musl" ;;
  *)
    echo "error: unsupported host for release check: $uname_s $uname_m" >&2
    exit 1
    ;;
esac

printf 'release-check: version=%s target=%s\n' "$version" "$dist_target"

git ls-files '*.zig' -z | xargs -0 zig fmt --check
zig build test --summary all
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dversion="$version"

test "$(./zig-out/bin/zi --version)" = "zi $version"
./zig-out/bin/zi --help >/dev/null

archive=$(./scripts/package-release.sh "$version" "$dist_target")
case "$archive" in
  *.tar.gz) tar -tzf "$archive" >/dev/null ;;
  *.zip)
    if command -v unzip >/dev/null 2>&1; then
      unzip -tq "$archive" >/dev/null
    else
      echo "warning: unzip not found; skipping zip archive validation" >&2
    fi
    ;;
  *)
    echo "error: unknown archive kind: $archive" >&2
    exit 1
    ;;
esac

./scripts/checksums.sh "$archive" > dist/checksums.txt
printf 'release-check: wrote %s\n' "$archive"
printf 'release-check: wrote dist/checksums.txt\n'

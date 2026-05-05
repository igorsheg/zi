#!/usr/bin/env sh
set -eu

usage() {
  echo "usage: $0 VERSION DIST_TARGET [ARCHIVE_KIND]" >&2
  echo "  VERSION:      release version without leading v, e.g. 0.1.0" >&2
  echo "  DIST_TARGET:  distribution target, e.g. aarch64-apple-darwin" >&2
  echo "  ARCHIVE_KIND: tar.gz or zip; defaults to zip for *windows*, tar.gz otherwise" >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
  exit 2
fi

version="$1"
dist_target="$2"
archive_kind="${3:-}"

case "$version" in
  v*)
    echo "error: VERSION must not include leading v: $version" >&2
    exit 2
    ;;
  "")
    echo "error: VERSION must not be empty" >&2
    exit 2
    ;;
esac

case "$dist_target" in
  "")
    echo "error: DIST_TARGET must not be empty" >&2
    exit 2
    ;;
esac

if [ -z "$archive_kind" ]; then
  case "$dist_target" in
    *windows*) archive_kind="zip" ;;
    *) archive_kind="tar.gz" ;;
  esac
fi

case "$archive_kind" in
  tar.gz|zip) ;;
  *)
    echo "error: ARCHIVE_KIND must be tar.gz or zip, got: $archive_kind" >&2
    exit 2
    ;;
esac

binary_name="zi"
case "$dist_target" in
  *windows*) binary_name="zi.exe" ;;
esac

binary_path="zig-out/bin/$binary_name"
if [ ! -f "$binary_path" ]; then
  echo "error: built binary not found: $binary_path" >&2
  echo "hint: run zig build -Doptimize=ReleaseSafe -Dversion=$version first" >&2
  exit 1
fi

# Unsigned Mach-O binaries downloaded from the internet can be killed by
# macOS before main() runs. Ad-hoc signing is local, requires no Apple
# identity, and keeps the CLI usable until we have Developer ID notarization.
if [ "$(uname -s)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  case "$dist_target" in
    *apple-darwin) codesign --force --sign - "$binary_path" >/dev/null 2>&1 || true ;;
  esac
fi

# Smoke-test native/package-host runnable binaries. Cross-built binaries may not
# execute on the packaging host, so a failed exec is only fatal when the command
# runs and reports the wrong version.
if [ -x "$binary_path" ]; then
  set +e
  version_output=$("./$binary_path" --version 2>/dev/null)
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    expected="zi $version"
    if [ "$version_output" != "$expected" ]; then
      echo "error: binary version mismatch" >&2
      echo "expected: $expected" >&2
      echo "actual:   $version_output" >&2
      exit 1
    fi
  else
    echo "warning: skipping binary smoke test; $binary_path is not runnable on this host" >&2
  fi
fi

package_name="zi-v$version-$dist_target"
stage_root="dist/stage"
stage_dir="$stage_root/$package_name"

rm -rf "$stage_dir"
mkdir -p "$stage_dir/bin"
mkdir -p "dist"

cp "$binary_path" "$stage_dir/bin/$binary_name"
chmod 755 "$stage_dir/bin/$binary_name" 2>/dev/null || true

if [ -f "README.md" ]; then
  cp "README.md" "$stage_dir/README.md"
fi

if [ -f "LICENSE" ]; then
  cp "LICENSE" "$stage_dir/LICENSE"
fi

case "$archive_kind" in
  tar.gz)
    archive="dist/$package_name.tar.gz"
    rm -f "$archive"
    (cd "$stage_root" && tar -czf "../$package_name.tar.gz" "$package_name")
    ;;
  zip)
    archive="dist/$package_name.zip"
    rm -f "$archive"
    if command -v zip >/dev/null 2>&1; then
      (cd "$stage_root" && zip -qr "../$package_name.zip" "$package_name")
    else
      echo "error: zip command not found" >&2
      exit 1
    fi
    ;;
esac

printf '%s\n' "$archive"

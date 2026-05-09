#!/usr/bin/env sh
set -eu

repo="${ZI_REPO:-igorsheg/zi}"
install_dir="${ZI_INSTALL_DIR:-$HOME/.local/bin}"
version="${ZI_VERSION:-}"

usage() {
  echo "usage: install.sh [--version VERSION] [--dir DIR]" >&2
  echo "" >&2
  echo "environment:" >&2
  echo "  ZI_VERSION       version without leading v, e.g. 0.1.0" >&2
  echo "  ZI_INSTALL_DIR   install directory, default: \$HOME/.local/bin" >&2
  echo "  ZI_REPO          GitHub repo, default: igorsheg/zi" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      version="$2"
      shift 2
      ;;
    --dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      install_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$version" in
  v*)
    echo "error: version must not include leading v: $version" >&2
    exit 2
    ;;
esac

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

has() {
  command -v "$1" >/dev/null 2>&1
}

download() {
  url=$1
  output=$2

  if has curl; then
    curl_path=$(command -v curl)
    case "$curl_path" in
      */snap/*)
        if has wget; then
          wget -q "$url" -O "$output"
          return
        fi
        echo "error: curl installed with snap cannot download files due to missing permissions" >&2
        echo "hint: install curl with a different package manager, or install wget" >&2
        exit 1
        ;;
    esac

    curl -fsSL "$url" -o "$output"
  elif has wget; then
    wget -q "$url" -O "$output"
  else
    echo "error: required command not found: curl or wget" >&2
    exit 1
  fi
}

fetch() {
  url=$1

  if has curl; then
    curl_path=$(command -v curl)
    case "$curl_path" in
      */snap/*)
        if has wget; then
          wget -qO- "$url"
          return
        fi
        echo "error: curl installed with snap cannot download files due to missing permissions" >&2
        echo "hint: install curl with a different package manager, or install wget" >&2
        exit 1
        ;;
    esac

    curl -fsSL "$url"
  elif has wget; then
    wget -qO- "$url"
  else
    echo "error: required command not found: curl or wget" >&2
    exit 1
  fi
}

need tar
need mktemp
need grep
need sed
need mv
need cp

if command -v shasum >/dev/null 2>&1; then
  checksum_cmd="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  checksum_cmd="sha256sum"
else
  echo "error: required command not found: shasum or sha256sum" >&2
  exit 1
fi

os=$(uname -s)
arch=$(uname -m)

case "$os:$arch" in
  Darwin:arm64) target="aarch64-apple-darwin" ;;
  Darwin:x86_64)
    echo "error: Intel macOS prebuilt artifacts are not published yet" >&2
    echo "hint: build from source with: zig build -Doptimize=ReleaseSafe" >&2
    exit 1
    ;;
  Linux:x86_64) target="x86_64-unknown-linux-musl" ;;
  Linux:aarch64|Linux:arm64) target="aarch64-unknown-linux-musl" ;;
  *)
    echo "error: unsupported platform: $os $arch" >&2
    exit 1
    ;;
esac

if [ -z "$version" ]; then
  latest_api_url="https://api.github.com/repos/$repo/releases/latest"
  tag=$(fetch "$latest_api_url" | grep '"tag_name"' | head -n 1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
  case "$tag" in
    v*) version=${tag#v} ;;
    *)
      echo "error: could not resolve latest release version from GitHub API" >&2
      exit 1
      ;;
  esac
fi

archive="zi-v$version-$target.tar.gz"
base_url="https://github.com/$repo/releases/download/v$version"
work_dir=$(mktemp -d)
install_tmp=
cleanup() {
  if [ -n "$install_tmp" ]; then
    rm -f "$install_tmp"
  fi
  rm -rf "$work_dir"
}
interrupt() {
  cleanup
  exit 1
}
trap cleanup EXIT
trap interrupt INT TERM

printf 'zi installer\n'
printf '  version: %s\n' "$version"
printf '  target:  %s\n' "$target"
printf '  dir:     %s\n' "$install_dir"

download "$base_url/$archive" "$work_dir/$archive"
download "$base_url/checksums.txt" "$work_dir/checksums.txt"

(
  cd "$work_dir"
  expected=$(grep "  $archive\$" checksums.txt || true)
  if [ -z "$expected" ]; then
    echo "error: checksum entry not found for $archive" >&2
    exit 1
  fi
  printf '%s\n' "$expected" | $checksum_cmd -c - >/dev/null
)

mkdir -p "$install_dir"
tar -xzf "$work_dir/$archive" -C "$work_dir"
package_dir="$work_dir/zi-v$version-$target"

if [ ! -x "$package_dir/bin/zi" ]; then
  echo "error: archive did not contain executable bin/zi" >&2
  exit 1
fi

install_tmp=$(mktemp "$install_dir/.zi.XXXXXX")
cp "$package_dir/bin/zi" "$install_tmp"
chmod 755 "$install_tmp"

# Unsigned Mach-O binaries downloaded from the internet can be killed by
# macOS before main() runs. Ad-hoc signing is local, requires no Apple
# identity, and keeps the CLI usable until we have Developer ID notarization.
if [ "$os" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$install_tmp" >/dev/null 2>&1 || {
    echo "warning: failed to ad-hoc sign $install_tmp" >&2
  }
fi

mv "$install_tmp" "$install_dir/zi"
install_tmp=

printf '\ninstalled zi to %s/zi\n' "$install_dir"
"$install_dir/zi" --version

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    printf '\nadd this to your shell profile if needed:\n\n'
    printf '  export PATH="%s:$PATH"\n\n' "$install_dir"
    printf 'then run:\n\n'
    printf '  zi --version\n'
    ;;
esac

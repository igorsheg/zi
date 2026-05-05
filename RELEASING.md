# Releasing zi

This document is the release ritual for zi. Keep it boring.

## Supported prebuilt artifacts

Current release artifacts:

- `aarch64-apple-darwin`
- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`

Not currently published:

- Intel macOS (`x86_64-apple-darwin`)
- Windows

Intel macOS users can build from source for now.

## Version source of truth

Release versions come from git tags.

A tag like:

```sh
v0.1.0
```

builds binaries that report:

```text
zi 0.1.0
```

A prerelease tag like:

```sh
v0.1.0-rc.1
```

builds binaries that report:

```text
zi 0.1.0-rc.1
```

Do not move published tags. If a release is broken, fix forward with a new tag.

## Local preflight

Run a local release check before using GitHub Actions:

```sh
./scripts/release-check.sh 0.1.0-rc.1
```

This checks formatting, runs tests, builds a release-safe native binary, packages it, validates the archive, and writes a local checksum file.

## Release candidate build

Manual workflow runs are release-candidate builds. They do not publish a GitHub Release.

In GitHub:

```text
Actions → Release → Run workflow
version: 0.1.0-rc.1
```

Expected result:

```text
zi-release-candidate-v0.1.0-rc.1
```

containing:

```text
checksums.txt
zi-v0.1.0-rc.1-aarch64-apple-darwin.tar.gz
zi-v0.1.0-rc.1-aarch64-unknown-linux-musl.tar.gz
zi-v0.1.0-rc.1-x86_64-unknown-linux-musl.tar.gz
```

Download and verify:

```sh
gh run download <run-id> \
  -n zi-release-candidate-v0.1.0-rc.1 \
  -D /tmp/zi-rc

cd /tmp/zi-rc
shasum -a 256 -c checksums.txt
```

Smoke-test the local platform artifact:

```sh
tar -xzf zi-v0.1.0-rc.1-aarch64-apple-darwin.tar.gz
./zi-v0.1.0-rc.1-aarch64-apple-darwin/bin/zi --version
./zi-v0.1.0-rc.1-aarch64-apple-darwin/bin/zi --help
```

Expected version output:

```text
zi 0.1.0-rc.1
```

## Publish a prerelease

A manual workflow run does not publish a GitHub Release. To publish a prerelease, push a prerelease tag:

```sh
git tag v0.1.0-rc.1
git push origin v0.1.0-rc.1
```

The `Release` workflow will build artifacts, generate `checksums.txt`, and publish a GitHub Release for the tag.

## Publish a final release

After an RC is verified, publish a final tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Verify the published release:

```sh
gh release view v0.1.0
gh release download v0.1.0 -D /tmp/zi-release
cd /tmp/zi-release
shasum -a 256 -c checksums.txt
```

Smoke-test the downloaded artifact for the local platform.

## Install script testing

After a GitHub Release exists, test the installer against that version:

```sh
ZI_VERSION=0.1.0-rc.1 ./scripts/install.sh
```

Or through curl:

```sh
curl -fsSL https://raw.githubusercontent.com/igorsheg/zi/main/scripts/install.sh | ZI_VERSION=0.1.0-rc.1 sh
```

The friendly public URL is intended to be:

```sh
curl -fsSL https://withzi.dev/install | sh
```

That route depends on the website/Cloudflare Pages deployment being configured.

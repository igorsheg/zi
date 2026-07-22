#!/usr/bin/env bun

import { chmod, mkdir, rm } from "node:fs/promises"
import { basename, join, resolve } from "node:path"

import { compileZi } from "./compile-zi.js"

const releaseTargets = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-x64"] as const

type ReleaseTarget = (typeof releaseTargets)[number]

export interface ReleaseBuildOptions {
  readonly version: string
  readonly target: ReleaseTarget
}

export function parseReleaseBuildOptions(
  argv: readonly string[],
  env: Readonly<Record<string, string | undefined>> = process.env
): ReleaseBuildOptions {
  let version = env.ZI_RELEASE_VERSION
  let target = env.ZI_RELEASE_TARGET

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]
    if (arg === "--version") version = required(argv[++index], "--version")
    else if (arg === "--target") target = required(argv[++index], "--target")
    else throw new Error(`Unknown release build argument: ${arg}`)
  }

  if (!version) throw new Error("Release version is required through --version or ZI_RELEASE_VERSION")
  return { version: normalizeVersion(version), target: target ? releaseTarget(target) : currentReleaseTarget() }
}

export function normalizeVersion(value: string): string {
  const version = value.startsWith("v") ? value.slice(1) : value
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(version)
  const core = match?.slice(1, 4) ?? []
  const prerelease = match?.[4]?.split(".") ?? []
  if (
    version.length > 128 ||
    core.length !== 3 ||
    core.some(hasLeadingZero) ||
    prerelease.some(part => !part || !/^[0-9A-Za-z-]+$/.test(part) || (/^\d+$/.test(part) && hasLeadingZero(part)))
  ) {
    throw new Error(`Invalid release version: ${value}`)
  }
  return version
}

export function currentReleaseTarget(platform = process.platform, arch = process.arch): ReleaseTarget {
  const target = `${platform === "win32" ? "windows" : platform}-${arch}`
  return releaseTarget(target)
}

export function releaseArchiveName(options: ReleaseBuildOptions): string {
  return `zi-${options.version}-${options.target}.tar.gz`
}

async function buildRelease(options: ReleaseBuildOptions): Promise<void> {
  const actualTarget = currentReleaseTarget()
  if (options.target !== actualTarget) {
    throw new Error(`Release target ${options.target} must be built on ${options.target}; this host is ${actualTarget}`)
  }

  const root = resolve(import.meta.dirname, "..")
  const outputDirectory = join(root, "dist")
  const packageName = `zi-${options.version}-${options.target}`
  const packageDirectory = join(outputDirectory, packageName)
  const executableName = options.target.startsWith("windows-") ? "zi.exe" : "zi"
  const executable = join(packageDirectory, executableName)
  const archive = join(outputDirectory, releaseArchiveName(options))

  await mkdir(outputDirectory, { recursive: true })
  await rm(packageDirectory, { recursive: true, force: true })
  await rm(archive, { force: true })
  await rm(`${archive}.sha256`, { force: true })
  await mkdir(packageDirectory)

  try {
    await compileZi({ outfile: executable, version: options.version })
    if (process.platform !== "win32") await chmod(executable, 0o755)
    await run(["tar", "-czf", archive, "-C", outputDirectory, packageName], {
      cwd: root,
      env: { ...process.env, COPYFILE_DISABLE: "1" }
    })
    const digest = await sha256(archive)
    await Bun.write(`${archive}.sha256`, `${digest}  ${basename(archive)}\n`)
    console.log(`${archive}\n${archive}.sha256`)
  } finally {
    await rm(packageDirectory, { recursive: true, force: true })
  }
}

async function sha256(path: string): Promise<string> {
  const file = Bun.file(path)
  if (file.size > 256 * 1024 * 1024) throw new Error("Release archives cannot exceed 256 MiB")
  const hasher = new Bun.CryptoHasher("sha256")
  hasher.update(await file.arrayBuffer())
  return hasher.digest("hex")
}

async function run(
  command: readonly [string, ...string[]],
  options: { readonly cwd: string; readonly env: Readonly<Record<string, string | undefined>> }
): Promise<void> {
  const child = Bun.spawn([...command], { ...options, stdin: "ignore", stdout: "inherit", stderr: "inherit" })
  const exitCode = await child.exited
  if (exitCode !== 0) throw new Error(`${command[0]} exited with code ${exitCode}`)
}

function releaseTarget(value: string): ReleaseTarget {
  switch (value) {
    case "darwin-arm64":
    case "darwin-x64":
    case "linux-arm64":
    case "linux-x64":
    case "windows-x64":
      return value
    default:
      throw new Error(`Unsupported release target: ${value}`)
  }
}

function hasLeadingZero(value: string): boolean {
  return value.length > 1 && value.startsWith("0")
}

function required(value: string | undefined, flag: string): string {
  if (!value) throw new Error(`${flag} requires a value`)
  return value
}

if (import.meta.main) {
  try {
    await buildRelease(parseReleaseBuildOptions(process.argv.slice(2)))
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    console.error(message)
    process.exitCode = 1
  }
}

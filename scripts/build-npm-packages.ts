#!/usr/bin/env bun

import { existsSync } from "node:fs"
import { chmod, cp, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, dirname, join, resolve } from "node:path"

import {
  currentReleaseTarget,
  normalizeVersion,
  releaseArchiveName,
  releaseTarget,
  releaseTargets,
  type ReleaseTarget
} from "./build-release.js"

export const npmPackageScope = "@with-zi"
export const npmCliPackageName = `${npmPackageScope}/zi`

export type NpmPackMode = "none" | "dry-run" | "pack"

export interface NpmPackageBuildOptions {
  readonly version: string
  readonly targets: readonly ReleaseTarget[]
  readonly distDir: string
  readonly packMode: NpmPackMode
  readonly verifyCurrent: boolean
}

export interface NpmPackageBuild {
  readonly packageName: string
  readonly directory: string
  readonly tarball?: string
}

export interface NpmPackageBuildResult {
  readonly npmRoot: string
  readonly packages: readonly NpmPackageBuild[]
}

interface NpmPlatform {
  readonly os: "darwin" | "linux" | "win32"
  readonly cpu: "arm64" | "x64"
  readonly executable: "zi" | "zi.exe"
}

const repository = Object.freeze({ type: "git", url: "git+https://github.com/igorsheg/zi.git" })
const allPlatformDependencies = Object.freeze(
  Object.fromEntries(releaseTargets.map(target => [npmPlatformPackageName(target), "0.0.0"]))
)

export function parseNpmPackageBuildOptions(
  argv: readonly string[],
  env: Readonly<Record<string, string | undefined>> = process.env
): NpmPackageBuildOptions {
  const root = resolve(import.meta.dirname, "..")
  let version = env.ZI_RELEASE_VERSION
  let distDir = env.ZI_RELEASE_DIST ?? "dist"
  let packMode: NpmPackMode = "dry-run"
  let verifyCurrent = false
  const targets: ReleaseTarget[] = []

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]
    if (arg === "--version") version = required(argv[++index], "--version")
    else if (arg === "--dist") distDir = required(argv[++index], "--dist")
    else if (arg === "--target") targets.push(releaseTarget(required(argv[++index], "--target")))
    else if (arg === "--no-pack") packMode = "none"
    else if (arg === "--dry-run") packMode = "dry-run"
    else if (arg === "--pack") packMode = "pack"
    else if (arg === "--verify-current") verifyCurrent = true
    else throw new Error(`Unknown npm package argument: ${arg}`)
  }

  if (!version) throw new Error("NPM package version is required through --version or ZI_RELEASE_VERSION")
  return {
    version: normalizeVersion(version),
    targets: targets.length > 0 ? targets : releaseTargets,
    distDir: resolve(root, distDir),
    packMode,
    verifyCurrent
  }
}

export function npmPlatformPackageName(target: ReleaseTarget): string {
  return `${npmPackageScope}/zi-${target}`
}

export function npmPlatform(target: ReleaseTarget): NpmPlatform {
  switch (target) {
    case "darwin-arm64":
      return { os: "darwin", cpu: "arm64", executable: "zi" }
    case "darwin-x64":
      return { os: "darwin", cpu: "x64", executable: "zi" }
    case "linux-arm64":
      return { os: "linux", cpu: "arm64", executable: "zi" }
    case "linux-x64":
      return { os: "linux", cpu: "x64", executable: "zi" }
    case "windows-x64":
      return { os: "win32", cpu: "x64", executable: "zi.exe" }
    default: {
      const exhaustive: never = target
      return exhaustive
    }
  }
}

export async function buildNpmPackages(options: NpmPackageBuildOptions): Promise<NpmPackageBuildResult> {
  const root = resolve(import.meta.dirname, "..")
  const npmRoot = join(options.distDir, "npm")
  const extractRoot = join(npmRoot, ".extract")
  await rm(npmRoot, { recursive: true, force: true })
  await mkdir(extractRoot, { recursive: true })

  const platformPackages = await Promise.all(
    options.targets.map(target =>
      buildPlatformPackage({ root, npmRoot, extractRoot, version: options.version, target })
    )
  )
  const packages = [...platformPackages, await buildCliPackage({ root, npmRoot, version: options.version })]

  const packed = await Promise.all(
    packages.map(async built => {
      const tarball = await packPackage(built.directory, npmRoot, options.packMode)
      return tarball ? Object.freeze({ packageName: built.packageName, directory: built.directory, tarball }) : built
    })
  )

  await rm(extractRoot, { recursive: true, force: true })
  const result = Object.freeze({ npmRoot, packages: Object.freeze(packed) })
  if (options.verifyCurrent) await verifyCurrentInstall(result, options.version)
  return result
}

async function buildPlatformPackage(input: {
  readonly root: string
  readonly npmRoot: string
  readonly extractRoot: string
  readonly version: string
  readonly target: ReleaseTarget
}): Promise<NpmPackageBuild> {
  const platform = npmPlatform(input.target)
  const archive = join(input.npmRoot, "..", releaseArchiveName({ version: input.version, target: input.target }))
  if (!existsSync(archive)) throw new Error(`Missing release archive for npm packaging: ${archive}`)

  const extractDir = join(input.extractRoot, input.target)
  await mkdir(extractDir, { recursive: true })
  await run(["tar", "-xzf", archive, "-C", extractDir], input.root)

  const sourceExecutable = join(extractDir, `zi-${input.version}-${input.target}`, platform.executable)
  if (!existsSync(sourceExecutable))
    throw new Error(`Release archive did not contain ${platform.executable}: ${archive}`)

  const packageName = npmPlatformPackageName(input.target)
  const directory = join(input.npmRoot, packageDirectoryName(packageName))
  await mkdir(join(directory, "bin"), { recursive: true })
  const packagedExecutable = join(directory, "bin", platform.executable)
  await cp(sourceExecutable, packagedExecutable)
  if (platform.executable === "zi") await chmod(packagedExecutable, 0o755)

  await copyReleaseMetadata(input.root, directory)
  await writeJson(join(directory, "package.json"), {
    name: packageName,
    version: input.version,
    description: `Native Zi executable for ${input.target}`,
    license: "MIT",
    repository,
    os: [platform.os],
    cpu: [platform.cpu],
    files: ["bin", "LICENSE", "THIRD_PARTY_NOTICES.md"],
    publishConfig: { access: "public" }
  })
  return Object.freeze({ packageName, directory })
}

async function buildCliPackage(input: {
  readonly root: string
  readonly npmRoot: string
  readonly version: string
}): Promise<NpmPackageBuild> {
  const directory = join(input.npmRoot, packageDirectoryName(npmCliPackageName))
  await mkdir(join(directory, "bin"), { recursive: true })
  await copyReleaseMetadata(input.root, directory)
  await cp(join(input.root, "README.md"), join(directory, "README.md"))
  const bin = join(directory, "bin", "zi.js")
  await writeFile(bin, cliResolverSource())
  await chmod(bin, 0o755)

  await writeJson(join(directory, "package.json"), {
    name: npmCliPackageName,
    version: input.version,
    description: "Zi coding-agent CLI",
    license: "MIT",
    type: "module",
    repository,
    bin: { zi: "./bin/zi.js" },
    files: ["bin", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"],
    optionalDependencies: Object.fromEntries(Object.keys(allPlatformDependencies).map(name => [name, input.version])),
    publishConfig: { access: "public" }
  })
  return Object.freeze({ packageName: npmCliPackageName, directory })
}

async function copyReleaseMetadata(root: string, directory: string): Promise<void> {
  await cp(join(root, "LICENSE"), join(directory, "LICENSE"))
  await cp(join(root, "THIRD_PARTY_NOTICES.md"), join(directory, "THIRD_PARTY_NOTICES.md"))
}

function cliResolverSource(): string {
  return `#!/usr/bin/env node
import { spawnSync } from "node:child_process"
import { createRequire } from "node:module"
import { dirname, join } from "node:path"

const require = createRequire(import.meta.url)
const target = targetFor(process.platform, process.arch)
const packageName = ${JSON.stringify(npmPackageScope)} + "/zi-" + target
let packageJson
try {
  packageJson = require.resolve(packageName + "/package.json")
} catch {
  console.error("Zi native package " + packageName + " is not installed. Reinstall " + ${JSON.stringify(npmCliPackageName)} + ".")
  process.exit(1)
}

const executable = join(dirname(packageJson), "bin", process.platform === "win32" ? "zi.exe" : "zi")
const result = spawnSync(executable, process.argv.slice(2), { stdio: "inherit" })
if (result.error) {
  console.error(result.error.message)
  process.exit(1)
}
if (result.signal) process.exit(128)
process.exit(result.status ?? 1)

function targetFor(platform, arch) {
  if (platform === "darwin" && arch === "arm64") return "darwin-arm64"
  if (platform === "darwin" && arch === "x64") return "darwin-x64"
  if (platform === "linux" && arch === "arm64") return "linux-arm64"
  if (platform === "linux" && arch === "x64") return "linux-x64"
  if (platform === "win32" && arch === "x64") return "windows-x64"
  console.error("Zi has no native npm package for " + platform + "/" + arch + ".")
  process.exit(1)
}
`
}

async function packPackage(directory: string, npmRoot: string, mode: NpmPackMode): Promise<string | undefined> {
  if (mode === "none") return undefined
  const args = ["npm", "pack", "--json", "--pack-destination", npmRoot]
  if (mode === "dry-run") args.push("--dry-run")
  const output = await runCapture(args, directory)
  const parsed: unknown = JSON.parse(output)
  if (!Array.isArray(parsed) || parsed.length !== 1 || !isRecord(parsed[0]) || typeof parsed[0].filename !== "string") {
    throw new Error(`Unexpected npm pack output for ${directory}`)
  }
  return mode === "pack" ? join(npmRoot, basename(parsed[0].filename)) : undefined
}

async function verifyCurrentInstall(result: NpmPackageBuildResult, version: string): Promise<void> {
  const target = currentReleaseTarget()
  const platformTarball = requirePackedTarball(result, npmPlatformPackageName(target))
  const cliTarball = requirePackedTarball(result, npmCliPackageName)
  const temporary = await mkdtemp(join(tmpdir(), "zi-npm-install-"))
  try {
    await writeJson(join(temporary, "package.json"), { private: true })
    // The current platform tarball is installed directly; npm still probes optional dependency metadata.
    // Keep that probe bounded so local packaging does not require the packages to exist in the registry yet.
    await run(
      [
        "npm",
        "install",
        "--ignore-scripts",
        "--omit=optional",
        "--no-audit",
        "--no-fund",
        "--fetch-retries=0",
        "--fetch-timeout=1000",
        platformTarball,
        cliTarball
      ],
      temporary
    )
    const command = join(temporary, "node_modules", ".bin", process.platform === "win32" ? "zi.cmd" : "zi")
    const child = Bun.spawn([command, "--version"], { cwd: temporary, stdin: "ignore", stdout: "pipe", stderr: "pipe" })
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])
    if (exitCode !== 0 || stdout !== `zi ${version}\n` || stderr !== "") {
      throw new Error(`Packed npm CLI failed its version smoke test (exit ${exitCode}): ${stderr || stdout}`)
    }
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}

function requirePackedTarball(result: NpmPackageBuildResult, packageName: string): string {
  const match = result.packages.find(candidate => candidate.packageName === packageName)
  if (!match?.tarball) throw new Error(`Packed tarball is required for ${packageName}`)
  return match.tarball
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`)
}

async function run(command: readonly [string, ...string[]], cwd: string): Promise<void> {
  const child = Bun.spawn([...command], { cwd, stdin: "ignore", stdout: "inherit", stderr: "inherit" })
  const exitCode = await child.exited
  if (exitCode !== 0) throw new Error(`${command[0]} exited with code ${exitCode}`)
}

async function runCapture(command: readonly string[], cwd: string): Promise<string> {
  if (command.length === 0) throw new Error("Cannot run an empty command")
  const child = Bun.spawn([...command], { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  if (exitCode !== 0) throw new Error(`${command[0]} exited with code ${exitCode}: ${stderr}`)
  return stdout
}

function packageDirectoryName(packageName: string): string {
  return packageName.replace(/^@/, "").replace(/\//g, "-")
}

function required(value: string | undefined, flag: string): string {
  if (!value) throw new Error(`${flag} requires a value`)
  return value
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

if (import.meta.main) {
  try {
    const result = await buildNpmPackages(parseNpmPackageBuildOptions(process.argv.slice(2)))
    console.log(result.packages.map(candidate => candidate.tarball ?? candidate.directory).join("\n"))
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    console.error(message)
    process.exitCode = 1
  }
}

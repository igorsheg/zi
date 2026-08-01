#!/usr/bin/env bun
/**
 * Install the local ./dist/zi build onto PATH.
 *
 * Default destination: ~/.local/bin/zi (already on many developer PATHs).
 * Mimics "npx/local toolchain" use without publishing.
 *
 * Usage:
 *   bun scripts/install-local-zi.ts
 *   bun scripts/install-local-zi.ts --build
 *   bun scripts/install-local-zi.ts --bin-dir ~/.local/bin
 */
import { access, chmod, copyFile, mkdir, rm, symlink, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join, resolve } from "node:path"

const root = resolve(import.meta.dirname, "..")
const defaultBinDir = join(homedir(), ".local", "bin")
type Args = { readonly build: boolean; readonly binDir: string; readonly link: boolean }

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2))
  const executableName = process.platform === "win32" ? "zi.exe" : "zi"
  const source = join(root, "dist", executableName)

  if (args.build || !(await exists(source))) {
    console.log(args.build ? "Building local zi…" : "dist/zi missing; building…")
    const build = Bun.spawn(["bun", "run", "build"], {
      cwd: root,
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit"
    })
    const code = await build.exited
    if (code !== 0) throw new Error(`build failed with exit ${code}`)
  }

  if (!(await exists(source))) throw new Error(`Built executable not found: ${source}`)

  await mkdir(args.binDir, { recursive: true })
  const destination = join(args.binDir, executableName)

  if (args.link && process.platform !== "win32") {
    await rm(destination, { force: true })
    await symlink(source, destination)
    console.log(`Linked ${destination} -> ${source}`)
  } else {
    // Copy so replacing dist/ mid-session cannot yank the PATH binary out from under open processes.
    const pending = `${destination}.${process.pid}.tmp`
    await copyFile(source, pending)
    await chmod(pending, 0o755)
    await rm(destination, { force: true })
    // rename over existing can fail across devices; copy+rm already used for payload.
    await copyFile(pending, destination)
    await chmod(destination, 0o755)
    await rm(pending, { force: true })
    console.log(`Installed ${destination}`)
  }

  const pathEntries = (process.env.PATH ?? "").split(delimiter())
  const onPath = pathEntries.some(entry => resolve(entry || ".") === resolve(args.binDir))
  if (!onPath) {
    console.log(`Warning: ${args.binDir} is not on PATH. Add it, e.g.:`)
    console.log(`  export PATH=${shellQuote(args.binDir)}:$PATH`)
  }

  // bun's global bin often precedes ~/.local/bin; retarget it so `zi` means this build.
  await maybeRetargetBunGlobalZi(destination)

  // Resolve which `zi` the current environment prefers.
  const which = Bun.spawnSync(["bash", "-lc", "command -v zi || true"], {
    stdout: "pipe",
    stderr: "pipe",
    env: process.env
  })
  const resolved = which.stdout.toString().trim()
  console.log(resolved ? `command -v zi → ${resolved}` : "command -v zi → (not found)")
  if (resolved && resolve(resolved) !== resolve(destination)) {
    const resolvedVersion = Bun.spawnSync([resolved, "--version"], { stdout: "pipe", stderr: "pipe" })
    const installedVersion = Bun.spawnSync([destination, "--version"], { stdout: "pipe", stderr: "pipe" })
    const left = (resolvedVersion.stdout.toString() || resolvedVersion.stderr.toString()).trim()
    const right = (installedVersion.stdout.toString() || installedVersion.stderr.toString()).trim()
    if (left !== right) {
      console.log(
        `Note: PATH still prefers ${resolved} (${left || "unknown"}) over ${destination} (${right || "unknown"})`
      )
    }
  }

  const version = Bun.spawnSync([destination, "--version"], { stdout: "pipe", stderr: "pipe" })
  if (version.exitCode === 0) {
    console.log(version.stdout.toString().trim() || version.stderr.toString().trim())
  }
}

async function maybeRetargetBunGlobalZi(destination: string): Promise<void> {
  const bunBin = join(homedir(), ".bun", "bin", process.platform === "win32" ? "zi.exe" : "zi")
  if (!(await exists(bunBin))) return
  if (resolve(bunBin) === resolve(destination)) return

  // Keep a one-line wrapper so npm global upgrades do not leave a stale Mach-O behind:
  // the wrapper always execs the installed local binary path.
  const wrapper = [
    "#!/usr/bin/env bash",
    `# installed by scripts/install-local-zi.ts — points at the local Zi build`,
    `exec ${shellQuote(destination)} "$@"`,
    ""
  ].join("\n")
  const pending = `${bunBin}.${process.pid}.tmp`
  await writeFile(pending, wrapper, { mode: 0o755 })
  await chmod(pending, 0o755)
  await rm(bunBin, { force: true })
  await copyFile(pending, bunBin)
  await chmod(bunBin, 0o755)
  await rm(pending, { force: true })
  console.log(`Retargeted ${bunBin} → exec ${destination}`)
}

function parseArgs(argv: readonly string[]): Args {
  let build = false
  let link = false
  let binDir = defaultBinDir
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === "--build") build = true
    else if (arg === "--link") link = true
    else if (arg === "--bin-dir") {
      const next = argv[++i]
      if (!next) throw new Error("--bin-dir requires a path")
      binDir = resolve(expandHome(next))
    } else if (arg === "--help" || arg === "-h") {
      printHelp()
      process.exit(0)
    } else {
      throw new Error(`Unknown argument: ${arg}`)
    }
  }
  return { build, binDir, link }
}

function printHelp(): void {
  console.log(`Usage: bun scripts/install-local-zi.ts [options]

Options:
  --build           Run bun run build before install
  --bin-dir <path>  Install location (default: ~/.local/bin)
  --link            Symlink instead of copy (POSIX only)
  -h, --help        Show help
`)
}

function expandHome(path: string): string {
  if (path === "~") return homedir()
  if (path.startsWith("~/")) return join(homedir(), path.slice(2))
  return path
}

function delimiter(): string {
  return process.platform === "win32" ? ";" : ":"
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

if (import.meta.main) {
  try {
    await main()
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    process.exitCode = 1
  }
}

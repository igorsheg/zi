import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"

export interface CompileZiOptions {
  readonly outfile: string
  readonly version: string
}

export async function compileZi(options: CompileZiOptions): Promise<void> {
  if (!options.version || options.version.length > 128 || /[\r\n]/.test(options.version)) {
    throw new Error("Zi build versions must contain 1 to 128 characters on one line")
  }

  const root = resolve(import.meta.dirname, "..")
  await compileStandalone(resolve(root, "packages/cli/src/standalone.ts"), options.outfile, {
    "process.env.ZI_BUILD_VERSION": JSON.stringify(options.version)
  })
  await verifyZi(options.outfile, options.version)
}

export async function compileStandalone(
  entrypoint: string,
  outfile: string,
  define: Readonly<Record<string, string>> = {}
): Promise<void> {
  const packageJson: unknown = JSON.parse(await readFile(resolve(import.meta.dirname, "../package.json"), "utf8"))
  const packageManager =
    typeof packageJson === "object" && packageJson !== null && "packageManager" in packageJson
      ? packageJson.packageManager
      : undefined
  assertPinnedBunVersion(Bun.version, packageManager)

  await mkdir(dirname(outfile), { recursive: true })
  await Bun.build({
    entrypoints: [entrypoint],
    target: "bun",
    format: "esm",
    minify: { syntax: true, whitespace: true, identifiers: false },
    packages: "bundle",
    conditions: ["bun", "node"],
    define: { ...define },
    compile: {
      outfile,
      autoloadDotenv: false,
      autoloadBunfig: false,
      autoloadTsconfig: false,
      autoloadPackageJson: false
    }
  })
}

export function assertPinnedBunVersion(actual: string, packageManager: unknown): void {
  const match = typeof packageManager === "string" ? /^bun@(\d+\.\d+\.\d+)$/.exec(packageManager) : null
  if (!match) throw new Error("Zi packageManager must pin Bun exactly")
  const expected = match[1]!
  if (actual !== expected) {
    throw new Error(
      `Zi builds require Bun ${expected}; running ${actual}. Update Bun before building the standalone executable.`
    )
  }
}

async function verifyZi(executable: string, version: string): Promise<void> {
  const child = Bun.spawn([executable, "-V"], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  const normalizedStdout = stdout.replaceAll("\r\n", "\n")
  if (exitCode !== 0 || normalizedStdout !== `zi ${version}\n` || stderr !== "") {
    throw new Error(
      `Compiled executable failed its version smoke test (exit ${exitCode}): stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
    )
  }
}

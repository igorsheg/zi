import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  buildNpmPackages,
  npmCliPackageName,
  npmExtensionApiPackageName,
  npmPlatform,
  npmPlatformPackageName,
  parseNpmPackageBuildOptions
} from "./build-npm-packages.js"
import { releaseArchiveName } from "./build-release.js"

test("npm package options use the owned @with-zi scope and bounded release inputs", () => {
  expect(npmCliPackageName).toBe("@with-zi/zi")
  expect(npmExtensionApiPackageName).toBe("@with-zi/extension-api")
  expect(npmPlatformPackageName("linux-x64")).toBe("@with-zi/zi-linux-x64")
  expect(npmPlatform("windows-x64")).toEqual({ os: "win32", cpu: "x64", executable: "zi.exe" })
  expect(
    parseNpmPackageBuildOptions(["--version", "v1.2.3-alpha.1", "--target", "linux-x64", "--pack"], {})
  ).toMatchObject({ version: "1.2.3-alpha.1", targets: ["linux-x64"], packMode: "pack" })
  expect(() => parseNpmPackageBuildOptions([], {})).toThrow("NPM package version is required")
})

test("npm package assembly wraps release archives without install-time downloads", async () => {
  const distDir = await mkdtemp(join(tmpdir(), "zi-npm-packages-"))
  const version = "1.2.3-alpha.1"
  const target = "linux-x64"
  const releaseDirectoryName = `zi-${version}-${target}`
  const releaseDirectory = join(distDir, releaseDirectoryName)
  try {
    await mkdir(releaseDirectory, { recursive: true })
    const executable = join(releaseDirectory, "zi")
    await writeFile(executable, "#!/bin/sh\necho zi 1.2.3-alpha.1\n")
    await chmod(executable, 0o755)
    await run([
      "tar",
      "-czf",
      join(distDir, releaseArchiveName({ version, target })),
      "-C",
      distDir,
      releaseDirectoryName
    ])

    const result = await buildNpmPackages({
      version,
      targets: [target],
      distDir,
      packMode: "none",
      verifyCurrent: false
    })

    const platform = result.packages.find(candidate => candidate.packageName === "@with-zi/zi-linux-x64")
    const extensionApi = result.packages.find(candidate => candidate.packageName === "@with-zi/extension-api")
    const cli = result.packages.find(candidate => candidate.packageName === "@with-zi/zi")
    expect(platform).toBeDefined()
    expect(extensionApi).toBeDefined()
    expect(cli).toBeDefined()
    expect(existsSync(join(platform!.directory, "bin", "zi"))).toBe(true)
    expect(JSON.parse(await readFile(join(platform!.directory, "package.json"), "utf8"))).toMatchObject({
      name: "@with-zi/zi-linux-x64",
      version,
      os: ["linux"],
      cpu: ["x64"]
    })
    expect(JSON.parse(await readFile(join(extensionApi!.directory, "package.json"), "utf8"))).toMatchObject({
      name: "@with-zi/extension-api",
      version,
      exports: { ".": { types: "./index.d.ts", import: "./index.js" } },
      dependencies: { typebox: "1.1.38" }
    })
    expect(existsSync(join(extensionApi!.directory, "index.js"))).toBe(true)
    expect(existsSync(join(extensionApi!.directory, "index.d.ts"))).toBe(true)
    expect(JSON.parse(await readFile(join(cli!.directory, "package.json"), "utf8"))).toMatchObject({
      name: "@with-zi/zi",
      version,
      bin: { zi: "./bin/zi.js" },
      optionalDependencies: { "@with-zi/zi-linux-x64": version }
    })
    const resolver = await readFile(join(cli!.directory, "bin", "zi.js"), "utf8")
    expect(resolver).not.toContain("curl")
    expect(resolver).toContain('arg === "--version" ? "-V" : arg')
  } finally {
    await rm(distDir, { recursive: true, force: true })
  }
})

async function run(command: readonly [string, ...string[]]): Promise<void> {
  const child = Bun.spawn([...command], { stdin: "ignore", stdout: "ignore", stderr: "pipe" })
  const [exitCode, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()])
  if (exitCode !== 0) throw new Error(stderr)
}

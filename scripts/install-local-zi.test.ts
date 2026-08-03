import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { lstat, mkdir, mkdtemp, readFile, readlink, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { installedProductDirectoryName } from "../packages/coding-agent/src/product-documentation.js"
import { copyDistributionDocumentation } from "./distribution-documentation.js"
import { installLocalDistribution } from "./install-local-zi.js"

const root = resolve(import.meta.dirname, "..")

test("copied local installs retain a dedicated model-readable product directory", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-local-install-copy-"))
  const sourceDirectory = join(temporary, "source")
  const source = join(sourceDirectory, process.platform === "win32" ? "zi.exe" : "zi")
  const destination = join(temporary, "bin", process.platform === "win32" ? "zi.exe" : "zi")
  try {
    await mkdir(sourceDirectory)
    await Bun.write(source, "local zi payload")
    await copyDistributionDocumentation(root, sourceDirectory)
    await Bun.write(join(sourceDirectory, "README.md"), "built documentation snapshot\n")
    const mode = await installLocalDistribution({ source, destination, link: false, platform: process.platform })

    const productDirectory = join(temporary, "bin", installedProductDirectoryName)
    expect(mode).toBe("copied")
    expect((await lstat(destination)).isFile()).toBe(true)
    expect(await readFile(destination, "utf8")).toBe("local zi payload")
    expect(await readFile(join(productDirectory, "README.md"), "utf8")).toBe("built documentation snapshot\n")
    expect(existsSync(join(productDirectory, "docs", "extensions.md"))).toBe(true)
    expect(existsSync(join(productDirectory, "docs", "skills.md"))).toBe(true)
    expect(existsSync(join(productDirectory, "docs", "subagents.md"))).toBe(true)
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

test("a failed copied install preserves the previous executable and documentation", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-local-install-failure-"))
  const sourceDirectory = join(temporary, "source")
  const source = join(sourceDirectory, process.platform === "win32" ? "zi.exe" : "zi")
  const destination = join(temporary, "bin", process.platform === "win32" ? "zi.exe" : "zi")
  const productDirectory = join(temporary, "bin", installedProductDirectoryName)
  try {
    await mkdir(sourceDirectory)
    await Bun.write(source, "version one executable")
    await copyDistributionDocumentation(root, sourceDirectory)
    await Bun.write(join(sourceDirectory, "README.md"), "version one documentation\n")
    await installLocalDistribution({ source, destination, link: false, platform: process.platform })

    await Bun.write(source, "version two executable")
    await Bun.write(join(sourceDirectory, "README.md"), "version two documentation\n")
    await rm(join(sourceDirectory, "docs", "skills.md"))

    const failed = installLocalDistribution({ source, destination, link: false, platform: process.platform })
    await Promise.allSettled([failed])
    expect(failed).rejects.toThrow()
    expect(await readFile(destination, "utf8")).toBe("version one executable")
    expect(await readFile(join(productDirectory, "README.md"), "utf8")).toBe("version one documentation\n")
    expect(existsSync(join(productDirectory, "docs", "skills.md"))).toBe(true)
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

test("linked local installs resolve the complete source distribution", async () => {
  if (process.platform === "win32") return

  const temporary = await mkdtemp(join(tmpdir(), "zi-local-install-link-"))
  const sourceDirectory = join(temporary, "source")
  const source = join(sourceDirectory, "zi")
  const destination = join(temporary, "bin", "zi")
  try {
    await mkdir(sourceDirectory)
    await Bun.write(source, "local zi payload")
    await copyDistributionDocumentation(root, sourceDirectory)
    const mode = await installLocalDistribution({ source, destination, link: true, platform: process.platform })

    expect(mode).toBe("linked")
    expect((await lstat(destination)).isSymbolicLink()).toBe(true)
    expect(await readlink(destination)).toBe(source)
    expect(existsSync(join(sourceDirectory, "docs", "skills.md"))).toBe(true)
    expect(existsSync(join(temporary, "bin", installedProductDirectoryName))).toBe(false)
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

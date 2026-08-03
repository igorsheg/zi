import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"

import {
  installedProductDirectoryName,
  productDocumentationContractPaths,
  productDocumentationPaths,
  productRoot
} from "../src/product-documentation.js"

test("source runs resolve product documentation from the repository root", () => {
  const sourceDirectory = resolve("/workspace/zi/packages/coding-agent/src")

  expect(
    productRoot("file:///workspace/zi/packages/coding-agent/src/product-documentation.ts", "/bin/bun", sourceDirectory)
  ).toBe(resolve("/workspace/zi"))
})

test("compiled runs resolve product documentation beside the executable", () => {
  const executable = resolve("/opt/zi/bin/zi")

  expect(productRoot("file:///$bunfs/root/zi", executable, "/ignored/source")).toBe(resolve("/opt/zi/bin"))
  expect(productRoot("file:///C:/~BUN/root/zi", executable, "/ignored/source")).toBe(resolve("/opt/zi/bin"))
  expect(productRoot("file:///C:/%7EBUN/root/zi", executable, "/ignored/source")).toBe(resolve("/opt/zi/bin"))
})

test("a copied local executable resolves its dedicated adjacent product directory", () => {
  const executable = resolve("/home/user/.local/bin/zi")
  const executableDirectory = resolve("/home/user/.local/bin")
  const installedDirectory = join(executableDirectory, installedProductDirectoryName)

  expect(
    productRoot("file:///$bunfs/root/zi", executable, "/ignored/source", root => root === installedDirectory)
  ).toBe(installedDirectory)
  expect(
    productRoot(
      "file:///$bunfs/root/zi",
      executable,
      "/ignored/source",
      root => root === executableDirectory || root === installedDirectory
    )
  ).toBe(executableDirectory)
})

test("generic neighboring directories do not shadow a complete copied product", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-product-root-"))
  const executableDirectory = join(temporary, "bin")
  const executable = join(executableDirectory, "zi")
  const installedDirectory = join(executableDirectory, installedProductDirectoryName)
  try {
    await mkdir(executableDirectory, { recursive: true })
    await Promise.all([
      Bun.write(join(executableDirectory, "README.md"), "unrelated"),
      mkdir(join(executableDirectory, "docs"), { recursive: true }),
      mkdir(join(executableDirectory, "examples"), { recursive: true })
    ])
    await Promise.all(
      productDocumentationContractPaths.map(async path => {
        const destination = join(installedDirectory, path)
        await mkdir(dirname(destination), { recursive: true })
        await Bun.write(destination, path)
      })
    )

    expect(productRoot("file:///$bunfs/root/zi", executable, "/ignored/source")).toBe(installedDirectory)
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
})

test("product documentation paths share one immutable distribution root", () => {
  const root = resolve("/opt/zi")
  const paths = productDocumentationPaths(root)

  expect(paths).toEqual({
    root,
    readme: join(root, "README.md"),
    docs: join(root, "docs"),
    examples: join(root, "examples")
  })
  expect(Object.isFrozen(paths)).toBe(true)
})

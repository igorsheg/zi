import { expect, test } from "bun:test"
import { chmod, mkdir, mkdtemp, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  discoverExtensionLoadPlan,
  maxExtensionDiscoveryDiagnostics,
  maxExtensionSources
} from "../src/extensions/discovery.js"
import { ZiPaths } from "../src/paths.js"
import { maxResourceDirectoryEntries } from "../src/resource-files.js"

test("extension discovery orders explicit, trusted project, and global sources deterministically", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-discovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const global = paths.globalResourceDir("extensions")
  const project = paths.projectResourceDir("extensions")
  await mkdir(join(global, "nested"), { recursive: true })
  await mkdir(project, { recursive: true })
  await writeFile(join(global, "z.ts"), "export default () => {}")
  await writeFile(join(global, "nested", "index.js"), "export default () => {}")
  await writeFile(join(global, "nested", "index.ts"), "export default () => {}")
  await writeFile(join(project, "b.ts"), "export default () => {}")
  await writeFile(join(project, "a.js"), "export default () => {}")

  const result = discoverExtensionLoadPlan(paths, "trusted", [join(global, "z.ts")])

  expect(result.plan.sources.map(source => [source.scope, source.declaredPath])).toEqual([
    ["temporary", join(global, "z.ts")],
    ["project", join(project, "a.js")],
    ["project", join(project, "b.ts")],
    ["global", join(global, "nested")]
  ])
  expect(result.diagnostics).toContainEqual(expect.objectContaining({ type: "duplicate", path: join(global, "z.ts") }))
  expect(result.plan.sources.at(-1)?.entryPath.endsWith("index.ts")).toBe(true)
  expect(new Set(result.plan.sources.map(source => source.id)).size).toBe(result.plan.sources.length)
  expect(Object.isFrozen(result.plan)).toBe(true)
  expect(Object.isFrozen(result.plan.sources)).toBe(true)
  expect(result.plan.sources.every(Object.isFrozen)).toBe(true)
})

test("extension directory resolution falls back when index.ts is not a file", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-index-fallback-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extension = join(paths.globalResourceDir("extensions"), "fallback")
  await mkdir(join(extension, "index.ts"), { recursive: true })
  await writeFile(join(extension, "index.js"), "export default () => {}")

  const result = discoverExtensionLoadPlan(paths, "untrusted")

  expect(result.plan.sources).toHaveLength(1)
  expect(result.plan.sources[0]?.entryPath.endsWith("index.js")).toBe(true)
})

test("excluded extension discovery never reads or diagnoses the project directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-untrusted-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectResourceDir("extensions"), "not a directory")
  await mkdir(paths.globalResourceDir("extensions"), { recursive: true })
  await writeFile(join(paths.globalResourceDir("extensions"), "global.ts"), "export default () => {}")

  for (const admission of ["untrusted", "absent"] as const) {
    const result = discoverExtensionLoadPlan(paths, admission)
    expect(result.plan.sources.map(source => source.scope)).toEqual(["global"])
    expect(result.diagnostics.some(diagnostic => diagnostic.path.startsWith(paths.projectDir))).toBe(false)
  }
})

test("coincident global and project extension roots retain global admission and identity", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-global-project-"))
  const paths = new ZiPaths(root, join(root, ".zi"))
  const extensions = paths.globalResourceDir("extensions")
  await mkdir(extensions, { recursive: true })
  await writeFile(join(extensions, "shared.ts"), "export default () => {}")

  const trusted = discoverExtensionLoadPlan(paths, "trusted")
  const untrusted = discoverExtensionLoadPlan(paths, "untrusted")

  expect(trusted.plan.sources).toEqual(untrusted.plan.sources)
  expect(trusted.plan.sources.map(source => source.scope)).toEqual(["global"])
  expect(trusted.diagnostics).toEqual([])
  expect(untrusted.diagnostics).toEqual([])
})

test("extension discovery follows file symlinks but not directory symlinks during one-level scanning", async () => {
  if (process.platform === "win32") return
  const root = await mkdtemp(join(tmpdir(), "zi-extension-symlink-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extensions = paths.globalResourceDir("extensions")
  const targets = join(root, "targets")
  await mkdir(extensions, { recursive: true })
  await mkdir(join(targets, "directory"), { recursive: true })
  await writeFile(join(targets, "file.ts"), "export default () => {}")
  await writeFile(join(targets, "directory", "index.ts"), "export default () => {}")
  await symlink(join(targets, "file.ts"), join(extensions, "linked.ts"))
  await symlink(join(targets, "directory"), join(extensions, "linked-directory"))

  const result = discoverExtensionLoadPlan(paths, "untrusted")

  expect(result.plan.sources.map(source => source.declaredPath)).toEqual([join(extensions, "linked.ts")])
  expect(result.diagnostics).toContainEqual(
    expect.objectContaining({ type: "unsupported", path: join(extensions, "linked-directory") })
  )
})

test("extension discovery rejects files that cannot be opened for reading", async () => {
  if (process.platform === "win32" || (typeof process.getuid === "function" && process.getuid() === 0)) return
  const root = await mkdtemp(join(tmpdir(), "zi-extension-unreadable-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extensions = paths.globalResourceDir("extensions")
  const source = join(extensions, "unreadable.ts")
  await mkdir(extensions, { recursive: true })
  await writeFile(source, "export default () => {}")
  await chmod(source, 0)

  try {
    const result = discoverExtensionLoadPlan(paths, "untrusted")
    expect(result.plan.sources).toEqual([])
    expect(result.diagnostics).toContainEqual(expect.objectContaining({ type: "unreadable", path: source }))
  } finally {
    await chmod(source, 0o600)
  }
})

test("an unreadable index.ts stat is diagnosed before falling back to index.js", async () => {
  if (process.platform === "win32" || (typeof process.getuid === "function" && process.getuid() === 0)) return
  const root = await mkdtemp(join(tmpdir(), "zi-extension-index-unreadable-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extension = join(paths.globalResourceDir("extensions"), "fallback")
  const blocked = join(root, "blocked")
  const indexTs = join(extension, "index.ts")
  await mkdir(extension, { recursive: true })
  await mkdir(blocked)
  await writeFile(join(blocked, "extension.ts"), "export default () => {}")
  await symlink(join(blocked, "extension.ts"), indexTs)
  await writeFile(join(extension, "index.js"), "export default () => {}")
  await chmod(blocked, 0)

  try {
    const result = discoverExtensionLoadPlan(paths, "untrusted")
    expect(result.plan.sources).toHaveLength(1)
    expect(result.plan.sources[0]?.entryPath.endsWith("index.js")).toBe(true)
    expect(result.diagnostics).toContainEqual(expect.objectContaining({ type: "unreadable", path: indexTs }))
  } finally {
    await chmod(blocked, 0o700)
  }
})

test("extension discovery preserves inaccessible stat boundaries as unreadable", async () => {
  if (process.platform === "win32" || (typeof process.getuid === "function" && process.getuid() === 0)) return
  const root = await mkdtemp(join(tmpdir(), "zi-extension-inaccessible-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const explicitDirectory = join(root, "explicit")
  const explicitSource = join(explicitDirectory, "extension.ts")
  const globalExtensions = paths.globalResourceDir("extensions")
  await mkdir(explicitDirectory)
  await writeFile(explicitSource, "export default () => {}")
  await mkdir(globalExtensions, { recursive: true })
  await writeFile(join(globalExtensions, "global.ts"), "export default () => {}")
  await chmod(explicitDirectory, 0)
  await chmod(paths.globalDir, 0)

  try {
    const result = discoverExtensionLoadPlan(paths, "untrusted", [explicitSource])
    expect(result.plan.sources).toEqual([])
    expect(result.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ type: "unreadable", path: explicitSource }),
        expect.objectContaining({ type: "unreadable", path: globalExtensions })
      ])
    )
    expect(result.diagnostics.some(diagnostic => diagnostic.type === "missing")).toBe(false)
  } finally {
    await chmod(explicitDirectory, 0o700)
    await chmod(paths.globalDir, 0o700)
  }
})

test("explicit extension paths validate missing, relative, and unsupported sources", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-explicit-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const unsupported = join(root, "extension.txt")
  await writeFile(unsupported, "no")

  const result = discoverExtensionLoadPlan(paths, "untrusted", ["relative.ts", join(root, "missing.ts"), unsupported])

  expect(result.plan.sources).toEqual([])
  expect(result.diagnostics.map(diagnostic => diagnostic.type)).toEqual(["unsupported", "missing", "unsupported"])
})

test("extension source admission is bounded before loading", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-bound-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extensions = paths.globalResourceDir("extensions")
  await mkdir(extensions, { recursive: true })
  await Promise.all(
    Array.from({ length: maxExtensionSources + 8 }, (_, index) =>
      writeFile(join(extensions, `${String(index).padStart(3, "0")}.ts`), "export default () => {}")
    )
  )

  const result = discoverExtensionLoadPlan(paths, "untrusted")

  expect(result.plan.sources).toHaveLength(maxExtensionSources)
  expect(result.diagnostics).toContainEqual(expect.objectContaining({ type: "limit", path: extensions, omitted: 8 }))
})

test("truncated extension roots fail closed instead of admitting a filesystem-dependent subset", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-truncated-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extensions = paths.globalResourceDir("extensions")
  await mkdir(extensions, { recursive: true })
  await Promise.all(
    Array.from({ length: maxResourceDirectoryEntries + 1 }, (_, index) =>
      writeFile(join(extensions, `${String(index).padStart(5, "0")}.ts`), "")
    )
  )

  const result = discoverExtensionLoadPlan(paths, "untrusted")

  expect(result.plan.sources).toEqual([])
  expect(result.diagnostics).toContainEqual(
    expect.objectContaining({ type: "limit", path: extensions, message: expect.stringContaining("root omitted") })
  )
})

test("extension discovery bounds retained diagnostics", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-diagnostic-bound-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const extensions = paths.globalResourceDir("extensions")
  await mkdir(extensions, { recursive: true })
  await Promise.all(
    Array.from({ length: maxExtensionDiscoveryDiagnostics + 12 }, (_, index) =>
      mkdir(join(extensions, `unsupported-${index}`))
    )
  )

  const result = discoverExtensionLoadPlan(paths, "untrusted")

  expect(result.diagnostics).toHaveLength(maxExtensionDiscoveryDiagnostics)
  expect(result.omittedDiagnostics).toBe(12)
})

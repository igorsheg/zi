import { expect, test } from "bun:test"
import { execFileSync } from "node:child_process"
import { chmod, mkdir, mkdtemp, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import {
  maxProjectFileSearchIgnoreBytes,
  maxProjectFileSearchResults,
  ProjectFileSearch,
  ProjectFileSearchQueryError
} from "../src/project-file-search.js"

test("project file search roots Git enumeration at OpenZiPaths.cwd and respects standard ignores", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-file-search-git-"))
  const cwd = join(root, "project", "nested")
  await mkdir(join(cwd, "src"), { recursive: true })
  await writeFile(join(cwd, "src", "tracked.ts"), "tracked")
  await writeFile(join(cwd, "src", "untracked.ts"), "untracked")
  await writeFile(join(cwd, "ignored.log"), "ignored")
  await writeFile(join(cwd, ".gitignore"), "*.log\n")
  await writeFile(join(root, "outside.ts"), "outside")
  execFileSync("git", ["init", "-q"], { cwd: join(root, "project") })
  execFileSync("git", ["add", "nested/src/tracked.ts", "nested/.gitignore"], { cwd: join(root, "project") })

  const search = new ProjectFileSearch(new OpenZiPaths(cwd, join(root, "global")))
  const result = await search.search("", new AbortController().signal)

  expect(result.matches).toContainEqual({ path: "src", type: "directory" })
  expect(result.matches).toContainEqual({ path: "src/tracked.ts", type: "file" })
  expect(result.matches).toContainEqual({ path: "src/untracked.ts", type: "file" })
  expect(result.matches.some(match => match.path.includes("outside") || match.path.includes("ignored"))).toBe(false)
  expect(result.matches.length).toBeLessThanOrEqual(maxProjectFileSearchResults)
  expect(Object.isFrozen(result.matches)).toBe(true)
  await search.dispose()
})

test("non-Git fallback is ignore-aware, includes hidden entries, and never traverses directory symlinks", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-file-search-walk-"))
  const cwd = join(root, "project")
  await mkdir(join(cwd, "src", "nested"), { recursive: true })
  await mkdir(join(cwd, "ignored"), { recursive: true })
  await mkdir(join(cwd, "a", "deep"), { recursive: true })
  await mkdir(join(root, "outside"), { recursive: true })
  await writeFile(join(cwd, "src", "nested", "component.ts"), "component")
  await writeFile(join(cwd, ".hidden.ts"), "hidden")
  await writeFile(join(cwd, "ignored", "secret.ts"), "secret")
  await writeFile(join(cwd, ".gitignore"), "ignored/\n*.tmp\n")
  await writeFile(join(cwd, "a", ".gitignore"), "*.log\n\\!literal\n!keep.log\n!keep.tmp\n")
  await writeFile(join(cwd, "a", "deep", "secret.log"), "secret")
  await writeFile(join(cwd, "a", "!literal"), "literal")
  await writeFile(join(cwd, "a", "keep.log"), "keep")
  await writeFile(join(cwd, "a", "keep.tmp"), "keep")
  if (process.platform !== "win32") await writeFile(join(cwd, "literal\\name.ts"), "literal backslash")
  await writeFile(join(root, "outside", "escaped.ts"), "escaped")
  if (process.platform !== "win32") await symlink(join(root, "outside"), join(cwd, "linked"))

  const search = new ProjectFileSearch(new OpenZiPaths(cwd, join(root, "global")))
  const nested = await search.search("src/com", new AbortController().signal)
  expect(nested.matches[0]).toEqual({ path: "src/nested/component.ts", type: "file" })

  const hidden = await search.search("hidden", new AbortController().signal)
  expect(hidden.matches).toContainEqual({ path: ".hidden.ts", type: "file" })

  const all = await search.search("", new AbortController().signal)
  expect(
    all.matches.some(
      match =>
        match.path.includes("secret.ts") ||
        match.path.includes("escaped.ts") ||
        match.path.includes("secret.log") ||
        match.path.endsWith("!literal")
    )
  ).toBe(false)
  const unignored = await search.search("keep", new AbortController().signal)
  expect(unignored.matches).toContainEqual({ path: "a/keep.log", type: "file" })
  expect(unignored.matches).toContainEqual({ path: "a/keep.tmp", type: "file" })
  if (process.platform !== "win32") {
    const literalBackslash = await search.search("literal", new AbortController().signal)
    expect(literalBackslash.matches).toEqual([])
  }
  await search.dispose()
})

test("fallback stops a subtree when its ignore policy exceeds the byte budget", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-file-search-ignore-bound-"))
  const cwd = join(root, "project")
  await mkdir(cwd, { recursive: true })
  await writeFile(join(cwd, "secret.ts"), "secret")
  await writeFile(join(cwd, ".gitignore"), `secret.ts\n#${"x".repeat(maxProjectFileSearchIgnoreBytes)}`)

  const search = new ProjectFileSearch(new OpenZiPaths(cwd, join(root, "global")))
  const result = await search.search("", new AbortController().signal)

  expect(result).toEqual({ matches: [], truncated: true })
  await search.dispose()
})

test("fallback skips a subtree whose ignore file is unreadable", async () => {
  if (process.platform === "win32") return
  const root = await mkdtemp(join(tmpdir(), "openzi-file-search-ignore-unreadable-"))
  const cwd = join(root, "project")
  await mkdir(cwd, { recursive: true })
  await writeFile(join(cwd, "secret.ts"), "secret")
  const ignoreFile = join(cwd, ".gitignore")
  await writeFile(ignoreFile, "secret.ts\n")
  await chmod(ignoreFile, 0)

  const search = new ProjectFileSearch(new OpenZiPaths(cwd, join(root, "global")))
  try {
    expect(await search.search("", new AbortController().signal)).toEqual({ matches: [], truncated: true })
  } finally {
    await chmod(ignoreFile, 0o600)
    await search.dispose()
  }
})

test("ranking prefers exact path, basename, prefix, and ordered nested segments", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-file-search-rank-"))
  const cwd = join(root, "project")
  await mkdir(join(cwd, "packages", "tui", "src"), { recursive: true })
  await mkdir(join(cwd, "other"), { recursive: true })
  await mkdir(join(cwd, "packages", "tui-source"), { recursive: true })
  await writeFile(join(cwd, "packages", "tui", "src", "autocomplete.ts"), "")
  await writeFile(join(cwd, "packages", "tui-source", "autocomplete.ts"), "")
  await writeFile(join(cwd, "other", "autocomplete.ts"), "")
  await writeFile(join(cwd, "autocomplete-helper.ts"), "")

  const search = new ProjectFileSearch(new OpenZiPaths(cwd, join(root, "global")))
  const exact = await search.search("other/autocomplete.ts", new AbortController().signal)
  expect(exact.matches[0]).toEqual({ path: "other/autocomplete.ts", type: "file" })

  const nested = await search.search("tui/src/auto", new AbortController().signal)
  expect(nested.matches[0]).toEqual({ path: "packages/tui/src/autocomplete.ts", type: "file" })
  expect(nested.matches.some(match => match.path.includes("tui-source"))).toBe(false)
  await search.dispose()
})

test("invalid queries fail before I/O and one search operation is single-flight and cancellable", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-file-search-state-"))
  const cwd = join(root, "project")
  await mkdir(cwd, { recursive: true })
  const search = new ProjectFileSearch(new OpenZiPaths(cwd, join(root, "global")))

  expect(() => search.search("../outside", new AbortController().signal)).toThrow(ProjectFileSearchQueryError)
  expect(() => search.search("/absolute", new AbortController().signal)).toThrow(ProjectFileSearchQueryError)

  const controller = new AbortController()
  const active = search.search("", controller.signal)
  expect(search.search("next", new AbortController().signal)).rejects.toThrow("active operation")
  controller.abort()
  expect(active).rejects.toHaveProperty("name", "AbortError")
  await search.waitForIdle()
  await search.dispose()
  expect(search.search("", new AbortController().signal)).rejects.toThrow("disposed")
})

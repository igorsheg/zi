import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, realpath, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { ZiPaths } from "../src/paths.js"
import {
  hasTrustRequiringProjectConfiguration,
  maxProjectTrustDecisions,
  maxProjectTrustFileBytes,
  projectConfigurationAdmission,
  ProjectTrustStore,
  resolveProjectTrust
} from "../src/project-trust.js"

test("project trust inherits the nearest canonical stored decision", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-"))
  const parent = join(root, "work")
  const cwd = join(parent, "project")
  const paths = new ZiPaths(cwd, join(root, "global"))
  await mkdir(cwd, { recursive: true })
  const store = new ProjectTrustStore(paths)
  const canonicalCwd = await realpath(cwd)
  const canonicalParent = await realpath(parent)

  expect(await store.lookup(cwd)).toEqual({ type: "unresolved", cwd: canonicalCwd })

  await store.update([{ type: "trusted", cwd: parent }])
  expect(await store.lookup(cwd)).toEqual({ type: "trusted", cwd: canonicalCwd, savedCwd: canonicalParent })

  await store.update([{ type: "untrusted", cwd }])
  expect(await store.lookup(cwd)).toEqual({ type: "untrusted", cwd: canonicalCwd, savedCwd: canonicalCwd })

  await store.update([{ type: "removed", cwd }])
  expect(await store.lookup(cwd)).toEqual({ type: "trusted", cwd: canonicalCwd, savedCwd: canonicalParent })
})

test("project trust canonicalizes symlink aliases before lookup and persistence", async () => {
  if (process.platform === "win32") return
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-link-"))
  const real = join(root, "real")
  const alias = join(root, "alias")
  const global = join(root, "global")
  await mkdir(real, { recursive: true })
  await symlink(real, alias)
  const store = new ProjectTrustStore(new ZiPaths(alias, global))

  await store.update([{ type: "trusted", cwd: alias }])
  const canonical = await realpath(real)

  expect(await store.lookup(real)).toEqual({ type: "trusted", cwd: canonical, savedCwd: canonical })
  expect(JSON.parse(await readFile(join(global, "trust.json"), "utf8"))).toEqual({ [canonical]: true })
})

test("project trust serializes concurrent updates without losing decisions", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-concurrent-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const first = new ProjectTrustStore(paths)
  const second = new ProjectTrustStore(paths)

  await Promise.all([
    first.update([{ type: "trusted", cwd: join(root, "one") }]),
    second.update([{ type: "untrusted", cwd: join(root, "two") }])
  ])

  expect(JSON.parse(await readFile(paths.trustFile, "utf8"))).toEqual({
    [resolve(root, "one")]: true,
    [resolve(root, "two")]: false
  })
})

test("project trust rejects malformed and unbounded persisted input without overwriting it", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-invalid-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  const store = new ProjectTrustStore(paths)

  await writeFile(paths.trustFile, JSON.stringify({ relative: true }))
  expect(store.lookup(paths.cwd)).rejects.toThrow("absolute normalized paths")
  expect(store.update([{ type: "trusted", cwd: paths.cwd }])).rejects.toThrow("absolute normalized paths")
  expect(await readFile(paths.trustFile, "utf8")).toBe('{"relative":true}')

  await writeFile(paths.trustFile, " ".repeat(maxProjectTrustFileBytes + 1))
  expect(store.lookup(paths.cwd)).rejects.toThrow(`${maxProjectTrustFileBytes} bytes`)

  const decisions = Object.fromEntries(
    Array.from({ length: maxProjectTrustDecisions + 1 }, (_, index) => [join(root, String(index)), true])
  )
  await writeFile(paths.trustFile, JSON.stringify(decisions))
  expect(store.lookup(paths.cwd)).rejects.toThrow(`${maxProjectTrustDecisions} decisions`)
})

test("project trust resolution is cwd-keyed and fails closed with diagnostics", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-resolution-"))
  const cwd = join(root, "project")
  const paths = new ZiPaths(cwd, join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, "{}")
  const canonicalCwd = await realpath(cwd)

  const unresolved = await resolveProjectTrust(paths)
  expect(unresolved).toEqual({
    type: "unresolved",
    cwd: canonicalCwd,
    diagnostic: {
      cwd: canonicalCwd,
      path: paths.projectDir,
      message: `Project configuration trust is unresolved and was ignored: ${paths.projectDir}`
    }
  })
  expect(projectConfigurationAdmission(unresolved)).toBe("untrusted")

  expect(resolveProjectTrust(paths, { type: "trusted", cwd: join(root, "other"), source: "runtime" })).rejects.toThrow(
    "does not match runtime cwd"
  )
  expect(await resolveProjectTrust(paths, { type: "trusted", cwd, source: "interactive" })).toEqual({
    type: "trusted",
    cwd: canonicalCwd,
    source: "interactive"
  })

  const store = new ProjectTrustStore(paths)
  await store.update([{ type: "trusted", cwd: root }])
  expect(await resolveProjectTrust(paths)).toEqual({
    type: "trusted",
    cwd: canonicalCwd,
    source: "stored",
    savedCwd: await realpath(root)
  })

  await writeFile(paths.trustFile, "not json")
  const failed = await resolveProjectTrust(paths)
  expect(failed).toMatchObject({
    type: "unresolved",
    cwd: canonicalCwd,
    diagnostic: { path: paths.trustFile, message: expect.stringContaining("could not be read") }
  })
  expect(projectConfigurationAdmission(failed)).toBe("untrusted")
})

test("coincident global and project configuration is already user-admitted", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-global-project-"))
  const paths = new ZiPaths(root, join(root, ".zi"))
  await mkdir(paths.projectResourceDir("extensions"), { recursive: true })
  await writeFile(join(paths.projectResourceDir("extensions"), "trusted.ts"), "export default () => {}")

  expect(paths.projectConfigIsGlobal).toBe(true)
  expect(hasTrustRequiringProjectConfiguration(paths)).toBe(false)
  const trust = await resolveProjectTrust(paths)
  expect(trust).toEqual({ type: "not_required", cwd: await realpath(root), reason: "project_configuration_is_global" })
  expect(projectConfigurationAdmission(trust)).toBe("trusted")
})

test("a project without protected configuration remains absent until an explicit write", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-absent-"))
  const cwd = join(root, "project")
  const paths = new ZiPaths(cwd, join(root, "global"))
  await mkdir(cwd, { recursive: true })

  const trust = await resolveProjectTrust(paths)
  expect(trust).toEqual({ type: "not_required", cwd: await realpath(cwd), reason: "no_project_configuration" })
  expect(projectConfigurationAdmission(trust)).toBe("absent")
})

test("project trust detects only exact project configuration that requires admission", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-project-trust-config-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })

  expect(hasTrustRequiringProjectConfiguration(paths)).toBe(false)
  await writeFile(join(paths.cwd, "AGENTS.md"), "context remains independently admitted")
  expect(hasTrustRequiringProjectConfiguration(paths)).toBe(false)

  const candidates = [
    { name: "settings.json", type: "file" },
    { name: "SYSTEM.md", type: "file" },
    { name: "APPEND_SYSTEM.md", type: "file" },
    { name: "extensions", type: "directory" },
    { name: "skills", type: "directory" },
    { name: "prompts", type: "directory" },
    { name: "themes", type: "directory" }
  ] as const
  await Promise.all(
    candidates.map(async (candidate, index) => {
      const isolated = new ZiPaths(join(root, `project-${index}`), paths.globalDir)
      await mkdir(isolated.projectDir, { recursive: true })
      const path = join(isolated.projectDir, candidate.name)
      if (candidate.type === "file") await writeFile(path, "{}")
      else await mkdir(path)
      expect(hasTrustRequiringProjectConfiguration(isolated)).toBe(true)
    })
  )
})

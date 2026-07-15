import { expect, test } from "bun:test"
import { join } from "node:path"

import { getDefaultAgentDir, OpenZiPaths, resolveOpenZiPath } from "../src/paths.js"

test("the default global directory is $HOME/.openzi", () => {
  expect(getDefaultAgentDir("/home/alice")).toBe("/home/alice/.openzi")
})

test("path inputs expand home and resolve relative to their admitting owner", () => {
  expect(resolveOpenZiPath("~/project", "/work", "/home/alice")).toBe("/home/alice/project")
  expect(resolveOpenZiPath("sessions", "/work/project", "/home/alice")).toBe("/work/project/sessions")
})

test("one cwd-bound policy resolves global, project, auth, resource, and session paths", () => {
  const home = "/home/alice/.openzi"
  const cwd = "/work/project"
  const paths = new OpenZiPaths(cwd, home)

  expect(paths.cwd).toBe(cwd)
  expect(paths.globalDir).toBe(home)
  expect(paths.projectDir).toBe(join(cwd, ".openzi"))
  expect(paths.globalSettingsFile).toBe(join(home, "settings.json"))
  expect(paths.projectSettingsFile).toBe(join(cwd, ".openzi", "settings.json"))
  expect(paths.authFile).toBe(join(home, "auth.json"))
  expect(paths.globalSystemPromptFile).toBe(join(home, "SYSTEM.md"))
  expect(paths.projectSystemPromptFile).toBe(join(cwd, ".openzi", "SYSTEM.md"))
  expect(paths.globalResourceDir("skills")).toBe(join(home, "skills"))
  expect(paths.projectResourceDir("skills")).toBe(join(cwd, ".openzi", "skills"))
  expect(paths.sessionDir).toBe(join(home, "sessions", "--work-project--"))
  expect(new OpenZiPaths(cwd, home, "local-sessions").sessionDir).toBe(join(cwd, "local-sessions"))
})

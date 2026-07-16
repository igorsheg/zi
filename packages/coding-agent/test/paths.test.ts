import { expect, test } from "bun:test"
import { join } from "node:path"

import { getDefaultAgentDir, OpenZiPaths, resolveOpenZiPath } from "../src/paths.js"

test("the default global directory is $HOME/.openzi/agent", () => {
  expect(getDefaultAgentDir("/home/alice")).toBe("/home/alice/.openzi/agent")
})

test("path inputs expand home and resolve relative to their admitting owner", () => {
  expect(resolveOpenZiPath("~/project", "/work", "/home/alice")).toBe("/home/alice/project")
  expect(resolveOpenZiPath("sessions", "/work/project", "/home/alice")).toBe("/work/project/sessions")
})

test("one cwd-bound policy resolves global, project, auth, resource, and session paths", () => {
  const agentDir = "/home/alice/.openzi/agent"
  const cwd = "/work/project"
  const paths = new OpenZiPaths(cwd, agentDir)

  expect(paths.cwd).toBe(cwd)
  expect(paths.globalDir).toBe(agentDir)
  expect(paths.projectDir).toBe(join(cwd, ".openzi"))
  expect(paths.globalSettingsFile).toBe(join(agentDir, "settings.json"))
  expect(paths.projectSettingsFile).toBe(join(cwd, ".openzi", "settings.json"))
  expect(paths.authFile).toBe(join(agentDir, "auth.json"))
  expect(paths.globalSystemPromptFile).toBe(join(agentDir, "SYSTEM.md"))
  expect(paths.projectSystemPromptFile).toBe(join(cwd, ".openzi", "SYSTEM.md"))
  expect(paths.globalResourceDir("skills")).toBe(join(agentDir, "skills"))
  expect(paths.projectResourceDir("skills")).toBe(join(cwd, ".openzi", "skills"))
  expect(paths.sessionDir).toBe(join(agentDir, "sessions", "--work-project--"))
  expect(new OpenZiPaths(cwd, agentDir, "local-sessions").sessionDir).toBe(join(cwd, "local-sessions"))
})

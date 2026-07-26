import { expect, test } from "bun:test"
import { join } from "node:path"

import { getDefaultAgentDir, ZiPaths, resolveZiPath } from "../src/paths.js"

test("the default global directory is $HOME/.zi/agent", () => {
  expect(getDefaultAgentDir("/home/alice")).toBe("/home/alice/.zi/agent")
})

test("path inputs expand home and resolve relative to their admitting owner", () => {
  expect(resolveZiPath("~/project", "/work", "/home/alice")).toBe("/home/alice/project")
  expect(resolveZiPath("sessions", "/work/project", "/home/alice")).toBe("/work/project/sessions")
})

test("one cwd-bound policy resolves global, project, auth, resource, and session paths", () => {
  const agentDir = "/home/alice/.zi/agent"
  const cwd = "/work/project"
  const paths = new ZiPaths(cwd, agentDir)

  expect(paths.cwd).toBe(cwd)
  expect(paths.globalDir).toBe(agentDir)
  expect(paths.projectDir).toBe(join(cwd, ".zi"))
  expect(paths.projectConfigIsGlobal).toBe(false)
  expect(paths.globalSettingsFile).toBe(join(agentDir, "settings.json"))
  expect(paths.projectSettingsFile).toBe(join(cwd, ".zi", "settings.json"))
  expect(paths.authFile).toBe(join(agentDir, "auth.json"))
  expect(paths.trustFile).toBe(join(agentDir, "trust.json"))
  expect(paths.globalSystemPromptFile).toBe(join(agentDir, "SYSTEM.md"))
  expect(paths.projectSystemPromptFile).toBe(join(cwd, ".zi", "SYSTEM.md"))
  expect(paths.globalResourceDir("skills")).toBe(join(agentDir, "skills"))
  expect(paths.projectResourceDir("skills")).toBe(join(cwd, ".zi", "skills"))
  expect(paths.sessionDir).toBe(join(agentDir, "sessions", "--work-project--"))
  expect(new ZiPaths(cwd, agentDir, "local-sessions").sessionDir).toBe(join(cwd, "local-sessions"))
  expect(new ZiPaths("/work", "/work/.zi").projectConfigIsGlobal).toBe(true)
})

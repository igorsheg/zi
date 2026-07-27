import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createModels, fauxAssistantMessage } from "@earendil-works/pi-ai"

import { createAgentSessionRuntime } from "../src/agent-session-runtime.js"
import { ZiPaths } from "../src/paths.js"

test("interactive project trust replaces the runtime and persists only explicit saved decisions", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-project-trust-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const paths = new ZiPaths(cwd, agentDir)
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, JSON.stringify({ steeringMode: "all" }))
  const options = {
    cwd,
    agentDir,
    session: { type: "new" as const, persist: false },
    modelFactory: () => createModels()
  }

  const sessionOnly = await createAgentSessionRuntime(options)
  const excluded = sessionOnly.session
  expect(sessionOnly.projectTrust.type).toBe("unresolved")
  expect(excluded.steeringMode).toBe("one-at-a-time")

  await sessionOnly.decideProjectTrust({ type: "trusted", persistence: "session" })
  expect(sessionOnly.projectTrust).toMatchObject({ type: "trusted", source: "interactive" })
  expect(sessionOnly.session.steeringMode).toBe("all")
  expect(existsSync(paths.trustFile)).toBe(false)
  expect(() => excluded.prompt("disposed")).toThrow("AgentSession is disposed")
  sessionOnly.dispose()
  await sessionOnly.waitForIdle()

  const remembered = await createAgentSessionRuntime(options)
  expect(remembered.projectTrust.type).toBe("unresolved")
  await remembered.decideProjectTrust({ type: "trusted", persistence: "saved" })
  expect(JSON.parse(await readFile(paths.trustFile, "utf8"))).toEqual({ [remembered.projectTrust.cwd]: true })
  expect(() => remembered.decideProjectTrust({ type: "untrusted", persistence: "session" })).toThrow("already resolved")
  remembered.dispose()
  await remembered.waitForIdle()

  const restored = await createAgentSessionRuntime(options)
  expect(restored.projectTrust).toMatchObject({ type: "trusted", source: "stored" })
  expect(restored.session.steeringMode).toBe("all")
  restored.dispose()
  await restored.waitForIdle()
})

test("project trust replacement preserves a resumed session journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-project-trust-resume-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "global")
  const paths = new ZiPaths(cwd, agentDir)
  await mkdir(paths.projectDir, { recursive: true })
  await writeFile(paths.projectSettingsFile, "{}")
  const base = { cwd, agentDir, modelFactory: () => createModels() }

  const created = await createAgentSessionRuntime({
    ...base,
    projectTrust: { type: "trusted", cwd, source: "runtime" },
    session: { type: "new", persist: true }
  })
  created.session.sessionManager.appendMessage({ role: "user", content: "preserved", timestamp: 1 })
  created.session.sessionManager.appendMessage(fauxAssistantMessage("answer"))
  const file = created.session.sessionManager.file!
  expect(existsSync(file)).toBe(true)
  created.dispose()
  await created.waitForIdle()

  const resumed = await createAgentSessionRuntime({ ...base, session: { type: "resume", file } })
  expect(resumed.projectTrust.type).toBe("unresolved")
  expect(resumed.session.messages).toHaveLength(2)
  await resumed.decideProjectTrust({ type: "trusted", persistence: "session" })

  expect(resumed.session.sessionManager.file).toBe(file)
  expect(resumed.session.messages).toMatchObject([{ role: "user", content: "preserved" }, { role: "assistant" }])
  resumed.dispose()
  await resumed.waitForIdle()
})

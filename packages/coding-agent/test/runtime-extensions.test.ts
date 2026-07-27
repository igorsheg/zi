import { expect, test } from "bun:test"
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createAgentSessionRuntime } from "../src/agent-session-runtime.js"
import { createAgentRuntime } from "../src/runtime.js"

const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
const workerCommand = Object.freeze([process.execPath, cli])

test("AgentSession owns one discovered extension lifecycle through final disposal", async () => {
  const fixture = await extensionFixture("direct")
  const runtime = await createAgentRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: false }
  })

  try {
    expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\n")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({
      status: "ready",
      lifecycle: "started",
      extensions: [{ status: "loaded" }],
      stdout: { text: "runtime extension stdout\n" },
      stderr: { text: "runtime extension stderr\n" }
    })
  } finally {
    runtime.session.dispose()
    await runtime.session.waitForIdle()
  }

  expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:quit\n")
  await rm(fixture.root, { recursive: true, force: true })
}, 10_000)

test("runtime project trust excludes extension code before worker startup", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-runtime-extension-trust-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensionDir = join(cwd, ".zi", "extensions")
  const loaded = join(root, "loaded.log")
  await mkdir(extensionDir, { recursive: true })
  await writeFile(
    join(extensionDir, "project.ts"),
    `import { writeFileSync } from "node:fs"
export default function (): void { writeFileSync(${JSON.stringify(loaded)}, "loaded") }
`
  )

  const runtime = await createAgentSessionRuntime({
    cwd,
    agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })
  const excluded = runtime.session
  expect(runtime.projectTrust.type).toBe("unresolved")
  expect(excluded.extensionHostSnapshot).toMatchObject({ status: "disabled", extensions: [] })
  expect(access(loaded)).rejects.toThrow()

  try {
    await runtime.decideProjectTrust({ type: "trusted", persistence: "session" })
    expect(await readFile(loaded, "utf8")).toBe("loaded")
    expect(runtime.session.extensionHostSnapshot).toMatchObject({ status: "ready", lifecycle: "started" })
    expect(() => excluded.prompt("disposed")).toThrow("AgentSession is disposed")
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("whole-runtime replacement starts the candidate only after retiring the current lifecycle", async () => {
  const fixture = await extensionFixture("replacement")
  const runtime = await createAgentSessionRuntime({
    cwd: fixture.cwd,
    agentDir: fixture.agentDir,
    session: { type: "new", persist: false },
    extensionWorkerCommand: workerCommand
  })

  try {
    await runtime.newSession()
    expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:new\nstart:new\n")
  } finally {
    runtime.dispose()
    await runtime.waitForIdle()
  }

  expect(await readFile(fixture.lifecycle, "utf8")).toBe("start:startup\nstop:new\nstart:new\nstop:quit\n")
  await rm(fixture.root, { recursive: true, force: true })
}, 10_000)

async function extensionFixture(
  name: string
): Promise<{ readonly root: string; readonly cwd: string; readonly agentDir: string; readonly lifecycle: string }> {
  const root = await mkdtemp(join(tmpdir(), `zi-runtime-extension-${name}-`))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extensions = join(agentDir, "extensions")
  const lifecycle = join(root, "lifecycle.log")
  await mkdir(cwd, { recursive: true })
  await mkdir(extensions, { recursive: true })
  await writeFile(
    join(extensions, "lifecycle.ts"),
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  console.log("runtime extension stdout")
  console.error("runtime extension stderr")
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecycle)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecycle)}, "stop:" + event.reason + "\\n"))
}
`
  )
  return { root, cwd, agentDir, lifecycle }
}

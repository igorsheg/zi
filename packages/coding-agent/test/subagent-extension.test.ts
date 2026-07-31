import { expect, test } from "bun:test"
import { cp, mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { createAgentRuntime } from "../src/runtime.js"
import { createModels, fauxProvider } from "../src/testing.js"

const workerCommand = Object.freeze([process.execPath, resolve(import.meta.dir, "../../../packages/cli/src/main.ts")])
const exampleExtension = resolve(import.meta.dir, "../../../examples/extensions/subagent")

test("declarative subagent example registers the reviewer type", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-subagent-extension-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  await mkdir(cwd, { recursive: true })
  await cp(exampleExtension, join(agentDir, "extensions", "subagent"), { recursive: true })

  const models = createModels()
  models.setProvider(fauxProvider().provider)

  try {
    const runtime = await createAgentRuntime({
      cwd,
      agentDir,
      model: "faux/faux-1",
      modelFactory: () => models,
      session: { type: "new", persist: false },
      extensionWorkerCommand: workerCommand
    })
    try {
      expect(runtime.session.extensionHostSnapshot).toMatchObject({
        status: "ready",
        tools: [],
        subagentTypes: [
          {
            name: "reviewer",
            description: "Review a change for correctness and missing tests",
            instructions:
              "Inspect the requested change. Do not edit files. Return findings with paths and line numbers."
          }
        ]
      })
    } finally {
      runtime.session.dispose()
      await runtime.session.waitForIdle()
    }
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 20_000)

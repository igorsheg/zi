import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all"

import { FileCredentialStore } from "../src/credential-store.js"
import { OpenZiPaths } from "../src/paths.js"
import { createAgentRuntime } from "../src/runtime.js"

test("credentials persist only in the global path and preserve other providers", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-auth-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.authFile,
    JSON.stringify({
      first: { type: "api_key", key: "one" },
      second: { type: "api_key", key: "old", env: { ACCOUNT: "account" } }
    })
  )
  const credentials = new FileCredentialStore(paths)

  expect(await credentials.read("second")).toEqual({ type: "api_key", key: "old", env: { ACCOUNT: "account" } })
  await credentials.modify("second", async current => ({ ...current, type: "api_key", key: "new" }))
  await credentials.delete("first")

  expect(JSON.parse(await readFile(paths.authFile, "utf8"))).toEqual({
    second: { type: "api_key", key: "new", env: { ACCOUNT: "account" } }
  })
})

test("the default model registry resolves credentials from the runtime path policy", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-auth-runtime-"))
  const globalDir = join(root, "global")
  const model = getBuiltinModels("anthropic")[0]
  if (!model) throw new Error("Anthropic catalog is empty")
  await mkdir(globalDir, { recursive: true })
  await writeFile(join(globalDir, "auth.json"), JSON.stringify({ anthropic: { type: "api_key", key: "stored-key" } }))

  const { session, services } = await createAgentRuntime({
    cwd: join(root, "project"),
    agentDir: globalDir,
    model: `${model.provider}/${model.id}`,
    persist: false
  })

  try {
    expect((await services.modelRegistry.models.getAuth(session.model))?.auth.apiKey).toBe("stored-key")
  } finally {
    session.dispose()
  }
})

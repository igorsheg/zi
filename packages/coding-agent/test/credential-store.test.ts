import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all"

import { FileCredentialStore, maxAuthFileBytes, maxStoredCredentials } from "../src/credential-store.js"
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

  expect(await credentials.list()).toEqual([
    { providerId: "first", type: "api_key" },
    { providerId: "second", type: "api_key" }
  ])
  expect(await credentials.read("second")).toEqual({ type: "api_key", key: "old", env: { ACCOUNT: "account" } })
  await credentials.modify("second", async current => ({ ...current, type: "api_key", key: "new" }))
  await credentials.delete("first")

  expect(JSON.parse(await readFile(paths.authFile, "utf8"))).toEqual({
    second: { type: "api_key", key: "new", env: { ACCOUNT: "account" } }
  })
})

test("oversized auth storage is rejected without overwriting it", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-auth-bound-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  const oversized = " ".repeat(maxAuthFileBytes + 1)
  await writeFile(paths.authFile, oversized)
  const credentials = new FileCredentialStore(paths)

  expect((await rejection(credentials.list())).message).toContain(`${maxAuthFileBytes} bytes`)
  expect(
    (await rejection(credentials.modify("provider", async () => ({ type: "api_key", key: "secret" })))).message
  ).toContain(`${maxAuthFileBytes} bytes`)
  expect(await readFile(paths.authFile, "utf8")).toBe(oversized)
})

test("an auth update cannot serialize beyond the file bound", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-auth-write-bound-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  const original = JSON.stringify({ first: { type: "api_key", key: "x".repeat(maxAuthFileBytes - 60) } })
  expect(Buffer.byteLength(original)).toBeLessThan(maxAuthFileBytes)
  await writeFile(paths.authFile, original)
  const credentials = new FileCredentialStore(paths)

  const error = await rejection(credentials.modify("second", async () => ({ type: "api_key", key: "secret" })))

  expect(error.message).toContain(`${maxAuthFileBytes} bytes`)
  expect(await readFile(paths.authFile, "utf8")).toBe(original)
})

test("auth storage bounds the number of provider credentials", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-auth-provider-bound-"))
  const paths = new OpenZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  const data = Object.fromEntries(
    Array.from({ length: maxStoredCredentials + 1 }, (_, index) => [`provider-${index}`, { type: "api_key", key: "x" }])
  )
  await writeFile(paths.authFile, JSON.stringify(data))

  const error = await rejection(new FileCredentialStore(paths).list())

  expect(error.message).toContain(`${maxStoredCredentials} providers`)
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

async function rejection(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise
  } catch (cause) {
    return cause instanceof Error ? cause : new Error(String(cause))
  }
  throw new Error("Expected promise to reject")
}

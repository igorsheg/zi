import { expect, test } from "bun:test"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import { createExtensionWorkerSpawner, ExtensionHost, type ExtensionHostTimeouts } from "../src/extensions/host.js"

test("ExtensionHost supervises the CLI worker over dedicated process pipes", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-process-"))
  const extensionPath = join(root, "extension.ts")
  const lifecyclePath = join(root, "lifecycle.log")
  await writeFile(
    extensionPath,
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  console.log("host process stdout")
  console.error("host process stderr")
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecyclePath)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecyclePath)}, "stop:" + event.reason + "\\n"))
}
`
  )
  const source: ExtensionSource = Object.freeze({
    id: "host-process-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]))

  try {
    expect(host.snapshot()).toMatchObject({ status: "ready", extensions: [{ status: "loaded" }] })
    await host.sessionStart("startup")
    await host.sessionShutdown("quit")
    await host.dispose()

    expect(await readFile(lifecyclePath, "utf8")).toBe("start:startup\nstop:quit\n")
    expect(host.snapshot()).toMatchObject({
      status: "disposed",
      stdout: { text: "host process stdout\n", omittedBytes: 0 },
      stderr: { text: "host process stderr\n", omittedBytes: 0 }
    })
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("ExtensionHost contains a real worker crash during startup", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-crash-"))
  const extensionPath = join(root, "crash.ts")
  await writeFile(extensionPath, `export default function (): void { process.exit(17) }\n`)
  const source: ExtensionSource = Object.freeze({
    id: "host-crash-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]))

  try {
    expect(host.snapshot()).toMatchObject({
      status: "failed",
      extensions: [],
      diagnostics: [expect.objectContaining({ phase: "handshake", severity: "error" })]
    })
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("ExtensionHost terminates a real worker blocked by extension JavaScript", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-blocked-"))
  const extensionPath = join(root, "blocked.ts")
  await writeFile(extensionPath, `export default function (): void { while (true) {} }\n`)
  const source: ExtensionSource = Object.freeze({
    id: "host-blocked-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const timeouts: ExtensionHostTimeouts = { startupMs: 2_000, lifecycleMs: 100, shutdownMs: 300 }
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]), timeouts)

  try {
    expect(host.snapshot()).toMatchObject({
      status: "failed",
      extensions: [],
      diagnostics: [
        expect.objectContaining({ phase: "handshake", message: "Extension worker startup deadline exceeded" })
      ]
    })
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

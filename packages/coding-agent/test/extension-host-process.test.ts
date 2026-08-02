import { expect, test } from "bun:test"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import {
  createExtensionWorkerSpawner as createProductionExtensionWorkerSpawner,
  ExtensionHost,
  type ExtensionHostTimeouts,
  type SpawnExtensionWorker
} from "../src/extensions/host.js"
import { createProcessTreeTracker } from "../src/processes/process-tree.js"

function createExtensionWorkerSpawner(
  command: readonly string[],
  removePublicApiDirectory?: (path: string) => void
): SpawnExtensionWorker {
  return createProductionExtensionWorkerSpawner(command, createProcessTreeTracker(), removePublicApiDirectory)
}

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

test("ExtensionHost provides the public runtime API to external TypeScript tools", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-tool-"))
  const extensionPath = join(root, "tool.ts")
  await writeFile(
    extensionPath,
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "echo_message",
    description: "Echo one message",
    parameters: Schema.object({
      message: Schema.string(),
      amount: Schema.number(),
      count: Schema.integer(),
      enabled: Schema.boolean(),
      tags: Schema.array(Schema.string()),
      mode: Schema.literal("loud"),
      note: Schema.optional(Schema.string())
    }),
    execute: ({ message, amount, count, enabled, tags, mode, note }) =>
      [message.toUpperCase(), amount, count, enabled, tags.join(","), mode, note ?? "none"].join(":")
  })
}
`
  )
  const source: ExtensionSource = Object.freeze({
    id: "host-tool-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]))

  try {
    expect(host.toolCatalog()).toMatchObject([{ name: "echo_message", source: { id: source.id } }])
    await host.sessionStart("startup")
    expect(
      await host.invokeTool("echo_message", {
        message: "external",
        amount: 1.5,
        count: 2,
        enabled: true,
        tags: ["a", "b"],
        mode: "loud"
      })
    ).toBe("EXTERNAL:1.5:2:true:a,b:loud:none")
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("ExtensionHost invokes external TypeScript commands with cancellation", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-command-"))
  const extensionPath = join(root, "command.ts")
  await writeFile(
    extensionPath,
    `import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerCommand({
    name: "echo",
    description: "Echo command arguments",
    argumentHint: "[text]",
    async execute(arguments_, { signal }) {
      if (arguments_ === "wait") {
        if (!signal.aborted) await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }))
        return "late"
      }
      return arguments_.toUpperCase()
    }
  })
}
`
  )
  const source: ExtensionSource = Object.freeze({
    id: "host-command-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]))

  try {
    expect(host.commandCatalog()).toMatchObject([{ name: "echo", source: { id: source.id } }])
    await host.sessionStart("startup")
    expect(await host.invokeCommand("echo", "external")).toBe("EXTERNAL")
    const controller = new AbortController()
    const cancelled = host.invokeCommand("echo", "wait", controller.signal)
    controller.abort()
    expect(cancelled).rejects.toMatchObject({ name: "AbortError" })
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("ExtensionHost contains a real worker crash during tool invocation", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-tool-crash-"))
  const extensionPath = join(root, "tool.ts")
  await writeFile(
    extensionPath,
    `import { Schema } from "@with-zi/extension-api"
export default zi => zi.registerTool({
  name: "crash_tool",
  description: "Crash this worker",
  parameters: Schema.object({}),
  execute: () => process.exit(17)
})
`
  )
  const source: ExtensionSource = Object.freeze({
    id: "host-tool-crash-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]))

  try {
    await host.sessionStart("startup")
    expect(host.invokeTool("crash_tool", {})).rejects.toThrow("unexpectedly")
    await Bun.sleep(10)
    expect(host.snapshot()).toMatchObject({ status: "failed", lifecycle: "started", failure: { phase: "protocol" } })
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("ExtensionHost bounds shutdown with an active tool invocation", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-tool-shutdown-"))
  const extensionPath = join(root, "tool.ts")
  await writeFile(
    extensionPath,
    `import { Schema } from "@with-zi/extension-api"
export default zi => zi.registerTool({
  name: "pending_tool",
  description: "Never settle",
  parameters: Schema.object({}),
  execute: async () => await new Promise(() => {})
})
`
  )
  const source: ExtensionSource = Object.freeze({
    id: "host-tool-shutdown-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  const timeouts: ExtensionHostTimeouts = {
    startupMs: 2_000,
    lifecycleMs: 100,
    shutdownMs: 300,
    commandMs: 2_000,
    commandCancellationMs: 25,
    toolMs: 2_000,
    toolCancellationMs: 25
  }
  const host = await ExtensionHost.create(plan, createExtensionWorkerSpawner([process.execPath, cli]), timeouts)

  try {
    await host.sessionStart("startup")
    const invocation = host.invokeTool("pending_tool", {})
    const disposal = host.dispose()
    expect(invocation).rejects.toThrow("disposed during invocation")
    await disposal
    expect(host.snapshot()).toMatchObject({ status: "disposed", lifecycle: "stopped" })
  } finally {
    await host.dispose()
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("ExtensionHost settles when temporary public API cleanup fails", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-host-cleanup-"))
  const extensionPath = join(root, "extension.ts")
  await writeFile(extensionPath, "export default function () {}\n")
  const source: ExtensionSource = Object.freeze({
    id: "host-cleanup-fixture",
    declaredPath: extensionPath,
    entryPath: extensionPath,
    scope: "temporary",
    origin: "cli"
  })
  const plan: ExtensionLoadPlan = Object.freeze({ cwd: root, sources: Object.freeze([source]) })
  const cli = resolve(import.meta.dirname, "../../cli/src/main.ts")
  let publicApiRoot: string | undefined
  const spawner = createExtensionWorkerSpawner([process.execPath, cli], path => {
    publicApiRoot = path
    throw new Error("public API cleanup denied")
  })
  const host = await ExtensionHost.create(plan, spawner)

  try {
    await host.sessionStart("startup")
    await host.dispose()
    expect(host.snapshot()).toMatchObject({
      status: "disposed",
      diagnostics: [expect.objectContaining({ phase: "shutdown", message: expect.stringContaining("cleanup denied") })]
    })
  } finally {
    await host.dispose()
    if (publicApiRoot) await rm(publicApiRoot, { recursive: true, force: true })
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
  const timeouts: ExtensionHostTimeouts = {
    startupMs: 2_000,
    lifecycleMs: 100,
    shutdownMs: 300,
    commandMs: 100,
    commandCancellationMs: 25,
    toolMs: 100,
    toolCancellationMs: 25
  }
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

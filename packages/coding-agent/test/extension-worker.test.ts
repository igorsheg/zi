import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { pathToFileURL } from "node:url"

import type { ExtensionLoadPlan, ExtensionSource } from "../src/extensions/discovery.js"
import {
  maxExtensionToolCatalogBytes,
  maxExtensionToolDescriptionBytes,
  maxExtensionTools
} from "../src/extensions/protocol.js"
import { loadExtensionGeneration, maxExtensionLifecycleHandlers } from "../src/extensions/worker.js"

const extensionApi = pathToFileURL(resolve(import.meta.dirname, "../../extension-api/src/index.ts")).href

test("worker loading awaits factories and runs lifecycle handlers in source and registration order", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-load-"))
  const log = join(root, "lifecycle.log")
  await writeDependency(root)
  await writeFile(join(root, "fixture.txt"), "fixture value\n")
  const first = await writeExtension(
    root,
    "first.ts",
    `import { appendFileSync, readFileSync } from "node:fs"
import { dependency } from "zi-worker-local-dependency"
import type { ExtensionAPI } from "@with-zi/extension-api"

export default async function (zi: ExtensionAPI): Promise<void> {
  await Promise.resolve()
  const value = readFileSync(new URL("./fixture.txt", import.meta.url), "utf8").trim()
  zi.on("session_start", () => appendFileSync(${JSON.stringify(log)}, "first:" + value + ":" + dependency + "\\n"))
  zi.on("session_start", () => appendFileSync(${JSON.stringify(log)}, "first-second\\n"))
  zi.on("session_shutdown", () => appendFileSync(${JSON.stringify(log)}, "first-stop\\n"))
}
`
  )
  const second = await writeExtension(
    root,
    "second.ts",
    `import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.on("session_start", event => appendFileSync(${JSON.stringify(log)}, "second:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(log)}, "second-stop:" + event.reason + "\\n"))
}
`
  )

  const generation = await loadExtensionGeneration(extensionPlan(root, [first, second]), 1)
  expect(generation.results.map(result => result.status)).toEqual(["loaded", "loaded"])

  expect(await generation.dispatch({ type: "session_start", reason: "startup" })).toEqual({
    diagnostics: [],
    omittedDiagnostics: 0
  })
  expect(await generation.dispatch({ type: "session_shutdown", reason: "quit" })).toEqual({
    diagnostics: [],
    omittedDiagnostics: 0
  })
  expect(await readFile(log, "utf8")).toBe(
    "first:fixture value:local dependency\nfirst-second\nsecond:startup\nfirst-stop\nsecond-stop:quit\n"
  )
  expect(generation.dispatch({ type: "session_start", reason: "reload" })).rejects.toThrow(
    "while extension lifecycle is stopped"
  )
})

test("worker registration exposes typed tools and validates arguments before execution", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tools-"))
  const log = join(root, "tool.log")
  const extension = await writeExtension(
    root,
    "tools.ts",
    `import { appendFileSync } from "node:fs"
import { Schema } from ${JSON.stringify(extensionApi)}
export default function (zi): void {
  zi.registerTool({
    name: "echo_message",
    label: "Echo",
    description: "Echo one message",
    parameters: Schema.object({ message: Schema.string() }),
    execute: ({ message }, { signal }) => {
      appendFileSync(${JSON.stringify(log)}, message + ":" + signal.aborted + "\\n")
      return message.toUpperCase()
    }
  })
}
`
  )

  const generation = await loadExtensionGeneration(extensionPlan(root, [extension]), 1)
  expect(generation.results.map(result => result.status)).toEqual(["loaded"])
  expect(generation.tools).toMatchObject([
    {
      source: { id: extension.id },
      name: "echo_message",
      label: "Echo",
      description: "Echo one message",
      parameters: { type: "object", properties: { message: { type: "string" } } },
      outputSchema: { type: "string" }
    }
  ])
  await generation.dispatch({ type: "session_start", reason: "startup" })

  expect(await generation.invoke("echo_message", { message: "hello" }, new AbortController().signal)).toBe("HELLO")
  expect(generation.invoke("echo_message", { message: 42 }, new AbortController().signal)).rejects.toThrow(
    "Invalid arguments"
  )
  expect(await readFile(log, "utf8")).toBe("hello:false\n")
})

test("worker validates structured tool outputs against their declared schema", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-output-"))
  const extension = await writeExtension(
    root,
    "structured.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default function (zi): void {
  const outputSchema = Schema.object({ count: Schema.integer(), label: Schema.string() })
  zi.registerTool({
    name: "structured_result",
    description: "Return a structured result",
    parameters: Schema.object({ count: Schema.integer() }),
    outputSchema,
    execute: ({ count }) => ({ count, label: String(count) })
  })
  zi.registerTool({
    name: "invalid_result",
    description: "Return an invalid result",
    parameters: Schema.object({}),
    outputSchema,
    execute: () => ({ count: "wrong", label: "invalid" })
  })
}
`
  )

  const generation = await loadExtensionGeneration(extensionPlan(root, [extension]), 1)
  expect(generation.tools).toMatchObject([
    { name: "structured_result", outputSchema: { type: "object" } },
    { name: "invalid_result", outputSchema: { type: "object" } }
  ])
  await generation.dispatch({ type: "session_start", reason: "startup" })

  expect(await generation.invoke("structured_result", { count: 3 }, new AbortController().signal)).toEqual({
    count: 3,
    label: "3"
  })
  expect(generation.invoke("invalid_result", {}, new AbortController().signal)).rejects.toThrow(
    "Invalid result for extension tool invalid_result"
  )
})

test("invalid and duplicate tool registrations fail only their source", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tool-registration-"))
  const first = await writeExtension(
    root,
    "first.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "shared_tool",
  description: "First",
  parameters: Schema.object({}),
  execute: () => "first"
})
`
  )
  const duplicate = await writeExtension(
    root,
    "duplicate.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "shared_tool",
  description: "Duplicate",
  parameters: Schema.object({}),
  execute: () => "duplicate"
})
`
  )
  const invalid = await writeExtension(
    root,
    "invalid.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "Invalid-Tool",
  description: "Invalid",
  parameters: Schema.string(),
  execute: () => "invalid"
})
`
  )
  const malformedSchema = await writeExtension(
    root,
    "malformed-schema.ts",
    `export default zi => zi.registerTool({
  name: "malformed_schema",
  description: "Malformed schema",
  parameters: { type: "object", properties: { value: { type: "string", pattern: "[" } } },
  execute: () => "invalid"
})
`
  )
  const valid = await writeExtension(
    root,
    "valid.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "valid_tool",
  description: "Valid",
  parameters: Schema.object({}),
  execute: () => "valid"
})
`
  )

  const generation = await loadExtensionGeneration(
    extensionPlan(root, [first, duplicate, invalid, malformedSchema, valid]),
    1
  )
  expect(generation.results.map(result => [result.status, result.diagnostic?.phase])).toEqual([
    ["loaded", undefined],
    ["failed", "registration"],
    ["failed", "registration"],
    ["failed", "registration"],
    ["loaded", undefined]
  ])
  expect(generation.results[1]?.diagnostic?.message).toContain("Duplicate extension tool name")
  expect(generation.results[2]?.diagnostic?.message).toContain("tool names")
  expect(generation.results[3]?.diagnostic?.message).toContain("Invalid regular expression")
  expect(generation.tools.map(tool => tool.name)).toEqual(["shared_tool", "valid_tool"])
})

test("worker loading attributes import, export, and factory failures and discards partial registration", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-failures-"))
  const log = join(root, "lifecycle.log")
  const importFailure = await writeExtension(root, "import-failure.ts", `throw new Error("import exploded")\n`)
  const invalidExport = await writeExtension(root, "invalid-export.ts", `export default 42\n`)
  const factoryFailure = await writeExtension(
    root,
    "factory-failure.ts",
    `import { appendFileSync } from "node:fs"
export default function (zi): never {
  zi.on("session_start", () => appendFileSync(${JSON.stringify(log)}, "must not run\\n"))
  throw new Error("factory exploded")
}
`
  )
  const valid = await writeExtension(root, "valid.ts", `export default function () {}\n`)

  const generation = await loadExtensionGeneration(
    extensionPlan(root, [importFailure, invalidExport, factoryFailure, valid]),
    1
  )

  expect(
    generation.results.map(result => [result.status, result.diagnostic?.phase, result.diagnostic?.message])
  ).toEqual([
    ["failed", "import", "import exploded"],
    ["failed", "factory", "Extension default export must be a function"],
    ["failed", "factory", "factory exploded"],
    ["loaded", undefined, undefined]
  ])
  await generation.dispatch({ type: "session_start", reason: "startup" })
  expect(readFile(log, "utf8")).rejects.toThrow()
})

test("worker factory deadlines close late registration and continue with later sources", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-factory-timeout-"))
  const pending = await writeExtension(
    root,
    "pending.ts",
    `export default async function (zi): Promise<never> {
  setTimeout(() => {
    try { zi.on("session_start", () => {}) } catch {}
  }, 40)
  await new Promise(() => {})
}
`
  )
  const valid = await writeExtension(root, "valid.ts", `export default function () {}\n`)

  const generation = await loadExtensionGeneration(extensionPlan(root, [pending, valid]), 1, 20)
  expect(generation.results.map(result => [result.status, result.diagnostic?.message])).toEqual([
    ["failed", "Extension factory deadline exceeded"],
    ["loaded", undefined]
  ])
})

test("worker lifecycle failures continue in order while a deadline fails the generation", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-lifecycle-"))
  const log = join(root, "lifecycle.log")
  const extension = await writeExtension(
    root,
    "lifecycle.ts",
    `import { appendFileSync } from "node:fs"
export default function (zi): void {
  zi.on("session_start", () => { throw new Error("first failed") })
  zi.on("session_start", () => appendFileSync(${JSON.stringify(log)}, "second ran\\n"))
  zi.on("session_shutdown", async () => { await new Promise(() => {}) })
}
`
  )
  const generation = await loadExtensionGeneration(extensionPlan(root, [extension]), 1)

  const started = await generation.dispatch({ type: "session_start", reason: "startup" }, 100)
  expect(started).toMatchObject({
    diagnostics: [{ extensionId: extension.id, phase: "lifecycle", message: "first failed" }],
    omittedDiagnostics: 0
  })
  expect(await readFile(log, "utf8")).toBe("second ran\n")

  const shutdown = await generation.dispatch({ type: "session_shutdown", reason: "quit" }, 20)
  expect(shutdown.fatal).toMatchObject({
    extensionId: extension.id,
    phase: "lifecycle",
    message: "Extension lifecycle deadline exceeded"
  })
  expect(generation.dispatch({ type: "session_shutdown", reason: "quit" })).rejects.toThrow(
    "while extension lifecycle is failed"
  )
})

test("worker lifecycle admission rejects concurrent and out-of-order transitions", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-transitions-"))
  const extension = await writeExtension(
    root,
    "pending-start.ts",
    `export default function (zi): void {
  zi.on("session_start", async () => { await new Promise(() => {}) })
}
`
  )
  const generation = await loadExtensionGeneration(extensionPlan(root, [extension]), 1)

  expect(generation.dispatch({ type: "session_shutdown", reason: "quit" })).rejects.toThrow(
    "while extension lifecycle is loaded"
  )
  const start = generation.dispatch({ type: "session_start", reason: "startup" }, 20)
  expect(generation.dispatch({ type: "session_start", reason: "reload" })).rejects.toThrow(
    "while extension lifecycle is starting"
  )
  expect((await start).fatal?.phase).toBe("lifecycle")
})

test("an aggregate tool catalog overflow rolls back only its source", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tool-catalog-bound-"))
  const excessive = await writeExtension(
    root,
    "excessive.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default function (zi): void {
  for (let index = 0; index < ${maxExtensionTools}; index++) {
    zi.registerTool({
      name: "catalog_tool_" + index,
      description: "d".repeat(${maxExtensionToolDescriptionBytes}),
      parameters: Schema.object({}, { description: "s".repeat(8_000) }),
      execute: () => "done"
    })
  }
}
`
  )
  const valid = await writeExtension(
    root,
    "valid.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "valid_tool",
  description: "Valid",
  parameters: Schema.object({}),
  execute: () => "done"
})
`
  )

  const generation = await loadExtensionGeneration(extensionPlan(root, [excessive, valid]), 1)
  expect(generation.results.map(result => [result.status, result.diagnostic?.message])).toEqual([
    ["failed", `Extension tool catalog cannot exceed ${maxExtensionToolCatalogBytes} bytes`],
    ["loaded", undefined]
  ])
  expect(generation.tools.map(tool => tool.name)).toEqual(["valid_tool"])
})

test("failed registrations cannot consume the generation tool bound", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-tool-bound-"))
  const excessive = await writeExtension(
    root,
    "excessive.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default function (zi): void {
  for (let index = 0; index <= ${maxExtensionTools}; index++) {
    zi.registerTool({
      name: "tool_" + index,
      description: "Bounded tool",
      parameters: Schema.object({}),
      execute: () => "done"
    })
  }
}
`
  )
  const valid = await writeExtension(
    root,
    "valid.ts",
    `import { Schema } from ${JSON.stringify(extensionApi)}
export default zi => zi.registerTool({
  name: "valid_tool",
  description: "Valid",
  parameters: Schema.object({}),
  execute: () => "done"
})
`
  )

  const generation = await loadExtensionGeneration(extensionPlan(root, [excessive, valid]), 1)
  expect(generation.results.map(result => [result.status, result.diagnostic?.message])).toEqual([
    ["failed", `Extension generations cannot register more than ${maxExtensionTools} tools`],
    ["loaded", undefined]
  ])
  expect(generation.tools.map(tool => tool.name)).toEqual(["valid_tool"])
})

test("failed factories cannot consume the generation lifecycle-handler bound", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-worker-handler-bound-"))
  const excessive = await writeExtension(
    root,
    "excessive.ts",
    `export default function (zi): void {
  for (let index = 0; index <= ${maxExtensionLifecycleHandlers}; index++) zi.on("session_start", () => {})
}
`
  )
  const valid = await writeExtension(
    root,
    "valid.ts",
    `export default function (zi): void { zi.on("session_start", () => {}) }\n`
  )

  const generation = await loadExtensionGeneration(extensionPlan(root, [excessive, valid]), 1)
  expect(generation.results.map(result => [result.status, result.diagnostic?.message])).toEqual([
    ["failed", `Extension generations cannot register more than ${maxExtensionLifecycleHandlers} lifecycle handlers`],
    ["loaded", undefined]
  ])
  expect((await generation.dispatch({ type: "session_start", reason: "startup" })).diagnostics).toEqual([])
})

async function writeExtension(root: string, name: string, source: string): Promise<ExtensionSource> {
  const path = join(root, name)
  await writeFile(path, source)
  return Object.freeze({ id: name, declaredPath: path, entryPath: path, scope: "temporary", origin: "cli" })
}

function extensionPlan(cwd: string, sources: readonly ExtensionSource[]): ExtensionLoadPlan {
  return Object.freeze({ cwd, sources: Object.freeze([...sources]) })
}

async function writeDependency(root: string): Promise<void> {
  const directory = join(root, "node_modules", "zi-worker-local-dependency")
  await mkdir(directory, { recursive: true })
  await writeFile(
    join(directory, "package.json"),
    JSON.stringify({ name: "zi-worker-local-dependency", type: "module", exports: "./index.js" })
  )
  await writeFile(join(directory, "index.js"), `export const dependency = "local dependency"\n`)
}

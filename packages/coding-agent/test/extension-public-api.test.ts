import { expect, test } from "bun:test"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

import { Schema } from "@with-zi/extension-api"

import { extensionApiModuleSource } from "../src/extensions/public-api-module.js"

function buildSchema(schema: typeof Schema) {
  return schema.object(
    {
      text: schema.string({ description: "Text", pattern: "^[a-z]+$" }),
      count: schema.integer({ minimum: 1 }),
      mode: schema.literal("loud", { description: "Mode" }),
      tags: schema.optional(schema.array(schema.string(), { maxItems: 4 }))
    },
    { additionalProperties: false }
  )
}

function invalidLiteral(schema: typeof Schema): unknown {
  return Reflect.apply(schema.literal, undefined, [1n])
}

function isProvisionedApi(value: unknown): value is { readonly Schema: typeof Schema } {
  if (typeof value !== "object" || value === null || !("Schema" in value)) return false
  const schema = value.Schema
  return typeof schema === "object" && schema !== null && "object" in schema && typeof schema.object === "function"
}

test("provisioned and published schema builders are behaviorally identical", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-extension-public-api-"))
  const modulePath = join(root, "index.mjs")
  try {
    await writeFile(modulePath, extensionApiModuleSource)
    const provisioned: unknown = await import(pathToFileURL(modulePath).href)
    if (!isProvisionedApi(provisioned)) throw new Error("Provisioned extension API did not export Schema")

    expect(buildSchema(provisioned.Schema)).toEqual(buildSchema(Schema))
    expect(provisioned.Schema.literal(null, { title: "None" })).toEqual(Schema.literal(null, { title: "None" }))
    expect(() => invalidLiteral(provisioned.Schema)).toThrow("Literal values must be JSON primitives")
    expect(() => invalidLiteral(Schema)).toThrow("Literal values must be JSON primitives")
    expect(Object.isFrozen(buildSchema(provisioned.Schema))).toBe(true)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

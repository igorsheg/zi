import { maxExpandedToolRows, type ToolPresentation, type ToolPresentationSource, type ToolSubject } from "./types.js"
import { boundHead, boundInline, recordValue, resultText, stringValue } from "./values.js"

// Keys that usually name the one thing an unknown tool acts on; the first
// string-valued match becomes the subject and the tool name drops to details.
const salientKeys = ["path", "file", "command", "query", "url", "uri", "operation", "name", "id", "key"] as const
const maxScalarArgEntries = 8
const maxScalarArgValueScalars = 160

export function projectGeneric(source: ToolPresentationSource): ToolPresentation {
  const name = source.name || "unknown"
  const salient = salientSubject(recordValue(source.args))
  const args = argumentsText(source.args)
  const result =
    "result" in source ? (resultText(source.result) ?? serialized(source.result, "unserializable result")) : ""
  const sections = [`Arguments:\n${args || "undefined"}`]
  if (result)
    sections.push(`${source.status === "failed" || source.status === "aborted" ? "Error" : "Result"}:\n${result}`)
  return {
    header: {
      label: "Tool",
      subject: salient ?? { type: "text", text: boundInline(name) },
      details: salient ? [boundInline(name)] : []
    },
    body: {
      type: "text",
      text: boundHead(sections.join("\n\n")),
      tone: source.status === "failed" || source.status === "aborted" ? "error" : "normal"
    },
    notices: [],
    preview: { compact: { type: "head", rows: 10 }, detailed: { type: "head", rows: maxExpandedToolRows } },
    timing: "duration"
  }
}

function salientSubject(args: Record<string, unknown> | undefined): ToolSubject | undefined {
  if (!args) return undefined
  for (const key of salientKeys) {
    const value = stringValue(args[key])
    if (!value) continue
    const text = boundInline(value, maxScalarArgValueScalars)
    if (key === "path" || key === "file") return { type: "path", path: text }
    if (key === "command") return { type: "command", text, prompt: false }
    return { type: "text", text }
  }
  return undefined
}

// Small all-scalar argument records read far better as `key: value` lines
// than as JSON; anything larger falls back to the bounded serializer.
function argumentsText(args: unknown): string {
  const record = recordValue(args)
  if (record) {
    const entries = Object.entries(record)
    const scalars =
      entries.length > 0 &&
      entries.length <= maxScalarArgEntries &&
      entries.every(([key, value]) => key && scalarArgument(value) !== undefined)
    if (scalars) return entries.map(([key, value]) => `${key}: ${scalarArgument(value)}`).join("\n")
  }
  return serialized(args, "unserializable arguments")
}

function scalarArgument(value: unknown): string | undefined {
  if (typeof value === "string") return boundInline(value, maxScalarArgValueScalars)
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "boolean" || value === null) return String(value)
  return undefined
}

const maxSerializedDepth = 8
const maxSerializedItems = 128
const maxSerializedScalars = 16_384
const maxSerializedStringScalars = 4_096

type JsonValue = null | boolean | number | string | undefined | JsonValue[] | { [key: string]: JsonValue }

interface SerializationBudget {
  items: number
  scalars: number
}

function serialized(value: unknown, fallback: string): string {
  try {
    const budget: SerializationBudget = { items: maxSerializedItems, scalars: maxSerializedScalars }
    const projected = projectJson(value, budget, new Set(), 0)
    return boundHead(JSON.stringify(projected, null, 2) ?? "")
  } catch {
    return fallback
  }
}

function projectJson(value: unknown, budget: SerializationBudget, ancestors: Set<object>, depth: number): JsonValue {
  if (value === null || typeof value === "boolean") return value
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  if (typeof value === "string") return boundedString(value, budget)
  if (typeof value === "undefined" || typeof value === "function" || typeof value === "symbol") return undefined
  if (typeof value === "bigint") throw new TypeError("BigInt is not JSON serializable")
  if (depth === maxSerializedDepth) return "… depth limit"
  if (ancestors.has(value)) throw new TypeError("Circular value")

  ancestors.add(value)
  try {
    if (Array.isArray(value)) return projectArray(value, budget, ancestors, depth)
    return projectObject(value, budget, ancestors, depth)
  } finally {
    ancestors.delete(value)
  }
}

function projectArray(
  value: readonly unknown[],
  budget: SerializationBudget,
  ancestors: Set<object>,
  depth: number
): JsonValue[] {
  const output: JsonValue[] = []
  let index = 0
  while (index < value.length && budget.items > 0) {
    budget.items--
    output.push(projectJson(value[index], budget, ancestors, depth + 1))
    index++
  }
  if (index < value.length) output.push(`… ${value.length - index} more items`)
  return output
}

function projectObject(
  value: object,
  budget: SerializationBudget,
  ancestors: Set<object>,
  depth: number
): { [key: string]: JsonValue } {
  const output: { [key: string]: JsonValue } = {}
  let omitted = false
  for (const key in value) {
    if (!Object.hasOwn(value, key)) continue
    if (budget.items === 0) {
      omitted = true
      break
    }
    budget.items--
    output[boundedString(key, budget)] = projectJson(Reflect.get(value, key), budget, ancestors, depth + 1)
  }
  if (omitted) output["…"] = "collection limit"
  return output
}

function boundedString(value: string, budget: SerializationBudget): string {
  const limit = Math.min(maxSerializedStringScalars, budget.scalars)
  const output: string[] = []
  let count = 0
  for (const scalar of value) {
    if (count === limit) break
    output.push(scalar)
    count++
  }
  budget.scalars -= count
  return count < scalarLengthAtMost(value, limit + 1) ? `${output.join("")}…` : output.join("")
}

function scalarLengthAtMost(value: string, limit: number): number {
  let count = 0
  for (const scalar of value) {
    if (scalar.length > 0) count++
    if (count === limit) break
  }
  return count
}

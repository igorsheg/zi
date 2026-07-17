import type { ToolPresentation, ToolPresentationSource } from "./types.js"
import { boundHead, boundInline, resultText } from "./values.js"

export function projectGeneric(source: ToolPresentationSource): ToolPresentation {
  const args = serialized(source.args, "unserializable arguments")
  const result =
    "result" in source ? (resultText(source.result) ?? serialized(source.result, "unserializable result")) : ""
  const sections = [`Arguments:\n${args || "undefined"}`]
  if (result)
    sections.push(`${source.status === "failed" || source.status === "aborted" ? "Error" : "Result"}:\n${result}`)
  return {
    header: { label: "Tool", subject: { type: "text", text: boundInline(source.name || "unknown") }, details: [] },
    body: {
      type: "text",
      text: boundHead(sections.join("\n\n")),
      tone: source.status === "failed" || source.status === "aborted" ? "error" : "normal"
    },
    notices: [],
    preview: { type: "head", rows: 10 }
  }
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

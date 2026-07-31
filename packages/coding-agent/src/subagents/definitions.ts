import type { ExtensionSource } from "../extensions/discovery.js"

export interface SubagentTypeDefinition {
  readonly name: string
  readonly description: string
  readonly instructions: string
}

export interface RegisteredSubagentType extends SubagentTypeDefinition {
  readonly source: ExtensionSource
}

export const maxSubagentTypes = 32
export const maxSubagentTypeNameBytes = 64
export const maxSubagentTypeDescriptionBytes = 4 * 1024
export const maxSubagentTypeInstructionsBytes = 32 * 1024
export const maxSubagentTypeCatalogBytes = 256 * 1024

const namePattern = /^[a-z][a-z0-9_-]*$/

export const generalSubagentType: SubagentTypeDefinition = Object.freeze({
  name: "general",
  description: "General coding, research, and repository work with normal Zi tools",
  instructions:
    "Complete the delegated task independently. Return a concise final answer with relevant paths and findings."
})

export function validateSubagentTypeDefinition(value: unknown): SubagentTypeDefinition {
  if (
    !isRecord(value) ||
    Object.keys(value).some(key => key !== "name" && key !== "description" && key !== "instructions")
  ) {
    throw new Error("Subagent type definitions require only name, description, and instructions")
  }
  const name = boundedText(value.name, "Subagent type name", maxSubagentTypeNameBytes)
  if (!namePattern.test(name)) {
    throw new Error("Subagent type names must start with a letter and contain only lowercase letters, numbers, _ or -")
  }
  const description = boundedText(value.description, "Subagent type description", maxSubagentTypeDescriptionBytes)
  const instructions = boundedText(value.instructions, "Subagent type instructions", maxSubagentTypeInstructionsBytes)
  return Object.freeze({ name, description, instructions })
}

export function validateRegisteredSubagentType(value: unknown): RegisteredSubagentType {
  if (!isRecord(value) || !isRecord(value.source)) throw new Error("Registered subagent types require a source")
  const definition = validateSubagentTypeDefinition({
    name: value.name,
    description: value.description,
    instructions: value.instructions
  })
  const rawSource = value.source
  if (
    typeof rawSource.id !== "string" ||
    typeof rawSource.declaredPath !== "string" ||
    typeof rawSource.entryPath !== "string" ||
    (rawSource.scope !== "global" && rawSource.scope !== "project" && rawSource.scope !== "temporary") ||
    (rawSource.origin !== "directory" && rawSource.origin !== "package" && rawSource.origin !== "cli")
  ) {
    throw new Error("Registered subagent types require a valid extension source")
  }
  const source: ExtensionSource = Object.freeze({
    id: rawSource.id,
    declaredPath: rawSource.declaredPath,
    entryPath: rawSource.entryPath,
    scope: rawSource.scope,
    origin: rawSource.origin
  })
  return Object.freeze({ source, ...definition })
}

export function validateSubagentTypeCatalog(value: unknown): readonly RegisteredSubagentType[] {
  if (!Array.isArray(value) || value.length > maxSubagentTypes) {
    throw new Error(`Extension generations cannot register more than ${maxSubagentTypes} subagent types`)
  }
  const definitions = value.map(validateRegisteredSubagentType)
  const names = new Set<string>()
  for (const definition of definitions) {
    if (definition.name === generalSubagentType.name)
      throw new Error("The built-in subagent type general cannot be replaced")
    if (names.has(definition.name)) throw new Error(`Duplicate subagent type name: ${definition.name}`)
    names.add(definition.name)
  }
  if (Buffer.byteLength(JSON.stringify(definitions)) > maxSubagentTypeCatalogBytes) {
    throw new Error(`Subagent type catalog cannot exceed ${maxSubagentTypeCatalogBytes} bytes`)
  }
  return Object.freeze(definitions)
}

function boundedText(value: unknown, label: string, maxBytes: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    Buffer.byteLength(value) > maxBytes ||
    value.includes("\0") ||
    value.includes("\r")
  ) {
    throw new Error(`${label} must contain 1 to ${maxBytes} UTF-8 bytes without NUL or carriage returns`)
  }
  return value
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

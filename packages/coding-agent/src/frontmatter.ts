import { parse } from "yaml"

export interface ParsedFrontmatter {
  readonly frontmatter: Readonly<Record<string, unknown>>
  readonly body: string
}

export function parseFrontmatter(content: string): ParsedFrontmatter {
  const { source, body } = extractFrontmatter(content)
  if (source === undefined || source.length === 0) return { frontmatter: {}, body }
  const parsed: unknown = parse(source)
  if (parsed === null || parsed === undefined) return { frontmatter: {}, body }
  if (!isRecord(parsed)) throw new Error("Frontmatter must be a YAML mapping")
  return { frontmatter: parsed, body }
}

export function stripFrontmatter(content: string): string {
  return parseFrontmatter(content).body
}

function extractFrontmatter(content: string): { readonly source?: string; readonly body: string } {
  const normalized = content.replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  if (!normalized.startsWith("---")) return { body: normalized }
  const end = normalized.indexOf("\n---", 3)
  if (end < 0) return { body: normalized }
  return { source: normalized.slice(4, end), body: normalized.slice(end + 4).trim() }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

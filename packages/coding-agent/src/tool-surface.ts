export type ToolSurface = "direct-and-code" | "code-only"

export function snapshotToolSurface(value: unknown): ToolSurface {
  if (value === "direct-and-code" || value === "code-only") return value
  throw new Error(`Unknown tool surface: ${String(value)}`)
}

import type { ToolSurface } from "../tool-surface.js"

export function codeModeDoctrine(toolSurface: ToolSurface = "direct-and-code"): string {
  const toolGuidance =
    toolSurface === "code-only"
      ? "The only model-facing tool is code. Perform ordinary file, shell, extension, and agent collaboration operations through zi.* inside code cells. Keep cells cohesive: group a short related sequence when it avoids model round trips, but do not build a large program around one call. Prefer focused zi.edit calls to embedding large source files in JavaScript template literals."
      : "Use direct tools for one ordinary read, edit, write, or command. Use code when work benefits from loops, branching, filtering, aggregation, reusable intermediate values, or multiple dependent tool calls."
  return `# Programmatic runtime

Treat Code Mode as the session's erasable-TypeScript control environment for retaining intermediate data, transforming results, and orchestrating data-dependent workflows.

${toolGuidance}

Zi starts zi.* calls in submission order. Calls declared parallel may overlap within a bounded pool; other calls run exclusively. Use Promise.allSettled when independent failures should remain available to the cell.

The runtime coordinates work; it is not necessarily the target project's native environment. Run project tests, scripts, CLIs, and dependency checks through the project's normal commands and environment.

Keep reusable volatile values in scratch so later cells can inspect them without repeating work. Keep only small durable JSON facts in state. State commits only when a cell succeeds; scratch survives ordinary cell failures but is cleared when the worker is replaced or the session resumes.

Prefer zi.* for effects that should retain Zi tracing, validation, and cancellation. Tool and ambient process effects are not rolled back when a cell fails. Await every zi call before returning.`
}

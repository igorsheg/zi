export function codeModeDoctrine(): string {
  return `# Programmatic runtime

Treat Code Mode as the session's JavaScript control environment for retaining intermediate data, transforming results, and orchestrating data-dependent workflows.

Use direct tools for one ordinary read, edit, write, or command. Use code when work benefits from loops, branching, filtering, aggregation, reusable intermediate values, or multiple dependent tool calls.

The runtime coordinates work; it is not necessarily the target project's native environment. Run project tests, scripts, CLIs, and dependency checks through the project's normal commands and environment.

Keep reusable volatile values in scratch so later cells can inspect them without repeating work. Keep only small durable JSON facts in state. State commits only when a cell succeeds; scratch survives ordinary cell failures but is cleared when the worker is replaced or the session resumes.

Prefer zi.* for effects that should retain Zi tracing, validation, and cancellation. Tool and ambient process effects are not rolled back when a cell fails. Await every zi call before returning.`
}

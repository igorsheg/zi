import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_status",
    description: "Show concise Git status for the repository or one path",
    parameters: Schema.object({
      path: Schema.optional(Schema.string({ description: "Optional repository-relative path" }))
    }),
    async execute({ path }, { signal }) {
      const child = Bun.spawn(["git", "status", "--short", ...(path ? ["--", path] : [])], {
        cwd: process.cwd(),
        stdout: "pipe",
        stderr: "pipe",
        signal
      })
      const [exitCode, stdout, stderr] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text()
      ])
      if (exitCode !== 0) throw new Error(stderr.trim() || `git status exited with ${exitCode}`)
      return stdout || "Working tree is clean."
    }
  })
}

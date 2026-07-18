import { expect, test } from "bun:test"
import { chmod, mkdtemp, rm } from "node:fs/promises"
import { join, resolve } from "node:path"

import { compileStandalone } from "./compile-openzi.js"

test("the standalone bundle resolves OAuth and marks its constrained runtime", async () => {
  const temporary = await mkdtemp(join(import.meta.dirname, ".compiled-standalone-"))
  const entrypoint = join(temporary, "smoke.ts")
  const executable = join(temporary, process.platform === "win32" ? "smoke.exe" : "smoke")
  const providers = Bun.resolveSync(
    "@earendil-works/pi-ai/providers/all",
    resolve(import.meta.dirname, "../packages/coding-agent/src")
  )
  try {
    await Bun.write(
      entrypoint,
      `
import { builtinModels } from ${JSON.stringify(providers)}

if (process.env.OPENZI_STANDALONE !== "1") throw new Error("Standalone runtime marker is missing")

const providerIds = ["anthropic", "github-copilot", "openai-codex"]
const credential = {
  type: "oauth",
  access: "compiled-oauth-access",
  refresh: "compiled-oauth-refresh",
  expires: Date.now() + 60_000
}
const credentials = {
  async read(providerId) {
    return providerIds.includes(providerId) ? credential : undefined
  },
  async modify() {
    return credential
  },
  async delete() {}
}
const models = builtinModels({ credentials })
for (const providerId of providerIds) {
  const model = models.getModels(providerId)[0]
  if (!model) throw new Error(\`Missing model for \${providerId}\`)
  const auth = await models.getAuth(model)
  if (auth?.auth.apiKey !== credential.access) throw new Error(\`OAuth derivation failed for \${providerId}\`)
}
`
    )
    await compileStandalone(entrypoint, executable)
    if (process.platform !== "win32") await chmod(executable, 0o755)
    const child = Bun.spawn([executable], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])

    expect({ exitCode, stdout, stderr }).toEqual({ exitCode: 0, stdout: "", stderr: "" })
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}, 30_000)

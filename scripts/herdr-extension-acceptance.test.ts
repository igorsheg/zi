import { expect, test } from "bun:test"
import { resolve } from "node:path"

test("the shipped Herdr extension passes its socket integration acceptance", async () => {
  const testFile = resolve(import.meta.dirname, "../examples/extensions/herdr-agent-state/index.test.ts")
  const child = Bun.spawn([process.execPath, "test", testFile], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])

  expect(exitCode, `${stdout}\n${stderr}`).toBe(0)
})

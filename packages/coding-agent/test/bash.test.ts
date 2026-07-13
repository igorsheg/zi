import { expect, test } from "bun:test"
import { existsSync, rmSync } from "node:fs"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { createBashTool } from "../src/tools/bash.js"
import { DEFAULT_MAX_BYTES } from "../src/tools/truncate.js"

test("bash bounds model output and preserves the full stream", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "openzi-bash-"))
  const tool = createBashTool(cwd)
  const result = await tool.execute("bash-1", { command: `node -e "process.stdout.write('x'.repeat(${DEFAULT_MAX_BYTES + 4096}))"` })

  const output = result.content[0]
  expect(output?.type).toBe("text")
  if (output?.type !== "text") throw new Error("Expected text output")
  expect(Buffer.byteLength(output.text)).toBeLessThan(DEFAULT_MAX_BYTES + 512)
  expect(result.details?.truncation?.truncated).toBe(true)
  expect(result.details?.fullOutputPath && existsSync(result.details.fullOutputPath)).toBe(true)

  if (result.details?.fullOutputPath) rmSync(dirname(result.details.fullOutputPath), { recursive: true, force: true })
})

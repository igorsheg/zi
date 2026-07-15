import { afterEach, beforeEach } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const originalDirectory = process.env.OPENZI_AGENT_DIR
let directory: string | undefined

beforeEach(() => {
  directory = mkdtempSync(join(tmpdir(), "openzi-tests-"))
  process.env.OPENZI_AGENT_DIR = directory
})

afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true })
  directory = undefined
  if (originalDirectory === undefined) delete process.env.OPENZI_AGENT_DIR
  else process.env.OPENZI_AGENT_DIR = originalDirectory
})

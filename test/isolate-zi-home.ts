import { afterEach, beforeEach } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const originalDirectory = process.env.ZI_AGENT_DIR
let directory: string | undefined

beforeEach(() => {
  directory = mkdtempSync(join(tmpdir(), "zi-tests-"))
  process.env.ZI_AGENT_DIR = directory
})

afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true })
  directory = undefined
  if (originalDirectory === undefined) delete process.env.ZI_AGENT_DIR
  else process.env.ZI_AGENT_DIR = originalDirectory
})

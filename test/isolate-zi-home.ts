import { afterEach, beforeEach } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const originalDirectory = process.env.ZI_AGENT_DIR
const originalHome = process.env.HOME
let directory: string | undefined

beforeEach(() => {
  directory = mkdtempSync(join(tmpdir(), "zi-tests-"))
  process.env.ZI_AGENT_DIR = directory
  process.env.HOME = directory
})

afterEach(() => {
  if (directory) rmSync(directory, { recursive: true, force: true })
  directory = undefined
  if (originalDirectory === undefined) delete process.env.ZI_AGENT_DIR
  else process.env.ZI_AGENT_DIR = originalDirectory
  if (originalHome === undefined) delete process.env.HOME
  else process.env.HOME = originalHome
})

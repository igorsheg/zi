import { existsSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import process from "node:process"

const exhausted = join(process.cwd(), ".compute-budget-exhausted")
if (!existsSync(exhausted)) {
  writeFileSync(exhausted, "")
  Object.defineProperty(process, "cpuUsage", {
    value(previous?: NodeJS.CpuUsage): NodeJS.CpuUsage {
      return previous ? { user: 60_001_000, system: 0 } : { user: 0, system: 0 }
    }
  })
}

const { runCodeModeWorkerFromStdio } = await import("../../src/code-mode/worker.js")
await runCodeModeWorkerFromStdio()

import process from "node:process"

Object.defineProperty(process, "cpuUsage", {
  value(previous?: NodeJS.CpuUsage): NodeJS.CpuUsage {
    return previous ? { user: 60_001_000, system: 0 } : { user: 0, system: 0 }
  }
})

const { runCodeModeWorkerFromStdio } = await import("../../src/code-mode/worker.js")
await runCodeModeWorkerFromStdio()

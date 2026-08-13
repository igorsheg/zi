import { expect, test } from "bun:test"

import { spawnOwnedProcess } from "../src/processes/owned-process.js"
import type { ProcessScope, ProcessTreeTracker } from "../src/processes/process-tree.js"

test("owned raw processes expose bounded stdio and one terminal exit", async () => {
  const child = spawnOwnedProcess({
    type: "raw",
    pipeAdapter: "direct",
    command: [process.execPath, "-e", 'process.stdout.write("out"); process.stderr.write("err")'],
    cwd: process.cwd(),
    env: process.env,
    signalUntrackedProcessGroup: true
  })

  const [stdout, stderr, exit] = await Promise.all([readText(child.stdout), readText(child.stderr), child.exited])
  expect({ stdout, stderr, exit }).toEqual({ stdout: "out", stderr: "err", exit: { code: 0, signal: null } })
  await child.dispose()
})

test("owned protocol processes keep fd3 separate from stdout", async () => {
  const child = spawnOwnedProcess({
    type: "protocol",
    pipeAdapter: "direct",
    command: [process.execPath, "-e", 'require("node:fs").writeSync(3, "protocol"); process.stdout.write("log")'],
    cwd: process.cwd(),
    env: process.env
  })

  const [protocol, stdout, exit] = await Promise.all([readText(child.protocol), readText(child.stdout), child.exited])
  expect({ protocol, stdout, exit }).toEqual({ protocol: "protocol", stdout: "log", exit: { code: 0, signal: null } })
  await child.dispose()
})

test("owned processes project tracker admission, refresh, containment failure, and termination", async () => {
  let failContainment!: (error: Error) => void
  let terminations = 0
  let disposals = 0
  const tracker: ProcessTreeTracker = {
    track(pid, onFailure): ProcessScope {
      failContainment = error => onFailure?.(error)
      return {
        platform: process.platform === "win32" ? "windows" : "posix",
        workerPid: pid,
        admitted: Promise.resolve(),
        snapshot: () => ({ workerPid: pid, identities: [] }),
        refresh: async () => ({ type: "ok" }),
        terminate: async () => {
          terminations++
          return { type: "terminated", signaledGroups: 0 }
        },
        dispose: async () => {
          disposals++
        }
      }
    },
    dispose: async () => {}
  }
  const child = spawnOwnedProcess({
    type: "raw",
    pipeAdapter: "direct",
    command: [process.execPath, "-e", "setInterval(() => {}, 1 << 30)"],
    cwd: process.cwd(),
    env: process.env,
    processTreeTracker: tracker
  })

  await child.admitted
  expect(await child.refreshTree()).toEqual({ type: "ok" })
  const containment = child.containmentFailure.catch(cause => cause)
  failContainment(new Error("containment lost"))
  expect(await containment).toEqual(expect.objectContaining({ message: "containment lost" }))
  await child.terminateTree()
  child.terminate(true)
  await child.exited
  await child.dispose()
  expect({ terminations, disposals }).toEqual({ terminations: 1, disposals: 1 })
})

test("owned process commands require one bounded absolute executable", () => {
  expect(() =>
    spawnOwnedProcess({ type: "raw", pipeAdapter: "direct", command: ["node"], cwd: process.cwd(), env: process.env })
  ).toThrow("absolute executable")
})

async function readText(stream: NodeJS.ReadableStream): Promise<string> {
  let text = ""
  for await (const chunk of stream) text += Buffer.from(chunk).toString()
  return text
}

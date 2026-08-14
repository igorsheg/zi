import { expect, test } from "bun:test"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { spawnOwnedProcess } from "../src/processes/owned-process.js"
import { createProcessTreeTracker, type ProcessScope, type ProcessTreeTracker } from "../src/processes/process-tree.js"

test("owned raw processes expose bounded stdio and one terminal exit", async () => {
  const tracker = createProcessTreeTracker()
  const child = spawnOwnedProcess({
    type: "raw",
    pipeAdapter: "direct",
    command: [process.execPath, "-e", 'process.stdout.write("out"); process.stderr.write("err")'],
    cwd: process.cwd(),
    env: process.env,
    processTreeTracker: tracker
  })

  const [stdout, stderr, exit] = await Promise.all([readText(child.stdout), readText(child.stderr), child.exit])
  expect({ stdout, stderr, exit }).toEqual({ stdout: "out", stderr: "err", exit: { code: 0, signal: null } })
  await child.dispose()
  await tracker.dispose()
})

test("owned process exit is independent from inherited output-pipe closure", async () => {
  if (process.platform === "win32") return
  const cwd = await mkdtemp(join(tmpdir(), "zi-owned-process-exit-"))
  const pidPath = join(cwd, "helper.pid")
  const tracker = createProcessTreeTracker()
  const script = `const {spawn}=require('node:child_process');const {writeFileSync}=require('node:fs');const child=spawn(process.execPath,['-e','setTimeout(()=>{},5000)'],{detached:true,stdio:['ignore',1,2]});writeFileSync(${JSON.stringify(
    pidPath
  )},String(child.pid));child.unref()`
  const child = spawnOwnedProcess({
    type: "raw",
    pipeAdapter: "node",
    command: [process.execPath, "-e", script],
    cwd,
    env: process.env,
    processTreeTracker: tracker
  })

  const outputSettled = Promise.all([readText(child.stdout), readText(child.stderr)])
  let helperPid = 0
  try {
    await child.exit
    expect(await settlesWithin(outputSettled, 50)).toBe(false)
    helperPid = Number(await readFile(pidPath, "utf8"))
    process.kill(helperPid, "SIGKILL")
    expect(await settlesWithin(outputSettled, 2_000)).toBe(true)
  } finally {
    if (helperPid > 0) {
      try {
        process.kill(helperPid, "SIGKILL")
      } catch {}
    }
    await child.dispose()
    await tracker.dispose()
    await rm(cwd, { recursive: true, force: true })
  }
})

test("owned protocol processes keep fd3 separate from stdout", async () => {
  const tracker = createProcessTreeTracker()
  const child = spawnOwnedProcess({
    type: "protocol",
    pipeAdapter: "direct",
    command: [process.execPath, "-e", 'require("node:fs").writeSync(3, "protocol"); process.stdout.write("log")'],
    cwd: process.cwd(),
    env: process.env,
    processTreeTracker: tracker
  })

  const [protocol, stdout, exit] = await Promise.all([readText(child.protocol), readText(child.stdout), child.exit])
  expect({ protocol, stdout, exit }).toEqual({ protocol: "protocol", stdout: "log", exit: { code: 0, signal: null } })
  await child.dispose()
  await tracker.dispose()
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
  await child.exit
  await child.dispose()
  expect({ terminations, disposals }).toEqual({ terminations: 1, disposals: 1 })
})

test("owned process commands require one bounded absolute executable", async () => {
  const tracker = createProcessTreeTracker()
  expect(() =>
    spawnOwnedProcess({
      type: "raw",
      pipeAdapter: "direct",
      command: ["node"],
      cwd: process.cwd(),
      env: process.env,
      processTreeTracker: tracker
    })
  ).toThrow("absolute executable")
  await tracker.dispose()
})

async function settlesWithin(operation: Promise<unknown>, timeoutMs: number): Promise<boolean> {
  return Promise.race([operation.then(() => true), Bun.sleep(timeoutMs).then(() => false)])
}

async function readText(stream: NodeJS.ReadableStream): Promise<string> {
  let text = ""
  for await (const chunk of stream) text += Buffer.from(chunk).toString()
  return text
}

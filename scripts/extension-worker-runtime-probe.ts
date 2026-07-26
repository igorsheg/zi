#!/usr/bin/env bun

// PROTOTYPE: delete after the extension-worker runtime ADR selects a production mechanism.

import { chmod, mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { compileStandalone } from "./compile-zi.js"

interface WorkerReport {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
  readonly protocol: string
  readonly killed: boolean
}

const temporary = await mkdtemp(join(tmpdir(), "zi-extension-worker-probe-"))
const executable = join(temporary, process.platform === "win32" ? "zi-probe.exe" : "zi-probe")
const extensionDirectory = join(temporary, "extension")

try {
  await writeFixtures(extensionDirectory)
  const entrypoint = join(temporary, "standalone.ts")
  await Bun.write(entrypoint, standaloneSource())
  await compileStandalone(entrypoint, executable)
  if (process.platform !== "win32") await chmod(executable, 0o755)

  const success = await runParent(executable, "success", join(extensionDirectory, "success.ts"))
  const failure = await runParent(executable, "failure", join(extensionDirectory, "failure.ts"))
  const crash = await runParent(executable, "crash", join(extensionDirectory, "crash.ts"))
  const hang = await runParent(executable, "hang", join(extensionDirectory, "hang.ts"))
  const successProtocol = parseProtocol(success.protocol)
  const failureProtocol = parseProtocol(failure.protocol)

  const checks = {
    releaseShapedCompilation: true,
    selfSpawn: success.exitCode === 0,
    externalTypeScript: successProtocol.status === "loaded",
    asyncFactory: successProtocol.value?.async === true,
    nodeBuiltin: successProtocol.value?.file === "extension fixture",
    localDependency: successProtocol.value?.dependency === "local dependency",
    dedicatedProtocolPipe:
      successProtocol.status === "loaded" &&
      !success.stdout.includes('"status":"loaded"') &&
      !success.stderr.includes('"status":"loaded"'),
    stdoutIsolation: success.stdout === "extension stdout\n",
    stderrIsolation: success.stderr === "extension stderr\n",
    cleanExit: success.exitCode === 0,
    exceptionAttribution:
      failure.exitCode === 0 &&
      failureProtocol.status === "failed" &&
      failureProtocol.source === resolve(extensionDirectory, "failure.ts") &&
      failureProtocol.message === "deliberate extension failure",
    crashContainment: crash.exitCode === 86,
    hangContainment: hang.killed && hang.exitCode !== 0
  }

  console.log(
    JSON.stringify(
      {
        prototype: "self-hosted compiled Bun extension worker",
        platform: `${process.platform}-${process.arch}`,
        bun: Bun.version,
        checks,
        reports: { success, failure, crash, hang }
      },
      null,
      2
    )
  )

  if (Object.values(checks).some(passed => !passed)) process.exitCode = 1
} finally {
  await rm(temporary, { recursive: true, force: true })
}

async function runParent(binary: string, scenario: string, source: string): Promise<WorkerReport> {
  const child = Bun.spawn([binary, "--probe-extension-parent", scenario, source], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "inherit"
  })
  const [exitCode, stdout] = await Promise.all([child.exited, new Response(child.stdout).text()])
  if (exitCode !== 0) throw new Error(`Probe parent failed for ${scenario} with exit code ${exitCode}`)
  const report: unknown = JSON.parse(stdout)
  if (
    !isRecord(report) ||
    typeof report.exitCode !== "number" ||
    typeof report.stdout !== "string" ||
    typeof report.stderr !== "string" ||
    typeof report.protocol !== "string" ||
    typeof report.killed !== "boolean"
  ) {
    throw new Error(`Probe parent returned an invalid report for ${scenario}`)
  }
  return {
    exitCode: report.exitCode,
    stdout: report.stdout,
    stderr: report.stderr,
    protocol: report.protocol,
    killed: report.killed
  }
}

interface ProtocolReport {
  readonly status: string | undefined
  readonly source: string | undefined
  readonly message: string | undefined
  readonly value:
    | {
        readonly async: boolean | undefined
        readonly file: string | undefined
        readonly dependency: string | undefined
      }
    | undefined
}

function parseProtocol(value: string): ProtocolReport {
  if (!value) return { status: undefined, source: undefined, message: undefined, value: undefined }
  const report: unknown = JSON.parse(value)
  if (!isRecord(report)) throw new Error("Extension worker returned an invalid protocol report")
  const result: ProtocolReport = {
    status: typeof report.status === "string" ? report.status : undefined,
    source: typeof report.source === "string" ? report.source : undefined,
    message: typeof report.message === "string" ? report.message : undefined,
    value: undefined
  }
  if (!isRecord(report.value)) return result
  return {
    ...result,
    value: {
      async: typeof report.value.async === "boolean" ? report.value.async : undefined,
      file: typeof report.value.file === "string" ? report.value.file : undefined,
      dependency: typeof report.value.dependency === "string" ? report.value.dependency : undefined
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

async function writeFixtures(directory: string): Promise<void> {
  const dependencyDirectory = join(directory, "node_modules", "zi-extension-probe-dependency")
  await mkdir(dependencyDirectory, { recursive: true })
  await Bun.write(join(directory, "package.json"), `${JSON.stringify({ private: true, type: "module" }, null, 2)}\n`)
  await Bun.write(join(directory, "fixture.txt"), "extension fixture\n")
  await Bun.write(
    join(dependencyDirectory, "package.json"),
    `${JSON.stringify({ name: "zi-extension-probe-dependency", type: "module", exports: "./index.js" }, null, 2)}\n`
  )
  await Bun.write(join(dependencyDirectory, "index.js"), 'export const dependency = "local dependency"\n')
  await Bun.write(
    join(directory, "success.ts"),
    `import { readFile } from "node:fs/promises"
import { dependency } from "zi-extension-probe-dependency"

interface ProbeValue {
  readonly async: true
  readonly file: string
  readonly dependency: string
}

export default async function load(): Promise<ProbeValue> {
  await Promise.resolve()
  console.log("extension stdout")
  console.error("extension stderr")
  return {
    async: true,
    file: (await readFile(new URL("./fixture.txt", import.meta.url), "utf8")).trim(),
    dependency
  }
}
`
  )
  await Bun.write(
    join(directory, "failure.ts"),
    `export default async function load(): Promise<never> {
  throw new Error("deliberate extension failure")
}
`
  )
  await Bun.write(join(directory, "crash.ts"), `export default function load(): never { process.exit(86) }\n`)
  await Bun.write(join(directory, "hang.ts"), `export default function load(): never { while (true) {} }\n`)
}

function standaloneSource(): string {
  const mainModule = resolve(import.meta.dirname, "../packages/cli/src/main.ts")
  return `import { spawn } from "node:child_process"
import { closeSync, writeFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { defaultCliArgv, main } from ${JSON.stringify(mainModule)}

const parentIndex = process.argv.indexOf("--probe-extension-parent")
const workerIndex = process.argv.indexOf("--probe-extension-worker")

if (workerIndex >= 0) {
  await runWorker(process.argv[workerIndex + 1])
} else if (parentIndex >= 0) {
  await runParent(process.argv[parentIndex + 1], process.argv[parentIndex + 2])
} else {
  process.exitCode = await main(defaultCliArgv())
}

async function runWorker(source) {
  let report
  try {
    const extension = await import(pathToFileURL(source).href)
    const value = await extension.default()
    report = { status: "loaded", source, value }
  } catch (cause) {
    report = {
      status: "failed",
      source,
      message: cause instanceof Error ? cause.message : String(cause)
    }
  }
  writeFileSync(3, JSON.stringify(report))
  closeSync(3)
}

async function runParent(scenario, source) {
  const child = spawn(process.execPath, ["--probe-extension-worker", source], {
    stdio: ["ignore", "pipe", "pipe", "pipe"],
    windowsHide: true
  })
  const protocolStream = child.stdio[3]
  if (!child.stdout || !child.stderr || !protocolStream) {
    throw new Error("Node-compatible spawn did not create the dedicated protocol pipe")
  }
  const protocolPromise = readStream(protocolStream)
  const stdoutPromise = readStream(child.stdout)
  const stderrPromise = readStream(child.stderr)
  const exitCodePromise = new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("close", (code, signal) => resolve(code ?? (signal ? 1 : 0)))
  })
  let killed = false
  let timeout
  if (scenario === "hang") {
    timeout = setTimeout(() => {
      killed = child.kill("SIGKILL")
    }, 500)
  }
  const [exitCode, stdout, stderr, protocol] = await Promise.all([
    exitCodePromise,
    stdoutPromise,
    stderrPromise,
    protocolPromise
  ])
  if (timeout) clearTimeout(timeout)
  console.log(JSON.stringify({ exitCode, stdout, stderr, protocol, killed }))
}

async function readStream(stream) {
  const chunks = []
  for await (const chunk of stream) chunks.push(Buffer.from(chunk))
  return Buffer.concat(chunks).toString("utf8")
}
`
}

import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve as resolvePath } from "node:path"

import type { AgentMessage, AgentRuntime, AgentSessionRuntime, CreateAgentRuntimeOptions } from "@with-zi/coding-agent"
import { codeModeWorkerArgument } from "@with-zi/coding-agent/internal/code-mode-worker-mode"
import { extensionWorkerArgument } from "@with-zi/coding-agent/internal/extension-worker"
import {
  internalSubagentApiKeyEnvironment,
  internalSubagentDepthEnvironment
} from "@with-zi/coding-agent/internal/subagent-invocation"
import {
  createModels,
  createTestAgentRuntime,
  createTestAgentSessionRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall
} from "@with-zi/coding-agent/testing"

import {
  bunWindowsDefaultMaxListeners,
  createProcessHost,
  currentZiCommand,
  defaultCliArgv,
  interactiveAcceptanceArgument
} from "../src/main.js"
import {
  helpText,
  maxCliStdinBytes,
  resolveAppMode,
  runCli,
  versionText,
  type CliHost,
  type CliSignal
} from "../src/run.js"

const cliTestHome = join(tmpdir(), `zi-cli-${process.pid}`)

test("spawned help stays stdout-clean and never initializes a terminal", async () => {
  const child = Bun.spawn([process.execPath, join(import.meta.dir, "../src/main.ts"), "--help"], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe"
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])

  expect(exitCode).toBe(0)
  expect(stdout).toBe(helpText)
  expect(stderr).toBe("")
  expect(stdout).not.toContain("\u001b")
  expect(stdout).not.toContain("      --session file")
})

test("spawned version stays stdout-clean and never initializes a terminal", async () => {
  const child = Bun.spawn([process.execPath, join(import.meta.dir, "../src/main.ts"), "--version"], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe"
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])

  expect({ exitCode, stdout, stderr }).toEqual({ exitCode: 0, stdout: versionText, stderr: "" })
})

test("spawned text and JSON modes own the same explicit extension lifecycle", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-cli-extension-"))
  const cwd = join(root, "project")
  const agentDir = join(root, "agent")
  const extension = join(root, "extension.ts")
  const lifecycle = join(root, "lifecycle.log")
  await mkdir(cwd, { recursive: true })
  await writeFile(
    extension,
    `import { appendFileSync } from "node:fs"
export default function (zi): void {
  console.log("extension must not reach stdout")
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecycle)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecycle)}, "stop:" + event.reason + "\\n"))
}
`
  )

  try {
    for (const mode of ["text", "json"]) {
      // Each mode receives the same isolated lifecycle file in deterministic order.
      // oxlint-disable-next-line eslint/no-await-in-loop
      await writeFile(lifecycle, "")
      const child = Bun.spawn(
        [
          process.execPath,
          join(import.meta.dir, "../src/main.ts"),
          "--cwd",
          cwd,
          "--agent-dir",
          agentDir,
          "--no-session",
          "--extension",
          extension,
          "--mode",
          mode,
          "prompt"
        ],
        {
          env: { PATH: process.env.PATH ?? "", HOME: root, USERPROFILE: root },
          stdin: "pipe",
          stdout: "pipe",
          stderr: "pipe"
        }
      )
      void child.stdin.end()
      // Keep each process lifetime separate so its lifecycle evidence cannot interleave.
      // oxlint-disable-next-line eslint/no-await-in-loop
      const [exitCode, stdout] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text()
      ])
      expect(exitCode).toBe(1)
      expect(stdout).not.toContain("extension must not reach stdout")
      // oxlint-disable-next-line eslint/no-await-in-loop
      expect(await readFile(lifecycle, "utf8")).toBe("start:startup\nstop:quit\n")
    }
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("CLI argument defaults handle Bun scripts and compiled executables", () => {
  expect(defaultCliArgv(["/usr/local/bin/bun", "/work/packages/cli/src/main.ts", "-V"])).toEqual(["-V"])
  expect(defaultCliArgv(["bun", "/$bunfs/root/standalone", "-V"])).toEqual(["-V"])
  expect(defaultCliArgv(["bun", "-V"])).toEqual(["-V"])
  expect(defaultCliArgv(["C:\\tools\\zi.exe", "-V"])).toEqual(["-V"])
  expect(defaultCliArgv(["C:\\tools\\zi.exe", "B:\\~BUN\\root\\standalone", codeModeWorkerArgument])).toEqual([
    codeModeWorkerArgument
  ])
  expect(defaultCliArgv(["C:\\tools\\zi.exe", "B:\\~BUN\\root\\standalone", extensionWorkerArgument])).toEqual([
    extensionWorkerArgument
  ])
  expect(defaultCliArgv(["C:\\tools\\zi.exe", "B:\\~BUN\\root\\standalone", "--mode", "rpc"])).toEqual([
    "--mode",
    "rpc"
  ])
  expect(defaultCliArgv(["C:\\tools\\zi.exe", "--mode", "interactive", interactiveAcceptanceArgument])).toEqual([
    "--mode",
    "interactive",
    interactiveAcceptanceArgument
  ])
  expect(currentZiCommand([process.execPath, "/work/packages/cli/src/main.ts"])).toEqual([
    process.execPath,
    resolvePath("/work/packages/cli/src/main.ts")
  ])
  expect(currentZiCommand([process.execPath, "/$bunfs/root/standalone"])).toEqual([process.execPath])
  expect(currentZiCommand([process.execPath, "B:\\~BUN\\root\\standalone.ts"])).toEqual([process.execPath])
})

test("the pinned Bun runtime raises only the Windows listener warning threshold", () => {
  expect(bunWindowsDefaultMaxListeners("win32", "1.3.14")).toBe(32)
  expect(bunWindowsDefaultMaxListeners("win32", "1.3.15")).toBeUndefined()
  expect(bunWindowsDefaultMaxListeners("linux", "1.3.14")).toBeUndefined()
})

test("the internal acceptance host changes only CLI TTY admission facts", () => {
  expect(createProcessHost(true)).toMatchObject({ stdinIsTTY: true, stdoutIsTTY: true })
})

test("the child process host captures then scrubs its private credential", () => {
  const previousDepth = process.env[internalSubagentDepthEnvironment]
  const previousApiKey = process.env[internalSubagentApiKeyEnvironment]
  process.env[internalSubagentDepthEnvironment] = "1"
  process.env[internalSubagentApiKeyEnvironment] = "child-secret"
  try {
    const host = createProcessHost(false)
    expect(host.env[internalSubagentApiKeyEnvironment]).toBe("child-secret")
    expect(process.env[internalSubagentApiKeyEnvironment]).toBeUndefined()
  } finally {
    if (previousDepth === undefined) delete process.env[internalSubagentDepthEnvironment]
    else process.env[internalSubagentDepthEnvironment] = previousDepth
    if (previousApiKey === undefined) delete process.env[internalSubagentApiKeyEnvironment]
    else process.env[internalSubagentApiKeyEnvironment] = previousApiKey
  }
})

test("CLI mode resolution keeps explicit protocols and otherwise follows TTY facts", () => {
  expect(resolveAppMode("json", true, true)).toBe("json")
  expect(resolveAppMode("text", true, true)).toBe("text")
  expect(resolveAppMode("rpc", false, false)).toBe("rpc")
  expect(resolveAppMode("auto", false, true)).toBe("text")
  expect(resolveAppMode("auto", true, false)).toBe("text")
  expect(resolveAppMode("auto", true, true)).toBe("interactive")
  expect(resolveAppMode("interactive", true, true)).toBe("interactive")
  expect(() => resolveAppMode("interactive", false, true)).toThrow("Interactive mode requires TTY stdin and stdout")
  expect(() => resolveAppMode("interactive", true, false)).toThrow("Interactive mode requires TTY stdin and stdout")
})

test("text mode writes final output without loading the TUI and disposes its runtime", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  let runtime: AgentRuntime | undefined
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  let interactiveLoads = 0
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    async createRuntime(options) {
      receivedOptions = options
      runtime = await createTestAgentRuntime({ ...options, models })
      return runtime
    },
    async runInteractive() {
      interactiveLoads++
    }
  })

  const exitCode = await runCli(
    [
      "-p",
      "--no-session",
      "--api-key",
      "cli-secret",
      "--model",
      `${faux.getModel().provider}/${faux.getModel().id}`,
      "start"
    ],
    host
  )
  expect({ exitCode, output, errors }).toEqual({ exitCode: 0, output: ["done\n"], errors: [] })
  expect(receivedOptions).toMatchObject({
    session: { type: "new", persist: false },
    apiKey: "cli-secret",
    extensionMode: "text"
  })
  expect(output.join("")).not.toContain("cli-secret")
  expect(interactiveLoads).toBe(0)
  expect(() => runtime?.session.prompt("disposed")).toThrow("AgentSession is disposed")
})

test("a depth-one child admits its scrubbed private credential without a CLI argument", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    env: { [internalSubagentDepthEnvironment]: "1", [internalSubagentApiKeyEnvironment]: "child-secret" },
    async createRuntime(options) {
      receivedOptions = options
      return createTestAgentRuntime({ ...options, models })
    }
  })

  const model = `${faux.getModel().provider}/${faux.getModel().id}`
  const exitCode = await runCli(["-p", "--no-session", "--model", model, "start"], host)

  expect({ exitCode, output, errors }).toEqual({ exitCode: 0, output: ["done\n"], errors: [] })
  expect(receivedOptions).toMatchObject({ apiKey: "child-secret", internalSubagentDepth: 1 })
})

test("environment defaults resolve once before runtime construction and CLI values win", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    cwd: "/process-cwd",
    env: {
      ZI_MODE: "text",
      ZI_AGENT_DIR: "/env-agent",
      ZI_SESSION_DIR: "/env-sessions",
      ZI_DEFAULT_MODEL: "ignored/model",
      ZI_DEFAULT_THINKING: "low"
    },
    async createRuntime(options) {
      receivedOptions = options
      return createTestAgentRuntime({
        ...options,
        cwd: "/work",
        agentDir: "/agent",
        session: { type: "new", persist: false },
        models
      })
    }
  })

  const model = `${faux.getModel().provider}/${faux.getModel().id}`
  const exitCode = await runCli(
    [
      "--model",
      model,
      "--thinking",
      "high",
      "--system-prompt",
      "Act as a reviewer",
      "--append-system-prompt",
      "Use concise findings",
      "start"
    ],
    host
  )

  expect({ exitCode, output, errors }).toEqual({ exitCode: 0, output: ["done\n"], errors: [] })
  expect(receivedOptions).toMatchObject({
    cwd: resolvePath("/process-cwd"),
    agentDir: resolvePath("/env-agent"),
    sessionDir: resolvePath("/env-sessions"),
    model,
    thinkingLevel: "high",
    systemPrompt: "Act as a reviewer",
    appendSystemPrompt: ["Use concise findings"]
  })
})

test("environment model existence remains runtime-owned after piped stdin", async () => {
  const models = createModels()
  let reads = 0
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    stdin: "piped",
    stdinIsTTY: false,
    env: { ZI_MODE: "text", ZI_DEFAULT_MODEL: "missing/model" },
    onReadStdin() {
      reads++
    },
    createRuntime: options => createTestAgentRuntime({ ...options, models })
  })

  expect(await runCli([], host)).toBe(1)
  expect(reads).toBe(1)
  expect(output).toEqual([])
  expect(errors).toEqual(["Unknown model: missing/model. Use provider/model-id.\n"])
})

test("headless startup writes model fallback diagnostics to stderr", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    async createRuntime(options) {
      const runtime = await createTestAgentRuntime({ ...options, models })
      return {
        ...runtime,
        bootstrapDiagnostic: {
          type: "model_fallback",
          savedModel: { provider: "removed", modelId: "old" },
          fallbackModel: { provider: faux.getModel().provider, modelId: faux.getModel().id },
          message: `Could not restore model removed/old. Using ${faux.getModel().provider}/${faux.getModel().id}.`
        }
      }
    }
  })

  const exitCode = await runCli(["-p", "--model", `${faux.getModel().provider}/${faux.getModel().id}`, "start"], host)

  expect(exitCode).toBe(0)
  expect(output).toEqual(["done\n"])
  expect(errors).toEqual([
    `Warning: Could not restore model removed/old. Using ${faux.getModel().provider}/${faux.getModel().id}.\n`
  ])
})

test("headless startup reports source-attributed extension diagnostics on stderr", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({ output, errors, createRuntime: options => createTestAgentRuntime({ ...options, models }) })

  const exitCode = await runCli(
    [
      "-p",
      "--extension",
      "missing-extension.ts",
      "--model",
      `${faux.getModel().provider}/${faux.getModel().id}`,
      "start"
    ],
    host
  )

  expect(exitCode).toBe(0)
  expect(output).toEqual(["done\n"])
  expect(errors).toEqual([
    `Warning: (extension ${resolvePath("/work/missing-extension.ts")}) Extension path does not exist\n`
  ])
})

test("headless startup reports excluded project configuration without contaminating stdout", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    async createRuntime(options) {
      const runtime = await createTestAgentRuntime({ ...options, models })
      return {
        ...runtime,
        projectTrust: {
          type: "unresolved",
          cwd: options.cwd,
          diagnostic: {
            cwd: options.cwd,
            path: join(options.cwd, ".zi"),
            message: `Project configuration trust is unresolved and was ignored: ${join(options.cwd, ".zi")}`
          }
        }
      }
    }
  })

  const exitCode = await runCli(["-p", "--model", `${faux.getModel().provider}/${faux.getModel().id}`, "start"], host)

  expect(exitCode).toBe(0)
  expect(output).toEqual(["done\n"])
  expect(errors).toEqual([
    `Warning: Project configuration trust is unresolved and was ignored: ${join(resolvePath("/work"), ".zi")}\n`
  ])
})

test("JSON mode emits only parseable JSONL without loading the TUI", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("done")])
  const output: string[] = []
  const errors: string[] = []
  let interactiveLoads = 0
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  const host = testHost({
    output,
    errors,
    createRuntime: options => {
      receivedOptions = options
      return createTestAgentRuntime({ ...options, models })
    },
    async runInteractive() {
      interactiveLoads++
    }
  })

  const exitCode = await runCli(
    ["--mode", "json", "--model", `${faux.getModel().provider}/${faux.getModel().id}`, "start"],
    host
  )
  expect(exitCode).toBe(0)
  expect(errors).toEqual([])
  expect(interactiveLoads).toBe(0)
  expect(receivedOptions?.extensionMode).toBe("json")
  expect(output.length).toBeGreaterThan(1)
  expect(output.every(line => line.endsWith("\n") && JSON.parse(line) !== undefined)).toBe(true)
})

test("custom extension tools preserve text and JSON stdout protocols", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-cli-extension-tool-"))
  const extensionPath = join(root, "extension.ts")
  await writeFile(
    extensionPath,
    `import { Schema, type ExtensionAPI } from "@with-zi/extension-api"
export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "cli_echo",
    description: "Echo a CLI value",
    parameters: Schema.object({ value: Schema.string() }),
    execute: ({ value }) => "tool:" + value
  })
}
`
  )
  const cli = resolvePath(import.meta.dirname, "../src/main.ts")

  try {
    for (const mode of ["text", "json"] as const) {
      const models = createModels()
      const faux = fauxProvider()
      models.setProvider(faux.provider)
      faux.setResponses([
        fauxAssistantMessage(fauxToolCall("cli_echo", { value: mode }, { id: `cli-tool-${mode}` }), {
          stopReason: "toolUse"
        }),
        fauxAssistantMessage(fauxText(`finished:${mode}`))
      ])
      const output: string[] = []
      const errors: string[] = []
      const host = testHost({
        cwd: root,
        output,
        errors,
        createRuntime: options =>
          createTestAgentRuntime({ ...options, extensionWorkerCommand: [process.execPath, cli], models })
      })

      // Each mode owns and disposes its runtime before the next starts.
      // oxlint-disable-next-line no-await-in-loop
      const exitCode = await runCli(
        [
          "--mode",
          mode,
          "--no-session",
          "--extension",
          extensionPath,
          "--model",
          `${faux.getModel().provider}/${faux.getModel().id}`,
          "use the custom tool"
        ],
        host
      )

      expect(exitCode).toBe(0)
      expect(errors).toEqual([])
      if (mode === "text") {
        expect(output).toEqual(["finished:text\n"])
      } else {
        expect(output.every(line => JSON.parse(line) !== undefined)).toBe(true)
        expect(output.join("")).toContain(`"toolName":"cli_echo"`)
        expect(output.join("")).toContain(`"text":"tool:json"`)
      }
    }
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}, 10_000)

test("piped stdin becomes the first prompt before positional messages", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("final")])
  let runtime: AgentRuntime | undefined
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    stdin: "piped",
    stdinIsTTY: false,
    async createRuntime(options) {
      runtime = await createTestAgentRuntime({ ...options, models })
      return runtime
    }
  })

  const exitCode = await runCli(["--model", `${faux.getModel().provider}/${faux.getModel().id}`, "argument"], host)
  expect(exitCode).toBe(0)
  expect(output).toEqual(["final\n"])
  expect(errors).toEqual([])
  expect(runtime?.session.messages.filter(message => message.role === "user").map(userText)).toEqual([
    "piped",
    "argument"
  ])
})

test("continue-recent reaches runtime construction as a distinct headless intent", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("continued")])
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    async createRuntime(options) {
      receivedOptions = options
      const testOptions = { ...options, session: { type: "new" as const, persist: false } }
      return createTestAgentRuntime({ ...testOptions, models })
    }
  })

  const exitCode = await runCli(
    ["-p", "--continue", "--model", `${faux.getModel().provider}/${faux.getModel().id}`, "continue"],
    host
  )

  expect(exitCode).toBe(0)
  expect(receivedOptions?.session).toEqual({ type: "continue" })
  expect(output).toEqual(["continued\n"])
  expect(errors).toEqual([])
})

test("TTY mode delegates positional prompts only to the dynamic interactive loader", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const output: string[] = []
  const errors: string[] = []
  let initialMessages: readonly string[] = []
  let sessionRuntime: AgentSessionRuntime | undefined
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  const host = testHost({
    output,
    errors,
    createRuntime: options => createTestAgentRuntime({ ...options, models }),
    async createSessionRuntime(options) {
      receivedOptions = options
      sessionRuntime = await createTestAgentSessionRuntime({ ...options, models })
      return sessionRuntime
    },
    async runInteractive(_runtime, messages) {
      initialMessages = messages
    }
  })

  const exitCode = await runCli(
    ["--model", `${faux.getModel().provider}/${faux.getModel().id}`, "interactive prompt"],
    host
  )
  expect(exitCode).toBe(0)
  expect(initialMessages).toEqual(["interactive prompt"])
  expect(receivedOptions?.extensionMode).toBe("interactive")
  expect(() => sessionRuntime?.session).toThrow("AgentSessionRuntime is disposed")
  expect(output).toEqual([])
  expect(errors).toEqual([])
})

test("RPC mode delegates protocol input without reading it as a prompt", async () => {
  const models = createModels()
  const output: string[] = []
  const errors: string[] = []
  let stdinReads = 0
  let rpcRuns = 0
  let runtime: AgentRuntime | undefined
  let receivedOptions: CreateAgentRuntimeOptions | undefined
  const host = testHost({
    output,
    errors,
    stdinIsTTY: false,
    stdoutIsTTY: false,
    onReadStdin() {
      stdinReads++
    },
    async createRuntime(options) {
      receivedOptions = options
      runtime = await createTestAgentRuntime({ ...options, models })
      return runtime
    },
    async runRpc(_session, signal) {
      rpcRuns++
      expect(signal.aborted).toBe(false)
      return { type: "eof" }
    }
  })

  expect(await runCli(["--mode", "rpc", "--no-session"], host)).toBe(0)
  expect({ stdinReads, rpcRuns }).toEqual({ stdinReads: 0, rpcRuns: 1 })
  expect(receivedOptions?.extensionMode).toBe("rpc")
  expect(() => runtime?.session.prompt("disposed")).toThrow("AgentSession is disposed")
  expect(output).toEqual([])
  expect(errors).toEqual([])
})

test("RPC signal cancellation keeps process exit and session disposal with the CLI", async () => {
  const models = createModels()
  const output: string[] = []
  const errors: string[] = []
  const signals: TestSignalControl = { listener: undefined, removes: 0 }
  const started = deferred<void>()
  let runtime: AgentRuntime | undefined
  const host = testHost({
    output,
    errors,
    signals,
    async createRuntime(options) {
      runtime = await createTestAgentRuntime({ ...options, models })
      return runtime
    },
    async runRpc(_session, signal) {
      started.resolve()
      await new Promise<void>(resolve => signal.addEventListener("abort", () => resolve(), { once: true }))
      return { type: "cancelled" }
    }
  })

  const running = runCli(["--mode", "rpc", "--no-session"], host)
  await started.promise
  signals.listener?.("SIGTERM")

  expect(await running).toBe(143)
  expect(signals.removes).toBe(1)
  expect(() => runtime?.session.prompt("disposed")).toThrow("AgentSession is disposed")
  expect(output).toEqual([])
  expect(errors).toEqual([])
})

test("RPC mode rejects positional prompts before runtime construction", async () => {
  const output: string[] = []
  const errors: string[] = []
  let runtimeCreates = 0
  const host = testHost({
    output,
    errors,
    async createRuntime() {
      runtimeCreates++
      throw new Error("unexpected runtime")
    }
  })

  expect(await runCli(["--mode", "rpc", "prompt"], host)).toBe(1)
  expect(runtimeCreates).toBe(0)
  expect(errors).toEqual(["RPC mode accepts input only through its JSONL protocol\n"])
})

test("missing models fail on stderr without contaminating stdout", async () => {
  const models = createModels()
  const output: string[] = []
  const errors: string[] = []
  let interactiveLoads = 0
  const host = testHost({
    output,
    errors,
    createRuntime: options => createTestAgentRuntime({ ...options, models }),
    async runInteractive() {
      interactiveLoads++
    }
  })

  expect(await runCli(["-p", "start"], host)).toBe(1)
  expect(output).toEqual([])
  expect(errors).toEqual(["No model selected. Use /login, then /model.\n"])
  expect(interactiveLoads).toBe(0)
})

test("help exits without reading stdin, creating a runtime, or loading the TUI", async () => {
  let reads = 0
  let runtimeCreates = 0
  let interactiveLoads = 0
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    env: { ZI_MODE: "invalid-but-irrelevant-to-help" },
    onReadStdin() {
      reads++
    },
    async createRuntime() {
      runtimeCreates++
      throw new Error("unexpected runtime")
    },
    async runInteractive() {
      interactiveLoads++
    }
  })

  expect(await runCli(["--help"], host)).toBe(0)
  expect(output).toEqual([helpText])
  expect(errors).toEqual([])
  expect(reads).toBe(0)
  expect(runtimeCreates).toBe(0)
  expect(interactiveLoads).toBe(0)
})

test("oversized piped stdin is rejected before runtime creation", async () => {
  let runtimeCreates = 0
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    stdin: "x".repeat(maxCliStdinBytes + 1),
    stdinIsTTY: false,
    async createRuntime() {
      runtimeCreates++
      throw new Error("unexpected runtime")
    }
  })

  expect(await runCli([], host)).toBe(1)
  expect(runtimeCreates).toBe(0)
  expect(output).toEqual([])
  expect(errors).toEqual([`Piped stdin cannot exceed ${maxCliStdinBytes} bytes\n`])
})

test("headless admission failures do not create a runtime or load the TUI", async () => {
  let runtimeCreates = 0
  let interactiveLoads = 0
  const output: string[] = []
  const errors: string[] = []
  const host = testHost({
    output,
    errors,
    async createRuntime() {
      runtimeCreates++
      throw new Error("unexpected runtime")
    },
    async runInteractive() {
      interactiveLoads++
    }
  })

  expect(await runCli(["-p"], host)).toBe(1)
  expect(runtimeCreates).toBe(0)
  expect(interactiveLoads).toBe(0)
  expect(output).toEqual([])
  expect(errors).toEqual(["Headless mode requires a prompt or piped stdin\n"])
})

for (const [signal, exitCode] of [
  ["SIGHUP", 129],
  ["SIGTERM", 143]
] as const) {
  test(`${signal} aborts headless work, removes listeners, and disposes the session`, async () => {
    const models = createModels()
    const faux = fauxProvider()
    models.setProvider(faux.provider)
    const started = deferred<void>()
    faux.setResponses([
      async (_context, request) => {
        started.resolve()
        await new Promise<void>(resolve => request?.signal?.addEventListener("abort", () => resolve(), { once: true }))
        return fauxAssistantMessage("partial", { stopReason: "aborted" })
      }
    ])
    let runtime: AgentRuntime | undefined
    const signals: TestSignalControl = { listener: undefined, removes: 0 }
    const output: string[] = []
    const errors: string[] = []
    const host = testHost({
      output,
      errors,
      signals,
      async createRuntime(options) {
        runtime = await createTestAgentRuntime({ ...options, models })
        return runtime
      }
    })

    const running = runCli(["-p", "--model", `${faux.getModel().provider}/${faux.getModel().id}`, "start"], host)
    await started.promise
    signals.listener?.(signal)

    expect(await running).toBe(exitCode)
    expect(output).toEqual([])
    expect(errors).toEqual(["Request was aborted\n"])
    expect(signals.listener).toBeUndefined()
    expect(signals.removes).toBe(1)
    expect(() => runtime?.session.prompt("disposed")).toThrow("AgentSession is disposed")
  })
}

interface TestSignalControl {
  listener: ((signal: CliSignal) => void) | undefined
  removes: number
}

interface TestHostOptions {
  readonly output: string[]
  readonly errors: string[]
  readonly createRuntime: CliHost["createRuntime"]
  readonly cwd?: string
  readonly home?: string
  readonly env?: Readonly<Record<string, string | undefined>>
  readonly createSessionRuntime?: CliHost["createSessionRuntime"]
  readonly runInteractive?: CliHost["runInteractive"]
  readonly runRpc?: CliHost["runRpc"]
  readonly stdin?: string
  readonly stdinIsTTY?: boolean
  readonly stdoutIsTTY?: boolean
  readonly signals?: TestSignalControl
  readonly onReadStdin?: () => void
}

function userText(message: AgentMessage): string {
  if (message.role !== "user") throw new Error("Expected user message")
  return typeof message.content === "string"
    ? message.content
    : message.content
        .filter(content => content.type === "text")
        .map(content => content.text)
        .join("")
}

function testHost(options: TestHostOptions): CliHost {
  return {
    cwd: options.cwd ?? "/work",
    home: options.home ?? cliTestHome,
    env: options.env ?? {},
    stdinIsTTY: options.stdinIsTTY ?? true,
    stdoutIsTTY: options.stdoutIsTTY ?? true,
    extensionWorkerCommand: Object.freeze([process.execPath]),
    codeModeWorkerCommand: Object.freeze([process.execPath]),
    async readStdin() {
      options.onReadStdin?.()
      return options.stdin
    },
    async writeStdout(chunk) {
      options.output.push(chunk)
    },
    async writeStderr(chunk) {
      options.errors.push(chunk)
    },
    createRuntime: options.createRuntime,
    createSessionRuntime:
      options.createSessionRuntime ??
      (async () => {
        throw new Error("unexpected interactive runtime")
      }),
    runInteractive: options.runInteractive ?? (async () => {}),
    runRpc:
      options.runRpc ??
      (async () => {
        throw new Error("unexpected RPC mode")
      }),
    onSignal(listener: (signal: CliSignal) => void) {
      if (options.signals) options.signals.listener = listener
      return () => {
        if (!options.signals) return
        if (options.signals.listener === listener) options.signals.listener = undefined
        options.signals.removes++
      }
    }
  }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

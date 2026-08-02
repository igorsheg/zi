import { expect, test } from "bun:test"
import { spawn } from "node:child_process"
import { chmod, mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { delimiter, join, resolve } from "node:path"
import { pathToFileURL } from "node:url"

import {
  ExtensionProtocolDecoder,
  type WorkerMessage,
  encodeExtensionProtocolFrame,
  extensionProtocolVersion,
  validateWorkerMessage
} from "../packages/coding-agent/src/extensions/protocol.js"
import { extensionApiModuleSource } from "../packages/coding-agent/src/extensions/public-api-module.js"
import { extensionWorkerArgument } from "../packages/coding-agent/src/extensions/worker-entry.js"
import { runCodeModeAcceptance } from "./code-mode-acceptance.js"
import { assertPinnedBunVersion, compileStandalone } from "./compile-zi.js"
import { runExtensionCustomToolAcceptance } from "./extension-custom-tool-acceptance.js"

test("standalone compilation requires the workspace-pinned Bun runtime", () => {
  expect(() => assertPinnedBunVersion("1.3.5", "bun@1.3.14")).toThrow("Zi builds require Bun 1.3.14; running 1.3.5")
  expect(() => assertPinnedBunVersion("1.3.14", "bun@1.3.14")).not.toThrow()
  expect(() => assertPinnedBunVersion("1.3.14", "npm@11.4.2")).toThrow("packageManager must pin Bun exactly")
})

test("the compiled Zi executable runs its dedicated internal worker protocols", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "zi-compiled-extension-worker-"))
  const executable = join(temporary, process.platform === "win32" ? "zi.exe" : "zi")
  const extension = join(temporary, "extension.ts")
  const lifecycle = join(temporary, "lifecycle.log")
  const exampleExtension = resolve(import.meta.dirname, "../examples/extensions/custom-tool/index.ts")
  const durableExtension = resolve(import.meta.dirname, "../examples/extensions/durable-counter/index.ts")
  let child: ReturnType<typeof spawn> | undefined

  try {
    await Bun.write(
      extension,
      `
import { appendFileSync } from "node:fs"
import type { ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  console.log("compiled worker stdout")
  console.error("compiled worker stderr")
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecycle)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecycle)}, "stop:" + event.reason + "\\n"))
}
`
    )
    await compileZiInSubprocess(executable)
    if (process.platform !== "win32") await chmod(executable, 0o755)
    const gitInit = Bun.spawnSync(["git", "init", "--quiet"], { cwd: temporary })
    if (gitInit.exitCode !== 0) throw new Error(new TextDecoder().decode(gitInit.stderr))
    const publicNodeModules = join(temporary, "public-api", "node_modules")
    const publicApi = join(publicNodeModules, "@with-zi", "extension-api")
    await mkdir(publicApi, { recursive: true })
    await Bun.write(
      join(publicApi, "package.json"),
      JSON.stringify({ name: "@with-zi/extension-api", type: "module", exports: "./index.js" })
    )
    await Bun.write(join(publicApi, "index.js"), extensionApiModuleSource)

    child = spawn(executable, [extensionWorkerArgument], {
      cwd: temporary,
      env: {
        ...process.env,
        NODE_PATH: process.env.NODE_PATH
          ? `${publicNodeModules}${delimiter}${process.env.NODE_PATH}`
          : publicNodeModules
      },
      stdio: ["pipe", "pipe", "pipe", "pipe"],
      windowsHide: true
    })
    const protocolOutput = child.stdio[3]
    if (!child.stdin || !child.stdout || !child.stderr || !protocolOutput) {
      throw new Error("Compiled extension worker did not expose its protocol and log pipes")
    }

    const stdout = readNodeStream(child.stdout)
    const stderr = readNodeStream(child.stderr)
    const protocolMessages: WorkerMessage[] = []
    let compiledCommandResult: string | undefined
    let compiledToolResult: unknown
    let compiledCounterResult: unknown
    let compiledCustomMessage: string | undefined
    const protocol = new Promise<void>((resolveProtocol, rejectProtocol) => {
      let completed = false
      const decoder = new ExtensionProtocolDecoder(validateWorkerMessage)
      const receive = (message: WorkerMessage): void => {
        protocolMessages.push(message)
        if (message.type === "fatal") {
          rejectProtocol(new Error(message.diagnostic.message))
          return
        }
        if (message.type === "ready") {
          if (
            !message.commands.some(command => command.name === "counter") ||
            !message.tools.some(tool => tool.name === "repository_status") ||
            !message.tools.some(tool => tool.name === "increment_counter")
          ) {
            rejectProtocol(
              new Error(
                `Compiled worker omitted a canonical extension contribution: ${JSON.stringify(message.extensions)}`
              )
            )
            return
          }
          child!.stdin!.write(
            encodeExtensionProtocolFrame({ type: "session_start", generation: 1, requestId: 1, reason: "startup" })
          )
          return
        }
        if (message.type === "custom_entries_get") {
          child!.stdin!.write(
            encodeExtensionProtocolFrame({
              type: "custom_entries_result",
              generation: 1,
              requestId: message.requestId,
              entries: []
            })
          )
          return
        }
        if (message.type === "settled" && message.requestId === 1) {
          child!.stdin!.write(
            encodeExtensionProtocolFrame({
              type: "command_invoke",
              generation: 1,
              requestId: 2,
              name: "counter",
              arguments: "show"
            })
          )
          return
        }
        if (message.type === "command_result" && message.requestId === 2) {
          compiledCommandResult = message.message
          child!.stdin!.write(
            encodeExtensionProtocolFrame({
              type: "tool_invoke",
              generation: 1,
              requestId: 3,
              name: "increment_counter",
              arguments: {}
            })
          )
          return
        }
        if (message.type === "custom_entry_append") {
          child!.stdin!.write(
            encodeExtensionProtocolFrame({
              type: "custom_entry_result",
              generation: 1,
              requestId: message.requestId,
              entry: {
                id: "compiled-counter-entry",
                timestamp: new Date(0).toISOString(),
                customType: message.customType,
                ...(message.data === undefined ? {} : { data: message.data })
              }
            })
          )
          return
        }
        if (message.type === "custom_message_send") {
          compiledCustomMessage = typeof message.message.content === "string" ? message.message.content : undefined
          child!.stdin!.write(
            encodeExtensionProtocolFrame({ type: "custom_message_result", generation: 1, requestId: message.requestId })
          )
          return
        }
        if (message.type === "tool_result" && message.requestId === 3) {
          compiledCounterResult = message.value
          child!.stdin!.write(
            encodeExtensionProtocolFrame({
              type: "tool_invoke",
              generation: 1,
              requestId: 4,
              name: "repository_status",
              arguments: {}
            })
          )
          return
        }
        if (message.type === "tool_result" && message.requestId === 4) {
          compiledToolResult = message.value
          child!.stdin!.write(
            encodeExtensionProtocolFrame({ type: "session_shutdown", generation: 1, requestId: 5, reason: "quit" })
          )
          return
        }
        if (message.type === "settled" && message.requestId === 5) {
          child!.stdin!.write(encodeExtensionProtocolFrame({ type: "stop", generation: 1, requestId: 6 }))
          return
        }
        if (message.type === "settled" && message.requestId === 6) {
          completed = true
          resolveProtocol()
        }
      }
      protocolOutput.on("data", chunk => {
        try {
          for (const message of decoder.push(chunk)) receive(message)
        } catch (cause) {
          rejectProtocol(cause)
        }
      })
      protocolOutput.on("error", rejectProtocol)
      protocolOutput.on("end", () => {
        if (!completed) rejectProtocol(new Error("Compiled extension worker closed its protocol pipe early"))
      })
    })

    child.stdin.write(
      encodeExtensionProtocolFrame({
        type: "initialize",
        protocolVersion: extensionProtocolVersion,
        generation: 1,
        plan: {
          cwd: temporary,
          sources: [
            {
              id: "compiled-extension",
              declaredPath: extension,
              entryPath: extension,
              scope: "temporary",
              origin: "cli"
            },
            {
              id: "compiled-custom-tool-example",
              declaredPath: exampleExtension,
              entryPath: exampleExtension,
              scope: "temporary",
              origin: "cli"
            },
            {
              id: "compiled-durable-counter-example",
              declaredPath: durableExtension,
              entryPath: durableExtension,
              scope: "temporary",
              origin: "cli"
            }
          ]
        }
      })
    )

    const [exitCode, capturedStdout, capturedStderr] = await Promise.all([childExit(child), stdout, stderr, protocol])
    expect(exitCode).toBe(0)
    expect(capturedStdout).toBe("compiled worker stdout\n")
    expect(capturedStderr).toBe("compiled worker stderr\n")
    expect(protocolMessages.map(message => message.type)).toEqual([
      "ready",
      "custom_entries_get",
      "settled",
      "command_result",
      "custom_entry_append",
      "custom_message_send",
      "tool_result",
      "tool_result",
      "settled",
      "settled"
    ])
    expect(compiledCommandResult).toBe("Counter: 0")
    expect(compiledCounterResult).toBe("1")
    expect(compiledCustomMessage).toBe("Counter: 1")
    expect(JSON.stringify(compiledToolResult)).toContain("zi")
    expect(await Bun.file(lifecycle).text()).toBe("start:startup\nstop:quit\n")

    await Bun.write(lifecycle, "")
    await Bun.write(
      extension,
      `
import { appendFileSync } from "node:fs"
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "compiled_echo",
    description: "Echo from the compiled extension worker",
    parameters: Schema.object({ value: Schema.string() }),
    execute: ({ value }) => "compiled:" + value
  })
  zi.on("session_start", event => appendFileSync(${JSON.stringify(lifecycle)}, "start:" + event.reason + "\\n"))
  zi.on("session_shutdown", event => appendFileSync(${JSON.stringify(lifecycle)}, "stop:" + event.reason + "\\n"))
}
`
    )
    child = spawn(
      executable,
      [
        "--cwd",
        temporary,
        "--agent-dir",
        join(temporary, "agent"),
        "--no-session",
        "--extension",
        extension,
        "--mode",
        "text",
        "prompt"
      ],
      { cwd: temporary, env: providerFreeEnvironment(temporary), stdio: ["pipe", "pipe", "pipe"], windowsHide: true }
    )
    child.stdin!.end()
    const [productExit, productStdout, productStderr] = await Promise.all([
      childExit(child),
      readNodeStream(child.stdout!),
      readNodeStream(child.stderr!)
    ])
    expect(productExit).toBe(1)
    expect(productStdout).not.toContain("compiled worker stdout")
    expect(productStderr).not.toContain("compiled worker stderr")
    expect(await Bun.file(lifecycle).text()).toBe("start:startup\nstop:quit\n")

    child = spawn(
      executable,
      ["--cwd", temporary, "--agent-dir", join(temporary, "rpc-agent"), "--no-session", "--mode", "rpc"],
      { cwd: temporary, env: providerFreeEnvironment(temporary), stdio: ["pipe", "pipe", "pipe"], windowsHide: true }
    )
    child.stdin!.end(`${JSON.stringify({ version: 1, id: "state", method: "session.get_state" })}\n`)
    const [rpcExit, rpcStdout, rpcStderr] = await Promise.all([
      childExit(child),
      readNodeStream(child.stdout!),
      readNodeStream(child.stderr!)
    ])
    expect(rpcExit).toBe(0)
    expect(rpcStderr).toBe("")
    expect(parseJsonLines(rpcStdout)).toMatchObject([
      { version: 1, sequence: 1, type: "ready", state: { activity: { type: "idle" } } },
      {
        version: 1,
        sequence: 2,
        type: "response",
        id: "state",
        method: "session.get_state",
        ok: true,
        result: { activity: { type: "idle" } }
      }
    ])

    await runExtensionCustomToolAcceptance({ executable, extensionSource: exampleExtension })

    await runCodeModeAcceptance({ executable, cwd: temporary })
  } finally {
    child?.kill()
    await rm(temporary, { recursive: true, force: true })
  }
}, 90_000)

test("the standalone bundle resolves OAuth and settles highlighted Markdown", async () => {
  const temporary = await mkdtemp(join(import.meta.dirname, ".compiled-standalone-"))
  const entrypoint = join(temporary, "smoke.ts")
  const executable = join(temporary, process.platform === "win32" ? "smoke.exe" : "smoke")
  const codingAgentSource = resolve(import.meta.dirname, "../packages/coding-agent/src")
  const providers = Bun.resolveSync("@earendil-works/pi-ai/providers/all", codingAgentSource)
  const bunOauth = Bun.resolveSync("@earendil-works/pi-ai/bun-oauth", codingAgentSource)
  const tuiSource = resolve(import.meta.dirname, "../packages/tui/src")
  const openTuiCore = Bun.resolveSync("@opentui/core", tuiSource)
  const openTuiTesting = Bun.resolveSync("@opentui/core/testing", tuiSource)
  const markdownFixture = [
    "## Release",
    "",
    "The **compiled** transcript keeps `inline` Markdown.",
    "",
    "```ts",
    "const answer: number = 42",
    "```"
  ].join("\n")
  try {
    await Bun.write(
      entrypoint,
      `
import { builtinModels } from ${JSON.stringify(providers)}
import {
  CodeRenderable,
  MarkdownRenderable,
  SyntaxStyle,
  destroyTreeSitterClient
} from ${JSON.stringify(openTuiCore)}
import { createTestRenderer } from ${JSON.stringify(openTuiTesting)}

import { registerBunOAuthFlows } from ${JSON.stringify(bunOauth)}
registerBunOAuthFlows()

const providerIds = ["anthropic", "github-copilot", "openai-codex", "xai"]
const credential = {
  type: "oauth",
  access: "compiled-oauth-access",
  refresh: "compiled-oauth-refresh",
  expires: Date.now() + 60_000
}
const credentials = {
  async read(providerId) {
    return providerIds.includes(providerId) ? credential : undefined
  },
  async modify() {
    return credential
  },
  async delete() {}
}
const models = builtinModels({ credentials })
for (const providerId of providerIds) {
  const provider = models.getProvider(providerId)
  if (!provider?.auth.oauth) throw new Error(\`Missing OAuth method for \${providerId}\`)
  const model = models.getModels(providerId)[0]
  if (!model) throw new Error(\`Missing model for \${providerId}\`)
  const auth = await models.getAuth(model)
  if (auth?.auth.apiKey !== credential.access) throw new Error(\`OAuth derivation failed for \${providerId}\`)
}

const setup = await createTestRenderer({ width: 72, height: 12, useThread: false })
const syntaxStyle = SyntaxStyle.fromStyles({
  default: { fg: "#ffffff" },
  conceal: { fg: "#777777" },
  "markup.heading": { fg: "#ffff00", bold: true },
  "markup.heading.2": { fg: "#ffff00", bold: true },
  "markup.strong": { fg: "#ffffff", bold: true },
  "markup.raw": { fg: "#00ffff" },
  "markup.raw.block": { fg: "#aaaaaa" }
})
const markdown = new MarkdownRenderable(setup.renderer, {
  content: ${JSON.stringify(markdownFixture)},
  syntaxStyle,
  conceal: true,
  streaming: true,
  internalBlockMode: "top-level"
})
setup.renderer.root.add(markdown)

try {
  for (let attempt = 0; attempt < 20; attempt++) {
    await setup.renderOnce()
    const stack = [...markdown.getChildren()]
    const pending = []
    while (stack.length > 0) {
      const child = stack.pop()
      if (child instanceof CodeRenderable && child.isHighlighting) pending.push(child)
      stack.push(...child.getChildren())
    }
    if (pending.length === 0) break
    await Promise.all(pending.map(child => child.highlightingDone))
    if (attempt === 19) throw new Error("Compiled Markdown highlighting did not settle")
  }
  await setup.renderOnce()
  const frame = setup.captureCharFrame()
  for (const expected of ["Release", "The compiled transcript keeps inline Markdown.", "const answer: number = 42"]) {
    if (!frame.includes(expected)) throw new Error(\`Compiled Markdown omitted: \${expected}\`)
  }
  for (const sourceMarker of ["## Release", "**compiled**", "\`inline\`", "\`\`\`"]) {
    if (frame.includes(sourceMarker)) throw new Error(\`Compiled Markdown exposed source markup: \${sourceMarker}\`)
  }
} finally {
  if (!setup.renderer.isDestroyed) setup.renderer.destroy()
  syntaxStyle.destroy()
  await destroyTreeSitterClient()
}
`
    )
    await compileStandalone(entrypoint, executable)
    if (process.platform !== "win32") await chmod(executable, 0o755)
    const child = Bun.spawn([executable], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])

    expect({ exitCode, stdout, stderr }).toEqual({ exitCode: 0, stdout: "", stderr: "" })
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}, 60_000)

function providerFreeEnvironment(home: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {}
  const credentialName =
    /(api[_-]?key|token|secret|credential|anthropic|openai|ollama|aws_|azure|google|github|gemini|mistral|groq|xai)/i
  for (const [name, value] of Object.entries(process.env)) {
    if (value !== undefined && !credentialName.test(name)) env[name] = value
  }
  env.HOME = home
  env.USERPROFILE = home
  return env
}

async function compileZiInSubprocess(outfile: string): Promise<void> {
  const compilerSource = pathToFileURL(resolve(import.meta.dirname, "compile-zi.ts")).href
  const code = `
const { compileZi } = await import(${JSON.stringify(compilerSource)})
await compileZi({ outfile: process.env.ZI_COMPILED_TEST_OUTFILE, version: "compiled-extension-worker-test" })
`
  const compiler = Bun.spawn([process.execPath, "-e", code], {
    cwd: resolve(import.meta.dirname, ".."),
    env: { ...process.env, ZI_COMPILED_TEST_OUTFILE: outfile },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe"
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    compiler.exited,
    new Response(compiler.stdout).text(),
    new Response(compiler.stderr).text()
  ])
  if (exitCode !== 0) {
    throw new Error(`Compiled Zi build failed: stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`)
  }
}

function parseJsonLines(output: string): Record<string, unknown>[] {
  return output
    .trimEnd()
    .split("\n")
    .map(line => {
      const value: unknown = JSON.parse(line)
      if (!isRecord(value)) throw new Error("Compiled RPC output must contain JSON objects")
      return value
    })
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

async function readNodeStream(stream: NodeJS.ReadableStream): Promise<string> {
  let text = ""
  for await (const chunk of stream) text += Buffer.from(chunk).toString("utf8")
  return text
}

function childExit(child: ReturnType<typeof spawn>): Promise<number | null> {
  return new Promise((resolveExit, rejectExit) => {
    child.once("error", rejectExit)
    child.once("exit", code => resolveExit(code))
  })
}

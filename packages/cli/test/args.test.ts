import { expect, test } from "bun:test"
import { join, resolve } from "node:path"

import { parseArgs, resolveCliInvocation } from "../src/args.js"

const context = { cwd: resolve("/process"), home: resolve("/home/tester"), env: {} }

test("CLI parses runtime overrides, prompts, and long-option equals syntax", () => {
  const parsed = parseArgs([
    "--cwd=/work",
    "--agent-dir",
    "/agent",
    "--session-dir=/sessions",
    "--model",
    "provider/model",
    "--thinking=high",
    "--api-key",
    "test-key",
    "--system-prompt",
    "Be direct",
    "--append-system-prompt=First",
    "--append-system-prompt",
    "Second",
    "--extension",
    "extension.ts",
    "--extension=~/global.ts",
    "--no-session",
    "first",
    "second"
  ])

  expect(resolveCliInvocation(parsed, context)).toEqual({
    cwd: resolve("/work"),
    agentDir: resolve("/agent"),
    sessionDir: resolve("/sessions"),
    model: "provider/model",
    thinkingLevel: "high",
    apiKey: "test-key",
    systemPrompt: "Be direct",
    appendSystemPrompt: ["First", "Second"],
    extensionPaths: [join(context.cwd, "extension.ts"), join(context.home, "global.ts")],
    session: { type: "new", persist: false },
    mode: "auto",
    toolSurface: "direct-and-code",
    messages: ["first", "second"]
  })
})

test("CLI values override environment defaults", () => {
  const args = resolveCliInvocation(parseArgs(["--cwd", "/cli", "--model", "cli/model", "--mode", "json"]), {
    cwd: "/process",
    home: "/home/tester",
    env: {
      ZI_AGENT_DIR: "/env-agent",
      ZI_SESSION_DIR: "/env-sessions",
      ZI_DEFAULT_MODEL: "env/model",
      ZI_DEFAULT_THINKING: "low",
      ZI_MODE: "text"
    }
  })

  expect(args).toMatchObject({
    cwd: resolve("/cli"),
    agentDir: resolve("/env-agent"),
    sessionDir: resolve("/env-sessions"),
    model: "cli/model",
    thinkingLevel: "low",
    mode: "json"
  })

  expect(
    resolveCliInvocation(
      parseArgs([
        "--agent-dir",
        "/cli-agent",
        "--session-dir",
        "/cli-sessions",
        "--model",
        "cli/model",
        "--mode",
        "text",
        "--thinking",
        "high"
      ]),
      {
        cwd: "/process",
        home: "/home/tester",
        env: {
          ZI_AGENT_DIR: "",
          ZI_SESSION_DIR: "",
          ZI_DEFAULT_MODEL: "",
          ZI_MODE: "invalid",
          ZI_DEFAULT_THINKING: "invalid"
        }
      }
    )
  ).toMatchObject({
    agentDir: resolve("/cli-agent"),
    sessionDir: resolve("/cli-sessions"),
    model: "cli/model",
    mode: "text",
    thinkingLevel: "high"
  })
})

test("environment values provide invocation defaults", () => {
  expect(
    resolveCliInvocation(parseArgs([]), {
      cwd: "/process",
      home: "/home/tester",
      env: {
        ZI_AGENT_DIR: "/agent",
        ZI_SESSION_DIR: "/sessions",
        ZI_DEFAULT_MODEL: "provider/model",
        ZI_DEFAULT_THINKING: "xhigh",
        ZI_MODE: "interactive"
      }
    })
  ).toEqual({
    cwd: resolve("/process"),
    agentDir: resolve("/agent"),
    sessionDir: resolve("/sessions"),
    model: "provider/model",
    thinkingLevel: "xhigh",
    extensionPaths: [],
    session: { type: "new", persist: true },
    mode: "interactive",
    toolSurface: "direct-and-code",
    messages: []
  })
})

test("CLI paths resolve from captured process facts at the invocation boundary", () => {
  const invocation = resolveCliInvocation(
    parseArgs([
      "--cwd",
      "project",
      "--agent-dir",
      ".agent",
      "--session-dir",
      "relative-sessions",
      "--resume",
      "sessions/existing.jsonl"
    ]),
    context
  )

  expect(invocation).toMatchObject({
    cwd: join(context.cwd, "project"),
    agentDir: join(context.cwd, ".agent"),
    sessionDir: "relative-sessions",
    session: { type: "resume", file: join(context.cwd, "sessions", "existing.jsonl") }
  })
  expect(resolveCliInvocation(parseArgs(["--resume", "~/existing.jsonl"]), context).session).toEqual({
    type: "resume",
    file: join(context.home, "existing.jsonl")
  })
})

test("later scalar flags and session selectors override earlier flags", () => {
  const parsed = parseArgs([
    "--model",
    "first/model",
    "--model=second/model",
    "--continue",
    "--resume",
    "old.jsonl",
    "--no-session",
    "--new-session",
    "--mode",
    "json",
    "--print"
  ])

  expect(resolveCliInvocation(parsed, context)).toMatchObject({
    model: "second/model",
    session: { type: "new", persist: true },
    mode: "text"
  })
})

test("CLI parses strict resume and continue intents", () => {
  expect(resolveCliInvocation(parseArgs(["--resume", "session.jsonl"]), context).session).toEqual({
    type: "resume",
    file: join(context.cwd, "session.jsonl")
  })
  expect(resolveCliInvocation(parseArgs(["-r", "short.jsonl"]), context).session).toEqual({
    type: "resume",
    file: join(context.cwd, "short.jsonl")
  })
  expect(resolveCliInvocation(parseArgs(["-c"]), context).session).toEqual({ type: "continue" })
  expect(() => parseArgs(["--session", "session.jsonl"])).toThrow("Unknown argument: --session")
})

test("double dash ends option parsing", () => {
  expect(resolveCliInvocation(parseArgs(["--", "--model", "literal"]), context).messages).toEqual([
    "--model",
    "literal"
  ])
})

test("help and version are parse-time intents", () => {
  expect(parseArgs(["-h", "-V"])).toMatchObject({ help: true, version: true, messages: [] })
})

test("RPC is an explicit protocol mode", () => {
  expect(resolveCliInvocation(parseArgs(["--mode", "rpc"]), context).mode).toBe("rpc")
})

test("code-only is an explicit invocation tool surface", () => {
  expect(resolveCliInvocation(parseArgs(["--code-only"]), context).toolSurface).toBe("code-only")
  expect(() => parseArgs(["--code-only=true"])).toThrow("--code-only does not take a value")
})

test("values and environment defaults are validated at their boundary", () => {
  expect(() => parseArgs(["--api-key"])).toThrow("--api-key requires a value")
  expect(() => parseArgs(["--thinking", "huge"])).toThrow("Invalid --thinking value")
  expect(() =>
    resolveCliInvocation(parseArgs([]), { cwd: "/process", home: "/home/tester", env: { ZI_MODE: "yaml" } })
  ).toThrow("Invalid ZI_MODE value")
  expect(() =>
    resolveCliInvocation(parseArgs([]), { cwd: "/process", home: "/home/tester", env: { ZI_DEFAULT_MODEL: "" } })
  ).toThrow("ZI_DEFAULT_MODEL must not be empty")
})

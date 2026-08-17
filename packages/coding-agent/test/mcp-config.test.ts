import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve, win32 } from "node:path"

import {
  maxMcpServers,
  maxMcpStartupTimeoutMs,
  maxMcpStdioServers,
  resolveMcpExecutable,
  resolveMcpLoadPlan,
  snapshotMcpServersConfig
} from "../src/mcp/config.js"
import { ZiPaths } from "../src/paths.js"
import { snapshotAgentRuntimeOptions } from "../src/runtime-options.js"
import { SettingsManager } from "../src/settings-manager.js"

test("MCP settings merge definitions by server name across admitted layers", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-settings-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({
      mcpServers: {
        selected: { transport: "stdio", command: ["global"], environment: { GLOBAL: "value" } },
        disabled: { transport: "stdio", command: ["lower"] }
      }
    })
  )
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({
      mcpServers: {
        selected: { transport: "streamable-http", url: "https://project.example/mcp" },
        disabled: { enabled: false },
        project: { transport: "stdio", command: ["project"] }
      }
    })
  )

  const settings = SettingsManager.create(paths, "trusted", {
    mcpServers: {
      selected: { transport: "stdio", command: ["runtime"] },
      runtime: { transport: "streamable-http", url: "https://runtime.example/mcp" }
    }
  })

  expect(settings.get().mcpServers).toEqual({
    selected: { transport: "stdio", command: ["runtime"] },
    disabled: { enabled: false },
    project: { transport: "stdio", command: ["project"] },
    runtime: { transport: "streamable-http", url: "https://runtime.example/mcp" }
  })
  expect(settings.get().mcpServers?.selected).not.toHaveProperty("environment")
  expect(Object.isFrozen(settings.get().mcpServers)).toBe(true)
})

test("MCP load plans use stable code-unit server ordering", () => {
  const configured = snapshotMcpServersConfig({
    "é-server": { enabled: false },
    "z-server": { enabled: false },
    "A-server": { enabled: false }
  })
  const paths = new ZiPaths("/workspace", "/agent")

  const plan = resolveMcpLoadPlan(configured, paths, {}, "linux")

  expect(plan.servers.map(server => server.name)).toEqual(["A-server", "z-server", "é-server"])
})

test("effective MCP settings enforce aggregate server and stdio bounds after layer precedence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-effective-bounds-"))

  const serverPaths = new ZiPaths(join(root, "server-project"), join(root, "server-global"))
  await mkdir(serverPaths.projectDir, { recursive: true })
  await mkdir(serverPaths.globalDir, { recursive: true })
  await writeFile(
    serverPaths.globalSettingsFile,
    JSON.stringify({
      mcpServers: Object.fromEntries(Array.from({ length: 8 }, (_, index) => [`global-${index}`, { enabled: false }]))
    })
  )
  await writeFile(
    serverPaths.projectSettingsFile,
    JSON.stringify({
      mcpServers: Object.fromEntries(Array.from({ length: 8 }, (_, index) => [`project-${index}`, { enabled: false }]))
    })
  )
  expect(() => SettingsManager.create(serverPaths, "trusted", { mcpServers: { runtime: { enabled: false } } })).toThrow(
    `${maxMcpServers} servers`
  )

  const stdioPaths = new ZiPaths(join(root, "stdio-project"), join(root, "stdio-global"))
  await mkdir(stdioPaths.projectDir, { recursive: true })
  await mkdir(stdioPaths.globalDir, { recursive: true })
  await writeFile(
    stdioPaths.globalSettingsFile,
    JSON.stringify({
      mcpServers: {
        "global-0": { transport: "stdio", command: ["tool"] },
        "global-1": { transport: "stdio", command: ["tool"] }
      }
    })
  )
  await writeFile(
    stdioPaths.projectSettingsFile,
    JSON.stringify({
      mcpServers: {
        "project-0": { transport: "stdio", command: ["tool"] },
        "project-1": { transport: "stdio", command: ["tool"] }
      }
    })
  )
  expect(() =>
    SettingsManager.create(stdioPaths, "trusted", {
      mcpServers: { runtime: { transport: "stdio", command: ["tool"] } }
    })
  ).toThrow(`${maxMcpStdioServers} stdio servers`)
})

test("untrusted project MCP settings are excluded before environment resolution", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-untrusted-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({
      mcpServers: { private: { transport: "stdio", command: ["private"], environmentFrom: ["PROJECT_SECRET"] } }
    })
  )
  const settings = SettingsManager.create(paths, "untrusted")
  const inaccessibleEnvironment: Readonly<Record<string, string | undefined>> = new Proxy(
    {},
    {
      ownKeys() {
        throw new Error("environment was accessed")
      },
      get() {
        throw new Error("environment was accessed")
      }
    }
  )

  expect(settings.get().mcpServers).toBeUndefined()
  expect(resolveMcpLoadPlan(settings.get().mcpServers, paths, inaccessibleEnvironment, "linux")).toEqual({
    servers: [],
    diagnostics: []
  })
})

test("MCP settings reject malformed and over-capacity definitions", () => {
  const invalid = [
    { "": { enabled: false } },
    { broken: { transport: "stdio", command: [] } },
    { broken: { transport: "stdio", command: ["bad\ncommand"] } },
    { broken: { transport: "stdio", command: ["tool"], environmentFrom: ["BAD-NAME"] } },
    { broken: { transport: "stdio", command: ["tool"], startupTimeoutMs: maxMcpStartupTimeoutMs + 1 } },
    { broken: { transport: "stdio", command: ["tool"], toolTimeoutMs: 1.5 } },
    { broken: { transport: "streamable-http", url: "ftp://example.com/mcp" } },
    { broken: { transport: "streamable-http", url: "https://user:secret@example.com/mcp" } },
    { broken: { transport: "streamable-http", url: "https://example.com/mcp", headers: { "Bad\nHeader": "value" } } },
    { broken: { transport: "stdio", command: ["tool"], future: true } }
  ]
  for (const value of invalid) expect(() => snapshotMcpServersConfig(value)).toThrow()

  expect(() =>
    snapshotMcpServersConfig(
      Object.fromEntries(
        Array.from({ length: maxMcpServers + 1 }, (_, index) => [`server-${index}`, { enabled: false }])
      )
    )
  ).toThrow(`${maxMcpServers} servers`)
  expect(() =>
    snapshotMcpServersConfig(
      Object.fromEntries(
        Array.from({ length: maxMcpStdioServers + 1 }, (_, index) => [
          `server-${index}`,
          { transport: "stdio", command: ["tool"] }
        ])
      )
    )
  ).toThrow(`${maxMcpStdioServers} stdio servers`)
})

test("runtime MCP settings snapshots are deeply immutable", () => {
  const command = ["tool", "--flag"]
  const environment = { TOKEN: "before" }
  const environmentFrom = ["INHERITED"]
  const headers = { Authorization: "before" }
  const headerEnvironment = { "X-Token": "HTTP_TOKEN" }
  const servers = {
    local: { transport: "stdio" as const, command, environment, environmentFrom },
    remote: { transport: "streamable-http" as const, url: "https://example.com/mcp", headers, headerEnvironment }
  }

  const snapshot = snapshotAgentRuntimeOptions({ cwd: "/workspace", settings: { mcpServers: servers } })
  command[0] = "changed"
  environment.TOKEN = "changed"
  environmentFrom[0] = "CHANGED"
  headers.Authorization = "changed"
  headerEnvironment["X-Token"] = "CHANGED"

  const captured = snapshot.settings?.mcpServers
  expect(captured?.local).toEqual({
    transport: "stdio",
    command: ["tool", "--flag"],
    environment: { TOKEN: "before" },
    environmentFrom: ["INHERITED"]
  })
  expect(captured?.remote).toEqual({
    transport: "streamable-http",
    url: "https://example.com/mcp",
    headers: { Authorization: "before" },
    headerEnvironment: { "X-Token": "HTTP_TOKEN" }
  })
  expect(Object.isFrozen(captured)).toBe(true)
  const local = captured?.local
  expect(Object.isFrozen(local)).toBe(true)
  if (local && local.enabled !== false && local.transport === "stdio") {
    expect(Object.isFrozen(local.command)).toBe(true)
    expect(Object.isFrozen(local.environment)).toBe(true)
  }
})

test("stdio resolution uses captured PATH, relative cwd, and a scrubbed bounded environment", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-mcp-resolve-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const executable = "/opt/mcp/bin/server"
  const configured = snapshotMcpServersConfig({
    local: {
      transport: "stdio",
      command: ["server", "--stdio"],
      cwd: "services/mcp",
      environment: { EXPLICIT: "configured" },
      environmentFrom: ["TOKEN"]
    }
  })
  const plan = resolveMcpLoadPlan(
    configured,
    paths,
    {
      PATH: "/opt/mcp/bin:/usr/bin",
      HOME: "/home/user",
      USER: "ci",
      LANG: "en_US.UTF-8",
      LC_CTYPE: "en_US.UTF-8",
      NODE_OPTIONS: "--inspect",
      AWS_SECRET_ACCESS_KEY: "cloud-secret",
      TOKEN: "inherited-secret"
    },
    "linux",
    candidate => candidate === executable
  )
  const server = plan.servers[0]
  if (!server || !server.enabled || server.transport !== "stdio") throw new Error("Expected stdio server")

  expect(plan.diagnostics).toEqual([])
  expect(server.command).toEqual([executable, "--stdio"])
  expect(server.cwd).toBe(resolve(paths.cwd, "services/mcp"))
  expect(server.environment).toEqual({
    PATH: "/opt/mcp/bin:/usr/bin",
    HOME: "/home/user",
    USER: "ci",
    LANG: "en_US.UTF-8",
    LC_CTYPE: "en_US.UTF-8",
    EXPLICIT: "configured",
    TOKEN: "inherited-secret"
  })
  expect(server.environment).not.toHaveProperty("NODE_OPTIONS")
  expect(server.environment).not.toHaveProperty("AWS_SECRET_ACCESS_KEY")
  expect(server.redactionValues).toEqual(["inherited-secret", "configured"])
  expect(server.redactionValues).not.toContain("ci")
  expect(server.redactionValues).not.toContain("en_US.UTF-8")
  expect(Object.isFrozen(server.environment)).toBe(true)
  expect(Object.isFrozen(server.redactionValues)).toBe(true)
})

test("bare executable resolution follows POSIX and Windows path conventions", () => {
  expect(
    resolveMcpExecutable("server", "/workspace", { PATH: "bin:/opt/tools" }, "linux", path => {
      return path === "/opt/tools/server"
    })
  ).toBe("/opt/tools/server")

  const expected = win32.join("D:\\Tools", "server.EXE")
  expect(
    resolveMcpExecutable(
      "server",
      "C:\\workspace",
      { Path: "C:\\Bin;D:\\Tools", PATHEXT: ".COM;.EXE" },
      "win32",
      path => path === expected
    )
  ).toBe(expected)
})

test("Streamable HTTP resolution applies captured header environment without leaking secrets in failures", () => {
  const paths = new ZiPaths("/workspace", "/global")
  const configured = snapshotMcpServersConfig({
    remote: {
      transport: "streamable-http",
      url: "https://example.com/mcp?tenant=internal",
      headers: { "X-Client": "zi" },
      headerEnvironment: { Authorization: "MCP_AUTH" }
    }
  })
  const resolved = resolveMcpLoadPlan(configured, paths, { MCP_AUTH: "Bearer supersecret" }, "linux")
  const server = resolved.servers[0]
  if (!server || !server.enabled || server.transport !== "streamable-http") {
    throw new Error("Expected HTTP server")
  }
  expect(server.headers).toEqual({ "X-Client": "zi", Authorization: "Bearer supersecret" })
  expect(server.redactionValues).toEqual([
    "https://example.com/mcp?tenant=internal",
    "Bearer supersecret",
    "?tenant=internal",
    "zi"
  ])

  const missing = resolveMcpLoadPlan(configured, paths, { OTHER_SECRET: "supersecret" }, "linux")
  expect(missing.servers).toEqual([])
  expect(missing.diagnostics).toHaveLength(1)
  expect(JSON.stringify(missing.diagnostics)).not.toContain("supersecret")

  let message = ""
  try {
    snapshotMcpServersConfig({
      remote: { transport: "streamable-http", url: "https://user:supersecret@example.com/mcp" }
    })
  } catch (cause) {
    message = cause instanceof Error ? cause.message : String(cause)
  }
  expect(message).not.toContain("supersecret")
})

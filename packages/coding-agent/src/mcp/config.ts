import { accessSync, constants } from "node:fs"
import { isAbsolute, posix, resolve, win32 } from "node:path"

import { isMcpServersConfigShape } from "../guards.js"
import type { ZiPaths } from "../paths.js"

export const maxMcpServers = 16
export const maxMcpStdioServers = 4
export const defaultMcpStartupTimeoutMs = 30_000
export const maxMcpStartupTimeoutMs = 2 * 60_000
export const defaultMcpToolTimeoutMs = 60_000
export const maxMcpToolTimeoutMs = 60 * 60_000
export const maxMcpHttpHeaderBytes = 64 * 1024

const maxMcpServerNameBytes = 128
const maxMcpCommandParts = 32
const maxMcpCommandPartBytes = 4_096
const maxMcpPathBytes = 4_096
const maxMcpEnvironmentEntries = 128
const maxMcpEnvironmentKeyBytes = 256
const maxMcpEnvironmentValueBytes = 32 * 1024
const maxMcpEnvironmentBytes = 64 * 1024
const maxMcpLocaleEntries = 32
const maxMcpHeaderEntries = 128
const maxMcpHeaderNameBytes = 256
const maxMcpHeaderValueBytes = 32 * 1024
const maxMcpUrlBytes = 8 * 1024

export type McpTransport = "stdio" | "streamable-http"

export function compareMcpIdentity(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

export interface McpDisabledServerConfig {
  readonly enabled: false
}

export interface McpServerBaseConfig {
  readonly enabled?: true
  readonly required?: boolean
  readonly startupTimeoutMs?: number
  readonly toolTimeoutMs?: number
}

export interface McpStdioServerConfig extends McpServerBaseConfig {
  readonly transport: "stdio"
  readonly command: readonly string[]
  readonly cwd?: string
  readonly environment?: Readonly<Record<string, string>>
  readonly environmentFrom?: readonly string[]
}

export interface McpHttpServerConfig extends McpServerBaseConfig {
  readonly transport: "streamable-http"
  readonly url: string
  readonly headers?: Readonly<Record<string, string>>
  readonly headerEnvironment?: Readonly<Record<string, string>>
}

export type McpServerConfig = McpDisabledServerConfig | McpStdioServerConfig | McpHttpServerConfig
export type McpServersConfig = Readonly<Record<string, McpServerConfig>>

interface McpResolvedServerBase {
  readonly name: string
  readonly required: boolean
  readonly startupTimeoutMs: number
  readonly toolTimeoutMs: number
  readonly redactionValues: readonly string[]
}

export interface McpResolvedDisabledServer {
  readonly name: string
  readonly enabled: false
}

export interface McpResolvedStdioServer extends McpResolvedServerBase {
  readonly enabled: true
  readonly transport: "stdio"
  readonly command: readonly string[]
  readonly cwd: string
  readonly environment: Readonly<Record<string, string>>
}

export interface McpResolvedHttpServer extends McpResolvedServerBase {
  readonly enabled: true
  readonly transport: "streamable-http"
  readonly url: string
  readonly headers: Readonly<Record<string, string>>
}

export type McpResolvedServer = McpResolvedDisabledServer | McpResolvedStdioServer | McpResolvedHttpServer

export interface McpLoadDiagnostic {
  readonly name: string
  readonly required: boolean
  readonly message: string
}

export interface McpLoadPlan {
  readonly servers: readonly McpResolvedServer[]
  readonly diagnostics: readonly McpLoadDiagnostic[]
}

export type McpExecutableProbe = (absolutePath: string) => boolean

export function validateMcpServersConfig(value: unknown): asserts value is McpServersConfig {
  if (!isMcpServersConfigShape(value)) throw new Error("Invalid mcpServers setting")
  const entries = Object.entries(value)
  if (entries.length > maxMcpServers) {
    throw new Error(`MCP settings cannot configure more than ${maxMcpServers} servers`)
  }

  let stdioServers = 0
  for (const [name, server] of entries) {
    validateServerName(name)
    if (server.enabled === false) continue
    validateTimeout(server.startupTimeoutMs, maxMcpStartupTimeoutMs, "startup timeout")
    validateTimeout(server.toolTimeoutMs, maxMcpToolTimeoutMs, "tool timeout")
    if (server.transport === "stdio") {
      stdioServers++
      validateStdioConfig(server)
    } else {
      validateHttpConfig(server)
    }
  }
  if (stdioServers > maxMcpStdioServers) {
    throw new Error(`MCP settings cannot configure more than ${maxMcpStdioServers} stdio servers`)
  }
}

export function snapshotMcpServersConfig(value: unknown): McpServersConfig {
  validateMcpServersConfig(value)
  const servers: Record<string, McpServerConfig> = Object.create(null)
  for (const [name, server] of Object.entries(value)) servers[name] = snapshotServer(server)
  return Object.freeze(servers)
}

export function resolveMcpLoadPlan(
  configured: McpServersConfig | undefined,
  paths: ZiPaths,
  environment: Readonly<Record<string, string | undefined>>,
  platform: NodeJS.Platform,
  executableProbe: McpExecutableProbe = path => defaultExecutableProbe(path, platform)
): McpLoadPlan {
  if (!configured || Object.keys(configured).length === 0) {
    return Object.freeze({ servers: Object.freeze([]), diagnostics: Object.freeze([]) })
  }

  const servers: McpResolvedServer[] = []
  const diagnostics: McpLoadDiagnostic[] = []
  for (const [name, config] of Object.entries(configured).toSorted(([left], [right]) =>
    compareMcpIdentity(left, right)
  )) {
    if (config.enabled === false) {
      servers.push(Object.freeze({ name, enabled: false }))
      continue
    }
    try {
      servers.push(resolveServer(name, config, paths, environment, platform, executableProbe))
    } catch (cause) {
      diagnostics.push(
        Object.freeze({ name, required: config.required ?? false, message: boundedResolutionMessage(cause) })
      )
    }
  }
  return Object.freeze({ servers: Object.freeze(servers), diagnostics: Object.freeze(diagnostics) })
}

export function resolveMcpExecutable(
  executable: string,
  cwd: string,
  environment: Readonly<Record<string, string | undefined>>,
  platform: NodeJS.Platform,
  executableProbe: McpExecutableProbe
): string {
  const pathApi = platform === "win32" ? win32 : posix
  const explicit = pathApi.isAbsolute(executable) || executable.includes("/") || executable.includes("\\")
  if (explicit) {
    const candidate = pathApi.resolve(cwd, executable)
    if (executableProbe(candidate)) return candidate
    throw new Error("MCP stdio executable does not exist")
  }

  const pathValue = environmentValue(environment, "PATH", platform)
  if (!pathValue) throw new Error("MCP stdio executable could not be resolved because PATH is unavailable")
  if (Buffer.byteLength(pathValue) > maxMcpEnvironmentValueBytes) {
    throw new Error("MCP stdio executable could not be resolved because PATH is too large")
  }
  const extensions = platform === "win32" ? windowsExecutableExtensions(environment, executable) : [""]
  const delimiter = platform === "win32" ? ";" : ":"
  for (const directory of pathValue.split(delimiter)) {
    if (!directory) continue
    const absoluteDirectory = pathApi.isAbsolute(directory) ? directory : pathApi.resolve(cwd, directory)
    for (const extension of extensions) {
      const candidate = pathApi.join(absoluteDirectory, `${executable}${extension}`)
      if (executableProbe(candidate)) return candidate
    }
  }
  throw new Error("MCP stdio executable was not found on PATH")
}

function resolveServer(
  name: string,
  config: McpStdioServerConfig | McpHttpServerConfig,
  paths: ZiPaths,
  environment: Readonly<Record<string, string | undefined>>,
  platform: NodeJS.Platform,
  executableProbe: McpExecutableProbe
): McpResolvedStdioServer | McpResolvedHttpServer {
  const base = {
    name,
    required: config.required ?? false,
    startupTimeoutMs: config.startupTimeoutMs ?? defaultMcpStartupTimeoutMs,
    toolTimeoutMs: config.toolTimeoutMs ?? defaultMcpToolTimeoutMs
  }
  if (config.transport === "stdio") {
    const cwd = resolve(config.cwd ? resolve(paths.cwd, config.cwd) : paths.cwd)
    const executable = resolveMcpExecutable(config.command[0]!, cwd, environment, platform, executableProbe)
    const childEnvironment = resolveStdioEnvironment(config, environment, platform)
    return Object.freeze({
      ...base,
      enabled: true,
      transport: "stdio",
      command: Object.freeze([executable, ...config.command.slice(1)]),
      cwd,
      environment: childEnvironment,
      redactionValues: configuredEnvironmentValues(config, childEnvironment, platform)
    })
  }

  const headers = resolveHttpHeaders(config, environment, platform)
  return Object.freeze({
    ...base,
    enabled: true,
    transport: "streamable-http",
    url: config.url,
    headers,
    redactionValues: httpRedactionValues(config, headers)
  })
}

function resolveStdioEnvironment(
  config: McpStdioServerConfig,
  captured: Readonly<Record<string, string | undefined>>,
  platform: NodeJS.Platform
): Readonly<Record<string, string>> {
  const environment: Record<string, string> = Object.create(null)
  const baseline = platform === "win32" ? windowsBaseline : posixBaseline
  for (const [key, value] of Object.entries(captured)) {
    if (value === undefined || Buffer.byteLength(value) > maxMcpEnvironmentValueBytes) continue
    const canonical = platform === "win32" ? key.toUpperCase() : key
    if (baseline.has(canonical)) setEnvironmentValue(environment, key, value, platform)
  }
  if (platform !== "win32") {
    let locales = 0
    for (const [key, value] of Object.entries(captured)) {
      if (
        locales >= maxMcpLocaleEntries ||
        !key.startsWith("LC_") ||
        value === undefined ||
        Buffer.byteLength(value) > maxMcpEnvironmentValueBytes
      ) {
        continue
      }
      setEnvironmentValue(environment, key, value, platform)
      locales++
    }
  }
  for (const [key, value] of Object.entries(config.environment ?? {})) {
    setEnvironmentValue(environment, key, value, platform)
  }
  for (const key of config.environmentFrom ?? []) {
    const value = environmentValue(captured, key, platform)
    if (value === undefined) throw new Error(`MCP environment variable ${key} is not set`)
    if (Buffer.byteLength(value) > maxMcpEnvironmentValueBytes) {
      throw new Error(`MCP environment variable ${key} is too large`)
    }
    setEnvironmentValue(environment, key, value, platform)
  }
  if (encodedRecordBytes(environment) > maxMcpEnvironmentBytes) {
    throw new Error("Resolved MCP stdio environment is too large")
  }
  return Object.freeze(environment)
}

function resolveHttpHeaders(
  config: McpHttpServerConfig,
  captured: Readonly<Record<string, string | undefined>>,
  platform: NodeJS.Platform
): Readonly<Record<string, string>> {
  const headers: Record<string, string> = Object.create(null)
  for (const [name, value] of Object.entries(config.headers ?? {})) headers[name] = value
  for (const [name, environmentName] of Object.entries(config.headerEnvironment ?? {})) {
    const value = environmentValue(captured, environmentName, platform)
    if (value === undefined) throw new Error(`MCP header environment variable ${environmentName} is not set`)
    if (!isHeaderValue(value)) throw new Error(`MCP header environment variable ${environmentName} is invalid`)
    headers[name] = value
  }
  if (encodedRecordBytes(headers) > maxMcpHttpHeaderBytes) throw new Error("Resolved MCP HTTP headers are too large")
  return Object.freeze(headers)
}

function configuredEnvironmentValues(
  config: McpStdioServerConfig,
  environment: Readonly<Record<string, string>>,
  platform: NodeJS.Platform
): readonly string[] {
  const names = [...Object.keys(config.environment ?? {}), ...(config.environmentFrom ?? [])]
  return redactionValues(names.map(name => environmentValue(environment, name, platform)))
}

function httpRedactionValues(
  config: McpHttpServerConfig,
  headers: Readonly<Record<string, string>>
): readonly string[] {
  const url = new URL(config.url)
  return redactionValues([
    ...Object.keys(config.headers ?? {}).map(name => headers[name]),
    ...Object.keys(config.headerEnvironment ?? {}).map(name => headers[name]),
    config.url,
    url.search
  ])
}

function redactionValues(values: readonly (string | undefined)[]): readonly string[] {
  return Object.freeze(
    [...new Set(values.filter((value): value is string => value !== undefined && value.length > 0))].toSorted(
      (left, right) => right.length - left.length
    )
  )
}

function snapshotServer(server: McpServerConfig): McpServerConfig {
  if (server.enabled === false) return Object.freeze({ enabled: false })
  const base = {
    ...(server.enabled === undefined ? {} : { enabled: true as const }),
    ...(server.required === undefined ? {} : { required: server.required }),
    ...(server.startupTimeoutMs === undefined ? {} : { startupTimeoutMs: server.startupTimeoutMs }),
    ...(server.toolTimeoutMs === undefined ? {} : { toolTimeoutMs: server.toolTimeoutMs })
  }
  if (server.transport === "stdio") {
    return Object.freeze({
      ...base,
      transport: "stdio" as const,
      command: Object.freeze([...server.command]),
      ...(server.cwd === undefined ? {} : { cwd: server.cwd }),
      ...(server.environment === undefined ? {} : { environment: freezeRecord(server.environment) }),
      ...(server.environmentFrom === undefined ? {} : { environmentFrom: Object.freeze([...server.environmentFrom]) })
    })
  }
  return Object.freeze({
    ...base,
    transport: "streamable-http" as const,
    url: server.url,
    ...(server.headers === undefined ? {} : { headers: freezeRecord(server.headers) }),
    ...(server.headerEnvironment === undefined ? {} : { headerEnvironment: freezeRecord(server.headerEnvironment) })
  })
}

function validateServerName(name: string): void {
  if (!isBoundedText(name, maxMcpServerNameBytes) || name !== name.trim()) {
    throw new Error("MCP server names must be non-empty bounded strings without surrounding whitespace")
  }
}

function validateTimeout(value: number | undefined, maximum: number, label: string): void {
  if (value !== undefined && (!Number.isSafeInteger(value) || value < 1 || value > maximum)) {
    throw new Error(`MCP ${label} must be a positive integer no greater than ${maximum} ms`)
  }
}

function validateStdioConfig(config: McpStdioServerConfig): void {
  if (
    config.command.length === 0 ||
    config.command.length > maxMcpCommandParts ||
    config.command.some(part => !isBoundedText(part, maxMcpCommandPartBytes))
  ) {
    throw new Error("MCP stdio commands require an executable and at most 31 bounded arguments")
  }
  if (config.cwd !== undefined && !isBoundedText(config.cwd, maxMcpPathBytes)) {
    throw new Error("MCP stdio cwd must be a bounded path")
  }
  validateEnvironmentRecord(config.environment)
  validateEnvironmentNames(config.environmentFrom)
}

function validateHttpConfig(config: McpHttpServerConfig): void {
  if (!isBoundedText(config.url, maxMcpUrlBytes)) throw new Error("MCP HTTP URL must be bounded")
  let url: URL
  try {
    url = new URL(config.url)
  } catch {
    throw new Error("MCP HTTP URL is invalid")
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password) {
    throw new Error("MCP HTTP URL must use HTTP or HTTPS without embedded credentials")
  }
  validateHeaderRecord(config.headers)
  validateHeaderEnvironment(config.headerEnvironment)
}

function validateEnvironmentRecord(record: Readonly<Record<string, string>> | undefined): void {
  if (!record) return
  const entries = Object.entries(record)
  if (entries.length > maxMcpEnvironmentEntries) throw new Error("MCP environment has too many entries")
  for (const [key, value] of entries) {
    validateEnvironmentName(key)
    if (!isBoundedValue(value, maxMcpEnvironmentValueBytes)) throw new Error("MCP environment value is invalid")
  }
  if (encodedRecordBytes(record) > maxMcpEnvironmentBytes) throw new Error("MCP environment is too large")
}

function validateEnvironmentNames(names: readonly string[] | undefined): void {
  if (!names) return
  if (names.length > maxMcpEnvironmentEntries) throw new Error("MCP environmentFrom has too many entries")
  const unique = new Set<string>()
  for (const name of names) {
    validateEnvironmentName(name)
    if (unique.has(name)) throw new Error("MCP environmentFrom cannot contain duplicate names")
    unique.add(name)
  }
}

function validateEnvironmentName(name: string): void {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || Buffer.byteLength(name) > maxMcpEnvironmentKeyBytes) {
    throw new Error("MCP environment names must use portable identifier syntax")
  }
}

function validateHeaderRecord(record: Readonly<Record<string, string>> | undefined): void {
  if (!record) return
  const entries = Object.entries(record)
  if (entries.length > maxMcpHeaderEntries) throw new Error("MCP HTTP headers have too many entries")
  for (const [name, value] of entries) {
    validateHeaderName(name)
    if (!isHeaderValue(value)) throw new Error("MCP HTTP header value is invalid")
  }
  if (encodedRecordBytes(record) > maxMcpHttpHeaderBytes) throw new Error("MCP HTTP headers are too large")
}

function validateHeaderEnvironment(record: Readonly<Record<string, string>> | undefined): void {
  if (!record) return
  const entries = Object.entries(record)
  if (entries.length > maxMcpHeaderEntries) throw new Error("MCP headerEnvironment has too many entries")
  for (const [name, environmentName] of entries) {
    validateHeaderName(name)
    validateEnvironmentName(environmentName)
  }
}

function validateHeaderName(name: string): void {
  if (
    Buffer.byteLength(name) > maxMcpHeaderNameBytes ||
    !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) ||
    forbiddenHeaders.has(name.toLowerCase())
  ) {
    throw new Error("MCP HTTP header name is invalid")
  }
}

function isHeaderValue(value: string): boolean {
  return isBoundedValue(value, maxMcpHeaderValueBytes) && !value.includes("\r") && !value.includes("\n")
}

function isBoundedText(value: string, maximumBytes: number): boolean {
  return value.trim().length > 0 && !hasControlCharacter(value) && Buffer.byteLength(value) <= maximumBytes
}

function isBoundedValue(value: string, maximumBytes: number): boolean {
  return !value.includes("\0") && Buffer.byteLength(value) <= maximumBytes
}

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index)
    if (code <= 31 || code === 127) return true
  }
  return false
}

function windowsExecutableExtensions(
  environment: Readonly<Record<string, string | undefined>>,
  executable: string
): readonly string[] {
  if (win32.extname(executable)) return [""]
  const configured = environmentValue(environment, "PATHEXT", "win32") ?? ".COM;.EXE;.BAT;.CMD"
  if (Buffer.byteLength(configured) > maxMcpEnvironmentValueBytes) {
    throw new Error("MCP stdio executable could not be resolved because PATHEXT is too large")
  }
  const extensions = configured
    .split(";")
    .filter(Boolean)
    .map(extension => (extension.startsWith(".") ? extension : `.${extension}`))
  return extensions.length === 0 ? [""] : extensions
}

function environmentValue(
  environment: Readonly<Record<string, string | undefined>>,
  name: string,
  platform: NodeJS.Platform
): string | undefined {
  if (platform !== "win32") return environment[name]
  const target = name.toUpperCase()
  for (const [key, value] of Object.entries(environment)) if (key.toUpperCase() === target) return value
  return undefined
}

function setEnvironmentValue(
  environment: Record<string, string>,
  name: string,
  value: string,
  platform: NodeJS.Platform
): void {
  if (platform === "win32") {
    const target = name.toUpperCase()
    for (const key of Object.keys(environment)) if (key.toUpperCase() === target) delete environment[key]
  }
  environment[name] = value
}

function encodedRecordBytes(record: Readonly<Record<string, string>>): number {
  return Buffer.byteLength(JSON.stringify(record))
}

function freezeRecord(record: Readonly<Record<string, string>>): Readonly<Record<string, string>> {
  return Object.freeze(Object.fromEntries(Object.entries(record)))
}

function boundedResolutionMessage(cause: unknown): string {
  const message = cause instanceof Error ? cause.message : "Could not resolve MCP server configuration"
  return Buffer.byteLength(message) <= 1_024 ? message : "Could not resolve MCP server configuration"
}

function defaultExecutableProbe(path: string, platform: NodeJS.Platform): boolean {
  try {
    accessSync(path, platform === "win32" ? constants.F_OK : constants.X_OK)
    return isAbsolute(path) || platform === "win32"
  } catch {
    return false
  }
}

const posixBaseline = new Set(["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"])
const windowsBaseline = new Set([
  "PATH",
  "PATHEXT",
  "SYSTEMROOT",
  "COMSPEC",
  "TEMP",
  "TMP",
  "USERPROFILE",
  "APPDATA",
  "LOCALAPPDATA"
])
const forbiddenHeaders = new Set(["connection", "content-length", "host", "transfer-encoding"])

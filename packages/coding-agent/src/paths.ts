import { homedir } from "node:os"
import { join, resolve } from "node:path"

export const projectConfigDirName = ".zi"
export const globalAgentDirName = "agent"

export type ResourceDirectory = "extensions" | "prompts" | "skills" | "themes"

/** Immutable global/project path policy for one effective working directory. */
export class ZiPaths {
  readonly cwd: string
  readonly globalDir: string
  readonly projectDir: string
  readonly globalSettingsFile: string
  readonly projectSettingsFile: string
  readonly authFile: string
  readonly globalSystemPromptFile: string
  readonly projectSystemPromptFile: string
  readonly globalAppendSystemPromptFile: string
  readonly projectAppendSystemPromptFile: string
  readonly sessionsDir: string
  readonly sessionDir: string

  constructor(cwd: string, globalDir = getAgentDir(), sessionDir?: string) {
    this.cwd = resolveZiPath(cwd)
    this.globalDir = resolveZiPath(globalDir)
    this.projectDir = join(this.cwd, projectConfigDirName)
    this.globalSettingsFile = join(this.globalDir, "settings.json")
    this.projectSettingsFile = join(this.projectDir, "settings.json")
    this.authFile = join(this.globalDir, "auth.json")
    this.globalSystemPromptFile = join(this.globalDir, "SYSTEM.md")
    this.projectSystemPromptFile = join(this.projectDir, "SYSTEM.md")
    this.globalAppendSystemPromptFile = join(this.globalDir, "APPEND_SYSTEM.md")
    this.projectAppendSystemPromptFile = join(this.projectDir, "APPEND_SYSTEM.md")
    this.sessionsDir = join(this.globalDir, "sessions")
    this.sessionDir = sessionDir ? resolveZiPath(sessionDir, this.cwd) : join(this.sessionsDir, encodeCwd(this.cwd))
    Object.freeze(this)
  }

  globalResourceDir(resource: ResourceDirectory): string {
    return join(this.globalDir, resource)
  }

  projectResourceDir(resource: ResourceDirectory): string {
    return join(this.projectDir, resource)
  }
}

export function resolveZiPath(input: string, baseDir = process.cwd(), home = homedir()): string {
  const expandedInput = expandHome(input, home)
  const expandedBase = expandHome(baseDir, home)
  return resolve(expandedBase, expandedInput)
}

export function getDefaultAgentDir(home = homedir()): string {
  return resolveZiPath(join(projectConfigDirName, globalAgentDirName), home, home)
}

export function getAgentDir(): string {
  return resolveZiPath(process.env.ZI_AGENT_DIR ?? getDefaultAgentDir())
}

export function getSessionDir(cwd: string, agentDir = getAgentDir()): string {
  return new ZiPaths(cwd, agentDir).sessionDir
}

function expandHome(path: string, home: string): string {
  if (path === "~") return home
  if (path.startsWith("~/") || (process.platform === "win32" && path.startsWith("~\\"))) {
    return join(home, path.slice(2))
  }
  return path
}

function encodeCwd(cwd: string): string {
  return `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`
}

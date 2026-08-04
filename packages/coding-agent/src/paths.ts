import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"

export const projectConfigDirName = ".zi"
export const globalAgentDirName = "agent"

export type ResourceDirectory = "extensions" | "prompts" | "skills" | "subagents" | "themes"

/** Immutable global/project path policy for one effective working directory. */
export class ZiPaths {
  readonly cwd: string
  readonly homeDir: string
  readonly globalDir: string
  readonly projectDir: string
  readonly projectConfigIsGlobal: boolean
  readonly globalSettingsFile: string
  readonly projectSettingsFile: string
  readonly authFile: string
  readonly trustFile: string
  readonly globalSystemPromptFile: string
  readonly projectSystemPromptFile: string
  readonly globalAppendSystemPromptFile: string
  readonly projectAppendSystemPromptFile: string
  readonly sessionsDir: string
  readonly sessionDir: string
  readonly globalAgentsSkillsDir: string
  readonly projectAgentsSkillDirs: readonly string[]

  constructor(cwd: string, globalDir = getAgentDir(), sessionDir?: string, homeDir = defaultHomeDir()) {
    this.homeDir = resolveZiPath(homeDir, homeDir, homeDir)
    this.cwd = resolveZiPath(cwd, process.cwd(), this.homeDir)
    this.globalDir = resolveZiPath(globalDir, process.cwd(), this.homeDir)
    this.projectDir = join(this.cwd, projectConfigDirName)
    this.projectConfigIsGlobal = this.projectDir === this.globalDir
    this.globalSettingsFile = join(this.globalDir, "settings.json")
    this.projectSettingsFile = join(this.projectDir, "settings.json")
    this.authFile = join(this.globalDir, "auth.json")
    this.trustFile = join(this.globalDir, "trust.json")
    this.globalSystemPromptFile = join(this.globalDir, "SYSTEM.md")
    this.projectSystemPromptFile = join(this.projectDir, "SYSTEM.md")
    this.globalAppendSystemPromptFile = join(this.globalDir, "APPEND_SYSTEM.md")
    this.projectAppendSystemPromptFile = join(this.projectDir, "APPEND_SYSTEM.md")
    this.sessionsDir = join(this.globalDir, "sessions")
    this.sessionDir = sessionDir
      ? resolveZiPath(sessionDir, this.cwd, this.homeDir)
      : join(this.sessionsDir, encodeCwd(this.cwd))
    this.globalAgentsSkillsDir = join(this.homeDir, ".agents", "skills")
    this.projectAgentsSkillDirs = Object.freeze(
      collectAncestorAgentsSkillDirs(this.cwd).filter(path => path !== this.globalAgentsSkillsDir)
    )
    Object.freeze(this)
  }

  globalResourceDir(resource: ResourceDirectory): string {
    return join(this.globalDir, resource)
  }

  projectResourceDir(resource: ResourceDirectory): string {
    return join(this.projectDir, resource)
  }

  resolveGlobalResourcePath(path: string): string {
    return resolveZiPath(path, this.globalDir, this.homeDir)
  }

  resolveProjectResourcePath(path: string): string {
    return resolveZiPath(path, this.projectDir, this.homeDir)
  }
}

export function resolveZiPath(input: string, baseDir = process.cwd(), home = defaultHomeDir()): string {
  const expandedInput = expandHome(input, home)
  const expandedBase = expandHome(baseDir, home)
  return resolve(expandedBase, expandedInput)
}

export function getDefaultAgentDir(home = defaultHomeDir()): string {
  return resolveZiPath(join(projectConfigDirName, globalAgentDirName), home, home)
}

export function getAgentDir(): string {
  return resolveZiPath(process.env.ZI_AGENT_DIR ?? getDefaultAgentDir())
}

export function getSessionDir(cwd: string, agentDir = getAgentDir()): string {
  return new ZiPaths(cwd, agentDir).sessionDir
}

// Pi provenance: pi-coding-agent package-manager.ts at 73414d08 discovers
// .agents/skills from cwd to the repository boundary, or filesystem root outside Git.
function collectAncestorAgentsSkillDirs(cwd: string): readonly string[] {
  const gitRoot = findGitRoot(cwd)
  const directories: string[] = []
  let directory = cwd
  while (true) {
    directories.push(join(directory, ".agents", "skills"))
    if (directory === gitRoot) break
    const parent = dirname(directory)
    if (parent === directory) break
    directory = parent
  }
  return directories
}

function findGitRoot(cwd: string): string | undefined {
  let directory = cwd
  while (true) {
    if (existsSync(join(directory, ".git"))) return directory
    const parent = dirname(directory)
    if (parent === directory) return undefined
    directory = parent
  }
}

function defaultHomeDir(): string {
  return process.env.HOME || homedir()
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

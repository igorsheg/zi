import { existsSync } from "node:fs"
import { dirname, join } from "node:path"

import type { ZiPaths } from "./paths.js"
import type { ProjectConfigurationAdmission } from "./project-trust.js"
import { loadPromptTemplates, type PromptTemplate } from "./prompt-templates.js"
import { ResourceDiagnostics, type ResourceDiagnostic, type ResourceKind } from "./resource-diagnostics.js"
import {
  canonicalResourcePath,
  maxResourceFileBytes,
  readResourceFile,
  resourcePathType,
  ResourceFileLimitError,
  SessionResourceBudget
} from "./resource-files.js"
import { resolveResourceRoots } from "./resource-roots.js"
import type { SettingsManager } from "./settings-manager.js"
import { loadSkills, type Skill } from "./skills.js"
import { loadSubagentProfiles, type SubagentProfile } from "./subagent-profiles.js"

export const maxContextFileCount = 128
export const maxSessionResourceBytes = 8 * 1024 * 1024

export interface ContextFile {
  readonly path: string
  readonly content: string
}

export interface SessionResources {
  readonly systemPrompt?: string
  readonly appendSystemPrompt: readonly string[]
  readonly contextFiles: readonly ContextFile[]
  readonly skills: readonly Skill[]
  readonly promptTemplates: readonly PromptTemplate[]
  readonly subagentProfiles: readonly SubagentProfile[]
  readonly diagnostics: readonly ResourceDiagnostic[]
}

export interface CreateSessionResourcesOptions {
  readonly systemPrompt?: string
  readonly appendSystemPrompt?: readonly string[]
  readonly contextFiles?: readonly ContextFile[]
  readonly skills?: readonly Skill[]
  readonly promptTemplates?: readonly PromptTemplate[]
  readonly subagentProfiles?: readonly SubagentProfile[]
  readonly diagnostics?: readonly ResourceDiagnostic[]
}

export interface ResourceLoaderOptions {
  readonly paths: ZiPaths
  readonly project: ProjectConfigurationAdmission
  readonly settingsManager?: SettingsManager
  readonly systemPrompt?: string
  readonly appendSystemPrompt?: readonly string[]
}

export class ResourceLoader {
  readonly #paths: ZiPaths
  readonly #project: ProjectConfigurationAdmission
  readonly #projectConfigurationAdmitted: boolean
  readonly #settingsManager: SettingsManager | undefined
  readonly #systemPrompt: string | undefined
  readonly #appendSystemPrompt: readonly string[] | undefined

  constructor(options: ResourceLoaderOptions) {
    if (options.project !== "trusted" && options.project !== "untrusted" && options.project !== "absent") {
      throw new Error(`Unknown project configuration admission: ${String(options.project)}`)
    }
    this.#paths = options.paths
    this.#project = options.project
    this.#projectConfigurationAdmitted = options.project === "trusted" && !options.paths.projectConfigIsGlobal
    this.#settingsManager = options.settingsManager
    this.#systemPrompt = options.systemPrompt
    this.#appendSystemPrompt = options.appendSystemPrompt ? [...options.appendSystemPrompt] : undefined
  }

  async load(): Promise<SessionResources> {
    const diagnostics = new ResourceDiagnostics()
    const budget = new SessionResourceBudget(maxSessionResourceBytes)
    const systemPrompt =
      this.#systemPrompt === undefined
        ? readPreferred(
            this.#projectConfigurationAdmitted ? this.#paths.projectSystemPromptFile : undefined,
            this.#paths.globalSystemPromptFile,
            "system-prompt",
            budget,
            diagnostics
          )
        : admitInline(this.#systemPrompt, "system-prompt", budget, diagnostics)
    const appendSystemPrompt =
      this.#appendSystemPrompt === undefined
        ? asList(
            readPreferred(
              this.#projectConfigurationAdmitted ? this.#paths.projectAppendSystemPromptFile : undefined,
              this.#paths.globalAppendSystemPromptFile,
              "append-system-prompt",
              budget,
              diagnostics
            )
          )
        : this.#appendSystemPrompt.flatMap(prompt => {
            const admitted = admitInline(prompt, "append-system-prompt", budget, diagnostics)
            return admitted === undefined ? [] : [admitted]
          })
    const contextFiles = loadContextFiles(this.#paths, budget, diagnostics)
    const skills = loadSkills(
      resolveResourceRoots(this.#paths, this.#settingsManager, this.#project, "skills"),
      budget,
      diagnostics
    )
    const promptTemplates = loadPromptTemplates(
      resolveResourceRoots(this.#paths, this.#settingsManager, this.#project, "prompts"),
      budget,
      diagnostics
    )
    const subagentProfiles = loadSubagentProfiles(
      [
        ...(this.#projectConfigurationAdmitted
          ? [{ path: this.#paths.projectResourceDir("subagents"), scope: "project" as const }]
          : []),
        { path: this.#paths.globalResourceDir("subagents"), scope: "global" as const }
      ],
      budget,
      diagnostics
    )

    return createSessionResources({
      ...(systemPrompt === undefined ? {} : { systemPrompt }),
      appendSystemPrompt,
      contextFiles,
      skills,
      promptTemplates,
      subagentProfiles,
      diagnostics: diagnostics.snapshot()
    })
  }
}

export function createSessionResources(options: CreateSessionResourcesOptions = {}): SessionResources {
  const appendSystemPrompt = Object.freeze([...(options.appendSystemPrompt ?? [])])
  const contextFiles = Object.freeze(
    (options.contextFiles ?? []).map(file => Object.freeze({ path: file.path, content: file.content }))
  )
  const skills = Object.freeze((options.skills ?? []).map(skill => Object.freeze({ ...skill })))
  const promptTemplates = Object.freeze((options.promptTemplates ?? []).map(template => Object.freeze({ ...template })))
  const subagentProfiles = Object.freeze((options.subagentProfiles ?? []).map(profile => Object.freeze({ ...profile })))
  const diagnostics = Object.freeze(
    (options.diagnostics ?? []).map(diagnostic => Object.freeze({ ...diagnostic }) as ResourceDiagnostic)
  )
  return Object.freeze({
    appendSystemPrompt,
    contextFiles,
    skills,
    promptTemplates,
    subagentProfiles,
    diagnostics,
    ...(options.systemPrompt === undefined ? {} : { systemPrompt: options.systemPrompt })
  })
}

function loadContextFiles(
  paths: ZiPaths,
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): readonly ContextFile[] {
  const seen = new Set<string>()
  const global = readContextFile(paths.globalDir, seen, budget, diagnostics)

  const nearestFirst: ContextFile[] = []
  let directory = paths.cwd
  while (true) {
    const remaining = maxContextFileCount - (global ? 1 : 0) - nearestFirst.length
    if (remaining === 0) {
      const omittedPath = contextCandidatePath(directory, seen)
      if (omittedPath) {
        diagnostics.add({
          type: "limit",
          resource: "context",
          limit: maxContextFileCount,
          path: omittedPath,
          message: `At most ${maxContextFileCount} context files can be loaded`
        })
      }
      if (omittedPath) break
    } else {
      const file = readContextFile(directory, seen, budget, diagnostics)
      if (file) nearestFirst.push(file)
    }
    const parent = dirname(directory)
    if (parent === directory) break
    directory = parent
  }
  const project = nearestFirst.toReversed()
  return global ? [global, ...project] : project
}

function contextCandidatePath(directory: string, seen: Set<string>): string | undefined {
  for (const name of ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]) {
    const path = join(directory, name)
    if (!existsSync(path)) continue
    return seen.has(canonicalResourcePath(path)) ? undefined : path
  }
  return undefined
}

function readContextFile(
  directory: string,
  seen: Set<string>,
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): ContextFile | undefined {
  for (const name of ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]) {
    const path = join(directory, name)
    if (!existsSync(path)) continue
    const canonical = canonicalResourcePath(path)
    if (seen.has(canonical)) return undefined
    const content = readFile(path, "context", budget, diagnostics)
    if (content !== undefined) {
      seen.add(canonical)
      return { path, content }
    }
  }
  return undefined
}

function readPreferred(
  projectPath: string | undefined,
  globalPath: string,
  resource: "system-prompt" | "append-system-prompt",
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): string | undefined {
  for (const path of [projectPath, globalPath]) {
    if (path === undefined || !existsSync(path)) continue
    const content = readFile(path, resource, budget, diagnostics)
    if (content !== undefined) return content
  }
  return undefined
}

function readFile(
  path: string,
  resource: ResourceKind,
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): string | undefined {
  if (resourcePathType(path) !== "file") {
    diagnostics.add({ type: "warning", resource, path, message: "Resource path is not a regular file" })
    return undefined
  }
  try {
    const content = readResourceFile(path)
    if (!budget.retain(Buffer.byteLength(content))) {
      diagnostics.add({
        type: "limit",
        resource,
        limit: budget.limit,
        path,
        message: `Session resources cannot retain more than ${budget.limit} bytes`
      })
      return undefined
    }
    return content
  } catch (cause) {
    if (cause instanceof ResourceFileLimitError) {
      diagnostics.add({ type: "limit", resource, limit: cause.limit, path, message: cause.message })
    } else {
      diagnostics.add({ type: "warning", resource, path, message: errorMessage(cause) })
    }
    return undefined
  }
}

function admitInline(
  content: string,
  resource: "system-prompt" | "append-system-prompt",
  budget: SessionResourceBudget,
  diagnostics: ResourceDiagnostics
): string | undefined {
  const bytes = Buffer.byteLength(content)
  if (bytes > maxResourceFileBytes) {
    diagnostics.add({
      type: "limit",
      resource,
      limit: maxResourceFileBytes,
      path: "<runtime>",
      message: `Inline resource cannot exceed ${maxResourceFileBytes} bytes`
    })
    return undefined
  }
  if (!budget.retain(bytes)) {
    diagnostics.add({
      type: "limit",
      resource,
      limit: budget.limit,
      path: "<runtime>",
      message: `Session resources cannot retain more than ${budget.limit} bytes`
    })
    return undefined
  }
  return content
}

function asList(value: string | undefined): readonly string[] {
  return value === undefined ? [] : [value]
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

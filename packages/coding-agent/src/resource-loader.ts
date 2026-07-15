import { existsSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"

import type { OpenZiPaths } from "./paths.js"

export interface ContextFile {
  path: string
  content: string
}

export interface PromptResources {
  systemPrompt?: string
  appendSystemPrompt: readonly string[]
  contextFiles: readonly ContextFile[]
}

export interface ResourceLoader {
  reload(): Promise<void>
  get(): PromptResources
}

export interface DefaultResourceLoaderOptions {
  paths: OpenZiPaths
  systemPrompt?: string
  appendSystemPrompt?: readonly string[]
}

export class DefaultResourceLoader implements ResourceLoader {
  readonly #options: DefaultResourceLoaderOptions
  #resources: PromptResources = { appendSystemPrompt: [], contextFiles: [] }

  constructor(options: DefaultResourceLoaderOptions) {
    this.#options = options
  }

  async reload(): Promise<void> {
    const paths = this.#options.paths
    const seen = new Set<string>()
    const global = findContextFile(paths.globalDir)
    if (global) seen.add(global.path)

    const project: ContextFile[] = []
    let directory = paths.cwd
    while (true) {
      const file = findContextFile(directory)
      if (file && !seen.has(file.path)) {
        seen.add(file.path)
        project.unshift(file)
      }
      const parent = dirname(directory)
      if (parent === directory) break
      directory = parent
    }

    const systemPrompt =
      this.#options.systemPrompt ?? readPreferred(paths.projectSystemPromptFile, paths.globalSystemPromptFile)
    const appendSystemPrompt =
      this.#options.appendSystemPrompt ??
      asPromptList(readPreferred(paths.projectAppendSystemPromptFile, paths.globalAppendSystemPromptFile))
    this.#resources = {
      appendSystemPrompt,
      contextFiles: global ? [global, ...project] : project,
      ...(systemPrompt === undefined ? {} : { systemPrompt })
    }
  }

  get(): PromptResources {
    return this.#resources
  }
}

function asPromptList(prompt: string | undefined): readonly string[] {
  return prompt === undefined ? [] : [prompt]
}

function readPreferred(projectFile: string, globalFile: string): string | undefined {
  if (existsSync(projectFile)) return readFileSync(projectFile, "utf8")
  if (existsSync(globalFile)) return readFileSync(globalFile, "utf8")
  return undefined
}

function findContextFile(directory: string): ContextFile | undefined {
  for (const name of ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]) {
    const path = join(directory, name)
    if (existsSync(path)) return { path, content: readFileSync(path, "utf8") }
  }
  return undefined
}

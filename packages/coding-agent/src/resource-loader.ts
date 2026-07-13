import { existsSync, readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"

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
  cwd: string
  agentDir: string
  systemPrompt?: string
  appendSystemPrompt?: readonly string[]
}

export class DefaultResourceLoader implements ResourceLoader {
  readonly #options: DefaultResourceLoaderOptions
  #contextFiles: ContextFile[] = []

  constructor(options: DefaultResourceLoaderOptions) {
    this.#options = options
  }

  async reload(): Promise<void> {
    const seen = new Set<string>()
    const global = findContextFile(resolve(this.#options.agentDir))
    if (global) seen.add(global.path)

    const project: ContextFile[] = []
    let directory = resolve(this.#options.cwd)
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
    this.#contextFiles = global ? [global, ...project] : project
  }

  get(): PromptResources {
    return {
      appendSystemPrompt: this.#options.appendSystemPrompt ?? [],
      contextFiles: this.#contextFiles,
      ...(this.#options.systemPrompt === undefined ? {} : { systemPrompt: this.#options.systemPrompt }),
    }
  }
}

function findContextFile(directory: string): ContextFile | undefined {
  for (const name of ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]) {
    const path = join(directory, name)
    if (existsSync(path)) return { path, content: readFileSync(path, "utf8") }
  }
}

import { existsSync } from "node:fs"
import { dirname, join, resolve } from "node:path"

export const installedProductDirectoryName = ".zi-package"
export const publicProductDocumentationFiles = Object.freeze([
  "authentication.md",
  "cli.md",
  "code-mode.md",
  "extensions.md",
  "index.md",
  "json-events.md",
  "notifications.md",
  "operation-outcomes.md",
  "prompts.md",
  "resources.md",
  "rpc.md",
  "settings.md",
  "skills.md",
  "subagents.md",
  "work-plans.md"
] as const)
export const productDocumentationContractPaths = Object.freeze([
  "README.md",
  ...publicProductDocumentationFiles.map(file => `docs/${file}`),
  "examples/extensions/custom-tool/README.md",
  "examples/extensions/custom-tool/index.ts",
  "examples/extensions/durable-counter/README.md",
  "examples/extensions/durable-counter/index.ts",
  "examples/extensions/herdr-agent-state/README.md",
  "examples/extensions/herdr-agent-state/index.ts",
  "examples/extensions/subagents/README.md",
  "examples/extensions/subagents/index.ts",
  "examples/rpc/README.md",
  "examples/rpc/client.ts",
  "examples/skills/review/README.md",
  "examples/skills/review/SKILL.md",
  "examples/subagents/README.md",
  "examples/subagents/pathfinder.md"
] as const)

export interface ProductDocumentationPaths {
  readonly root: string
  readonly readme: string
  readonly docs: string
  readonly examples: string
}

export function getProductDocumentationPaths(): ProductDocumentationPaths {
  return productDocumentationPaths(productRoot(import.meta.url, process.execPath, import.meta.dirname))
}

export function productDocumentationPaths(root: string): ProductDocumentationPaths {
  const resolvedRoot = resolve(root)
  return Object.freeze({
    root: resolvedRoot,
    readme: join(resolvedRoot, "README.md"),
    docs: join(resolvedRoot, "docs"),
    examples: join(resolvedRoot, "examples")
  })
}

export function productRoot(
  metaUrl: string,
  executable: string,
  sourceDirectory: string,
  hasDocumentation: (root: string) => boolean = containsProductDocumentation
): string {
  if (!isCompiledBunUrl(metaUrl)) return resolve(sourceDirectory, "../../..")

  const executableDirectory = dirname(executable)
  if (hasDocumentation(executableDirectory)) return executableDirectory
  const installedDirectory = join(executableDirectory, installedProductDirectoryName)
  return hasDocumentation(installedDirectory) ? installedDirectory : executableDirectory
}

function containsProductDocumentation(root: string): boolean {
  return productDocumentationContractPaths.every(path => existsSync(join(root, path)))
}

function isCompiledBunUrl(url: string): boolean {
  return url.includes("$bunfs") || url.includes("~BUN") || url.includes("%7EBUN")
}

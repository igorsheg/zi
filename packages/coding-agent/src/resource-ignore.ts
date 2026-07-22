import { existsSync } from "node:fs"
import { join, relative, sep } from "node:path"

import ignore from "ignore"

import { readResourceFile } from "./resource-files.js"

const ignoreFileNames = [".gitignore", ".ignore", ".fdignore"]

/** One root-scoped ignore policy shared by every directory visited during discovery. */
export class ResourceIgnore {
  readonly #root: string
  readonly #matcher = ignore()

  constructor(root: string) {
    this.#root = root
  }

  enter(directory: string): void {
    const relativeDirectory = relative(this.#root, directory)
    const prefix = relativeDirectory.length === 0 ? "" : `${toPosixPath(relativeDirectory)}/`

    for (const name of ignoreFileNames) {
      const path = join(directory, name)
      if (!existsSync(path)) continue
      try {
        const patterns = readResourceFile(path)
          .split(/\r?\n/)
          .map(line => prefixIgnorePattern(line, prefix))
          .filter((line): line is string => line !== undefined)
        if (patterns.length > 0) this.#matcher.add(patterns)
      } catch {
        // Ignore files only filter optional discovery; an invalid one does not invalidate a resource.
      }
    }
  }

  ignores(path: string, directory = false): boolean {
    const relativePath = toPosixPath(relative(this.#root, path))
    return this.#matcher.ignores(directory ? `${relativePath}/` : relativePath)
  }
}

function prefixIgnorePattern(line: string, prefix: string): string | undefined {
  const trimmed = line.trim()
  if (trimmed.length === 0 || (trimmed.startsWith("#") && !trimmed.startsWith("\\#"))) return undefined

  let pattern = line
  let negated = false
  if (pattern.startsWith("!")) {
    negated = true
    pattern = pattern.slice(1)
  } else if (pattern.startsWith("\\!")) {
    pattern = pattern.slice(1)
  }
  if (pattern.startsWith("/")) pattern = pattern.slice(1)

  const value = `${prefix}${pattern}`
  return negated ? `!${value}` : value
}

function toPosixPath(path: string): string {
  return path.split(sep).join("/")
}

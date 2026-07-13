import { homedir } from "node:os"
import { isAbsolute, resolve } from "node:path"

export function resolveToolPath(path: string, cwd: string): string {
  const expanded = path === "~" ? homedir() : path.startsWith("~/") ? resolve(homedir(), path.slice(2)) : path
  return isAbsolute(expanded) ? resolve(expanded) : resolve(cwd, expanded)
}

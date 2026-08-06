import { basename, isAbsolute, relative, resolve, sep } from "node:path"

// Pi 73414d0 applies this containment rule to compact resource reads; Zi uses it for every semantic path subject.
export function displayToolPath(cwd: string, path: string, compact: boolean): string {
  const root = resolve(cwd || ".")
  const absolute = resolve(root, path)
  const relativePath = relative(root, absolute)
  const insideCwd =
    relativePath === "" || (!isAbsolute(relativePath) && relativePath !== ".." && !relativePath.startsWith(`..${sep}`))
  if (!insideCwd) return absolute

  const localPath = isAbsolute(path) ? relativePath || "." : path
  return compact ? basename(localPath) || localPath : localPath
}

import type { ZiPaths } from "./paths.js"
import type { ProjectConfigurationAdmission } from "./project-trust.js"
import type { SettingsManager } from "./settings-manager.js"

export type ConfigurableResource = "extensions" | "skills" | "prompts"

export interface ResourceRoot {
  readonly path: string
  readonly scope: "global" | "project"
  readonly source: "settings" | "directory" | "agents"
  readonly includeRootFiles: boolean
}

/** Resolve one precedence-ordered resource catalog from admitted settings and cwd-bound paths. */
export function resolveResourceRoots(
  paths: ZiPaths,
  settings: SettingsManager | undefined,
  project: ProjectConfigurationAdmission,
  resource: ConfigurableResource
): readonly ResourceRoot[] {
  const roots: ResourceRoot[] = []
  const projectAdmitted = project === "trusted"

  addConfiguredRoots(roots, settings?.getOverrides()[resource], "global", path => paths.resolveGlobalResourcePath(path))
  if (projectAdmitted && !paths.projectConfigIsGlobal) {
    addConfiguredRoots(roots, settings?.getProject()[resource], "project", path =>
      paths.resolveProjectResourcePath(path)
    )
    roots.push(root(paths.projectResourceDir(resource), "project", "directory"))
  }
  if (projectAdmitted && resource === "skills") {
    for (const path of paths.projectAgentsSkillDirs) roots.push(root(path, "project", "agents", false))
  }

  addConfiguredRoots(roots, settings?.getGlobal()[resource], "global", path => paths.resolveGlobalResourcePath(path))
  roots.push(root(paths.globalResourceDir(resource), "global", "directory"))
  if (resource === "skills") roots.push(root(paths.globalAgentsSkillsDir, "global", "agents", false))

  return Object.freeze(roots)
}

function addConfiguredRoots(
  roots: ResourceRoot[],
  configured: readonly string[] | undefined,
  scope: ResourceRoot["scope"],
  resolve: (path: string) => string
): void {
  for (const path of configured ?? []) roots.push(root(resolve(path), scope, "settings"))
}

function root(
  path: string,
  scope: ResourceRoot["scope"],
  source: ResourceRoot["source"],
  includeRootFiles = true
): ResourceRoot {
  return Object.freeze({ path, scope, source, includeRootFiles })
}

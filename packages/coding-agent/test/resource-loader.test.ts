import { expect, test } from "bun:test"
import { mkdir, mkdtemp, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { ZiPaths } from "../src/paths.js"
import { maxResourceFileBytes } from "../src/resource-files.js"
import { maxSessionResourceBytes, ResourceLoader } from "../src/resource-loader.js"
import { SettingsManager } from "../src/settings-manager.js"

test("session resources follow cwd-bound Pi discovery and precedence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resources-"))
  const cwd = join(root, "project", "nested")
  const paths = new ZiPaths(cwd, join(root, "global"))
  await mkdir(paths.globalResourceDir("skills"), { recursive: true })
  await mkdir(paths.globalResourceDir("prompts"), { recursive: true })
  await mkdir(paths.projectResourceDir("skills"), { recursive: true })
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await mkdir(cwd, { recursive: true })

  await writeFile(join(paths.globalDir, "AGENTS.md"), "global instructions")
  await writeFile(join(dirname(cwd), "AGENTS.md"), "project instructions")
  await writeFile(join(cwd, "CLAUDE.md"), "nested instructions")
  await writeFile(paths.globalSystemPromptFile, "global system")
  await writeFile(paths.projectSystemPromptFile, "project system")
  await writeFile(paths.globalAppendSystemPromptFile, "global append")
  await writeFile(paths.projectAppendSystemPromptFile, "project append")

  await writeSkill(join(paths.globalResourceDir("skills"), "review", "SKILL.md"), "review", "global review")
  await writeSkill(join(paths.projectResourceDir("skills"), "review", "SKILL.md"), "review", "project review")
  await writeFile(
    join(paths.globalResourceDir("skills"), "direct.md"),
    "---\nname: direct\ndescription: Direct global skill\n---\nDirect body"
  )
  await writeFile(
    join(paths.globalResourceDir("prompts"), "commit.md"),
    "---\ndescription: Global commit\n---\nGlobal $1"
  )
  await writeFile(
    join(paths.projectResourceDir("prompts"), "commit.md"),
    "---\ndescription: Project commit\nargument-hint: <path>\n---\nProject $1"
  )

  const resources = await new ResourceLoader({ paths, project: "trusted" }).load()

  expect(resources.systemPrompt).toBe("project system")
  expect(resources.appendSystemPrompt).toEqual(["project append"])
  expect(resources.contextFiles).toEqual([
    { path: join(paths.globalDir, "AGENTS.md"), content: "global instructions" },
    { path: join(dirname(cwd), "AGENTS.md"), content: "project instructions" },
    { path: join(cwd, "CLAUDE.md"), content: "nested instructions" }
  ])
  expect(resources.skills.map(skill => [skill.name, skill.description, skill.scope])).toEqual([
    ["review", "project review", "project"],
    ["direct", "Direct global skill", "global"]
  ])
  expect(resources.promptTemplates).toMatchObject([
    { name: "commit", description: "Project commit", argumentHint: "<path>", content: "Project $1", scope: "project" }
  ])
  expect(resources.diagnostics).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ type: "collision", resource: "skill", name: "review" }),
      expect.objectContaining({ type: "collision", resource: "prompt-template", name: "commit" })
    ])
  )
  expect(Object.isFrozen(resources)).toBe(true)
  expect(Object.isFrozen(resources.skills)).toBe(true)
  expect(Object.isFrozen(resources.skills[0])).toBe(true)
})

test("settings add file and directory resource roots with scoped precedence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-configured-resources-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const projectSkills = join(paths.cwd, "catalog", "skills")
  const projectPrompt = join(paths.cwd, "catalog", "review.md")
  const globalSkills = join(paths.globalDir, "catalog", "skills")
  const globalPrompt = join(paths.globalDir, "catalog", "global.md")
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(
    paths.projectSettingsFile,
    JSON.stringify({ skills: ["../catalog/skills"], prompts: ["../catalog/review.md"] })
  )
  await writeFile(
    paths.globalSettingsFile,
    JSON.stringify({ skills: ["catalog/skills"], prompts: ["catalog/global.md"] })
  )
  await writeSkill(join(projectSkills, "review", "SKILL.md"), "review", "Configured project review")
  await writeSkill(join(paths.projectResourceDir("skills"), "review", "SKILL.md"), "review", "Automatic project review")
  await writeSkill(join(globalSkills, "global-custom", "SKILL.md"), "global-custom", "Configured global skill")
  await writeFile(projectPrompt, "Configured project prompt")
  await writeFile(globalPrompt, "Configured global prompt")
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await writeFile(join(paths.projectResourceDir("prompts"), "review.md"), "Automatic project prompt")

  const settingsManager = SettingsManager.create(paths, "trusted")
  const resources = await new ResourceLoader({ paths, project: "trusted", settingsManager }).load()

  expect(resources.skills.map(skill => [skill.name, skill.description, skill.scope])).toEqual([
    ["review", "Configured project review", "project"],
    ["global-custom", "Configured global skill", "global"]
  ])
  expect(resources.promptTemplates.map(prompt => [prompt.name, prompt.content, prompt.scope])).toEqual([
    ["review", "Configured project prompt", "project"],
    ["global", "Configured global prompt", "global"]
  ])
  expect(resources.diagnostics).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ type: "collision", resource: "skill", name: "review" }),
      expect.objectContaining({ type: "collision", resource: "prompt-template", name: "review" })
    ])
  )
})

test("resource loading follows settings path changes after reload", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resource-settings-reload-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await writeSkill(join(paths.globalDir, "first", "review", "SKILL.md"), "first", "First skill")
  await writeSkill(join(paths.globalDir, "second", "review", "SKILL.md"), "second", "Second skill")
  await writeFile(paths.globalSettingsFile, JSON.stringify({ skills: ["first"] }))
  const settingsManager = SettingsManager.create(paths, "absent")
  const loader = new ResourceLoader({ paths, project: "absent", settingsManager })

  expect((await loader.load()).skills.map(skill => skill.name)).toEqual(["first"])

  await writeFile(paths.globalSettingsFile, JSON.stringify({ skills: ["second"] }))
  settingsManager.reload()

  expect((await loader.load()).skills.map(skill => skill.name)).toEqual(["second"])
})

test(".agents skill discovery is trust-gated, Git-bounded, and keeps the global location user-scoped", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agents-skills-"))
  const home = join(root, "home")
  const repository = join(root, "workspace", "repository")
  const cwd = join(repository, "packages", "app")
  await mkdir(join(repository, ".git"), { recursive: true })
  await mkdir(cwd, { recursive: true })
  const paths = new ZiPaths(cwd, join(home, ".zi", "agent"), undefined, home)

  await writeSkill(join(paths.globalAgentsSkillsDir, "global-agent", "SKILL.md"), "global-agent", "Global agent skill")
  await writeFile(
    join(paths.globalAgentsSkillsDir, "direct.md"),
    "---\nname: direct\ndescription: Must not load\n---\nBody"
  )
  await writeSkill(
    join(repository, "packages", ".agents", "skills", "review", "SKILL.md"),
    "review",
    "Nearest project skill"
  )
  await writeSkill(join(repository, ".agents", "skills", "review", "SKILL.md"), "review", "Repository project skill")
  await writeSkill(
    join(root, "workspace", ".agents", "skills", "above-repository", "SKILL.md"),
    "above-repository",
    "Must not load"
  )

  const trusted = await new ResourceLoader({ paths, project: "trusted" }).load()
  const untrusted = await new ResourceLoader({ paths, project: "untrusted" }).load()

  expect(trusted.skills.map(skill => [skill.name, skill.description, skill.scope])).toEqual([
    ["review", "Nearest project skill", "project"],
    ["global-agent", "Global agent skill", "global"]
  ])
  expect(untrusted.skills.map(skill => [skill.name, skill.scope])).toEqual([["global-agent", "global"]])
  expect(trusted.skills.some(skill => skill.name === "direct" || skill.name === "above-repository")).toBe(false)
})

test("trusted .agents skills remain project-scoped when the .zi root is globally admitted", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agents-skills-global-project-"))
  const home = join(root, "home")
  const cwd = join(root, "repository")
  await mkdir(join(cwd, ".git"), { recursive: true })
  const paths = new ZiPaths(cwd, join(cwd, ".zi"), undefined, home)
  await writeSkill(join(cwd, ".agents", "skills", "project", "SKILL.md"), "project", "Project skill")

  const trusted = await new ResourceLoader({ paths, project: "trusted" }).load()
  const untrusted = await new ResourceLoader({ paths, project: "untrusted" }).load()

  expect(trusted.skills.map(skill => [skill.name, skill.scope])).toEqual([["project", "project"]])
  expect(untrusted.skills).toEqual([])
})

test("non-Git projects discover .agents skills through the filesystem ancestry", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agents-skills-non-git-"))
  const cwd = join(root, "work", "nested")
  await mkdir(cwd, { recursive: true })
  const paths = new ZiPaths(cwd, join(root, "home", ".zi", "agent"), undefined, join(root, "home"))
  await writeSkill(join(root, ".agents", "skills", "workspace", "SKILL.md"), "workspace", "Workspace skill")

  const resources = await new ResourceLoader({ paths, project: "trusted" }).load()

  expect(resources.skills.map(skill => [skill.name, skill.scope])).toEqual([["workspace", "project"]])
})

test("skill recursion and prompt discovery match Pi rules", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resource-rules-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const skills = paths.projectResourceDir("skills")
  const prompts = paths.projectResourceDir("prompts")
  await writeSkill(join(skills, "root", "SKILL.md"), "root", "Root skill")
  await writeSkill(join(skills, "root", "nested", "SKILL.md"), "nested", "Must not load")
  await writeSkill(join(skills, "group", "nested", "SKILL.md"), "nested", "Nested skill")
  await writeSkill(join(skills, ".hidden", "SKILL.md"), "hidden", "Must not load")
  await writeSkill(join(skills, "node_modules", "dependency", "SKILL.md"), "dependency", "Must not load")
  await writeSkill(join(skills, "ignored", "SKILL.md"), "ignored", "Must not load")
  await mkdir(skills, { recursive: true })
  await writeFile(join(skills, ".gitignore"), "ignored/\n")
  await mkdir(join(prompts, "nested"), { recursive: true })
  await writeFile(join(prompts, ".gitignore"), "ignored.md\n")
  await writeFile(join(prompts, ".hidden.md"), "Must not load")
  await writeFile(join(prompts, "ignored.md"), "Must not load")
  await writeFile(join(prompts, "top.md"), "Top prompt")
  await writeFile(join(prompts, "nested", "hidden.md"), "Must not load")

  const resources = await new ResourceLoader({ paths, project: "trusted" }).load()

  expect(resources.skills.map(skill => skill.name)).toEqual(["nested", "root"])
  expect(resources.promptTemplates.map(prompt => prompt.name)).toEqual(["top"])
})

test("canonical skill and prompt paths load once through project and global symlinks", async () => {
  if (process.platform === "win32") return
  const root = await mkdtemp(join(tmpdir(), "zi-resource-symlinks-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const sharedSkill = join(root, "shared", "skill")
  const sharedPrompt = join(root, "shared", "review.md")
  await writeSkill(join(sharedSkill, "SKILL.md"), "shared", "Shared skill")
  await writeFile(sharedPrompt, "Shared prompt")
  await mkdir(paths.projectResourceDir("skills"), { recursive: true })
  await mkdir(paths.globalResourceDir("skills"), { recursive: true })
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await mkdir(paths.globalResourceDir("prompts"), { recursive: true })
  await symlink(sharedSkill, join(paths.projectResourceDir("skills"), "project-link"))
  await symlink(sharedSkill, join(paths.globalResourceDir("skills"), "global-link"))
  await symlink(sharedPrompt, join(paths.projectResourceDir("prompts"), "review.md"))
  await symlink(sharedPrompt, join(paths.globalResourceDir("prompts"), "review.md"))

  const resources = await new ResourceLoader({ paths, project: "trusted" }).load()

  expect(resources.skills.map(skill => [skill.name, skill.scope])).toEqual([["shared", "project"]])
  expect(resources.promptTemplates.map(prompt => [prompt.name, prompt.scope])).toEqual([["review", "project"]])
  expect(resources.diagnostics.filter(diagnostic => diagnostic.type === "collision")).toEqual([])
})

test("session resource catalog and retained-byte bounds omit further candidates with diagnostics", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resource-bounds-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  const skills = paths.projectResourceDir("skills")
  const prompts = paths.projectResourceDir("prompts")
  await mkdir(skills, { recursive: true })
  await mkdir(prompts, { recursive: true })
  await Promise.all(
    Array.from({ length: 257 }, (_, index) => {
      const name = `skill-${String(index).padStart(3, "0")}`
      return [
        writeFile(join(skills, `${name}.md`), `---\nname: ${name}\ndescription: Skill ${index}\n---\nBody`),
        writeFile(join(prompts, `prompt-${String(index).padStart(3, "0")}.md`), `Prompt ${index}`)
      ]
    }).flat()
  )

  const catalog = await new ResourceLoader({ paths, project: "trusted" }).load()

  expect(catalog.skills).toHaveLength(256)
  expect(catalog.promptTemplates).toHaveLength(256)
  expect(catalog.diagnostics).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ type: "limit", resource: "skill", limit: 256 }),
      expect.objectContaining({ type: "limit", resource: "prompt-template", limit: 256 })
    ])
  )

  const retainedDirectories = nestedDirectories(join(root, "contexts"), 9)
  await Promise.all(
    retainedDirectories.map(async (directory, index) => {
      await mkdir(directory, { recursive: true })
      await writeFile(join(directory, "AGENTS.md"), String(index).repeat(maxResourceFileBytes))
    })
  )
  const retained = await new ResourceLoader({
    paths: new ZiPaths(retainedDirectories.at(-1)!, join(root, "empty-global")),
    project: "trusted"
  }).load()
  expect(retained.contextFiles).toHaveLength(8)
  expect(retained.diagnostics).toContainEqual(
    expect.objectContaining({ type: "limit", resource: "context", limit: maxSessionResourceBytes })
  )
})

test("context discovery stops at its file-count bound", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-context-count-"))
  const directories = nestedDirectories(root, 129)
  await Promise.all(
    directories.map(async (directory, index) => {
      await mkdir(directory, { recursive: true })
      await writeFile(join(directory, "AGENTS.md"), String(index))
    })
  )

  const resources = await new ResourceLoader({
    paths: new ZiPaths(directories.at(-1)!, join(root, "global")),
    project: "trusted"
  }).load()

  expect(resources.contextFiles).toHaveLength(128)
  expect(resources.diagnostics).toContainEqual(
    expect.objectContaining({ type: "limit", resource: "context", limit: 128 })
  )
})

test("excluded project resources stay unread while contextual instructions remain", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resource-untrusted-"))
  const cwd = join(root, "project")
  const paths = new ZiPaths(cwd, join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  const absentLoader = new ResourceLoader({ paths, project: "absent" })
  await writeFile(join(cwd, "AGENTS.md"), "context remains admitted")
  await writeFile(paths.projectSystemPromptFile, "project system")
  await writeFile(paths.globalSystemPromptFile, "global system")
  await writeFile(paths.projectAppendSystemPromptFile, "project append")
  await writeFile(paths.globalAppendSystemPromptFile, "global append")
  await writeSkill(join(paths.projectResourceDir("skills"), "review", "SKILL.md"), "review", "Project review")
  await writeSkill(join(paths.globalResourceDir("skills"), "review", "SKILL.md"), "review", "Global review")
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await mkdir(paths.globalResourceDir("prompts"), { recursive: true })
  await writeFile(join(paths.projectResourceDir("prompts"), "commit.md"), "Project prompt")
  await writeFile(join(paths.globalResourceDir("prompts"), "commit.md"), "Global prompt")

  const resources = await new ResourceLoader({ paths, project: "untrusted" }).load()
  const raced = await absentLoader.load()

  expect(resources.systemPrompt).toBe("global system")
  expect(resources.appendSystemPrompt).toEqual(["global append"])
  expect(resources.contextFiles).toContainEqual({ path: join(cwd, "AGENTS.md"), content: "context remains admitted" })
  expect(resources.skills.map(skill => [skill.name, skill.description, skill.scope])).toEqual([
    ["review", "Global review", "global"]
  ])
  expect(resources.promptTemplates.map(prompt => [prompt.name, prompt.content, prompt.scope])).toEqual([
    ["commit", "Global prompt", "global"]
  ])
  expect(resources.diagnostics.filter(diagnostic => diagnostic.type === "collision")).toEqual([])
  expect(raced).toEqual(resources)
})

test("invalid project resources diagnose and fall back to valid global resources", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-resource-fallback-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "global"))
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(paths.globalDir, { recursive: true })
  await writeFile(paths.projectSystemPromptFile, "x".repeat(maxResourceFileBytes + 1))
  await writeFile(paths.globalSystemPromptFile, "global fallback")
  await writeSkill(join(paths.projectResourceDir("skills"), "deploy", "SKILL.md"), "deploy", undefined)
  await writeSkill(join(paths.globalResourceDir("skills"), "deploy", "SKILL.md"), "deploy", "Global deploy")
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await mkdir(paths.globalResourceDir("prompts"), { recursive: true })
  await writeFile(join(paths.projectResourceDir("prompts"), "review.md"), "---\ninvalid: [\n---\nProject")
  await writeFile(join(paths.globalResourceDir("prompts"), "review.md"), "Global review")

  const resources = await new ResourceLoader({ paths, project: "trusted" }).load()

  expect(resources.systemPrompt).toBe("global fallback")
  expect(resources.skills.map(skill => [skill.name, skill.scope])).toEqual([["deploy", "global"]])
  expect(resources.promptTemplates.map(prompt => [prompt.name, prompt.scope])).toEqual([["review", "global"]])
  expect(resources.diagnostics).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ type: "limit", resource: "system-prompt" }),
      expect.objectContaining({ type: "warning", resource: "skill", message: "description is required" }),
      expect.objectContaining({ type: "warning", resource: "prompt-template" })
    ])
  )
})

function nestedDirectories(root: string, count: number): readonly string[] {
  const directories: string[] = []
  let directory = root
  for (let index = 0; index < count; index++) {
    directory = join(directory, `d${index}`)
    directories.push(directory)
  }
  return directories
}

async function writeSkill(path: string, name: string, description: string | undefined): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(
    path,
    `---\nname: ${name}\n${description === undefined ? "" : `description: ${description}\n`}---\n# ${name}\n\nSkill body.`
  )
}

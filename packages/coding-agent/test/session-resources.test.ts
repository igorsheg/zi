import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Context } from "@earendil-works/pi-ai"

import { ZiPaths } from "../src/paths.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider
} from "../src/testing.js"

test("AgentSession owns resource catalogs, prompt construction, and command expansion", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-session-resources-"))
  const globalDir = join(cwd, "global")
  const paths = new ZiPaths(cwd, globalDir)
  const skillPath = join(paths.projectResourceDir("skills"), "review", "SKILL.md")
  await mkdir(join(paths.projectResourceDir("skills"), "review"), { recursive: true })
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await writeFile(
    skillPath,
    "---\nname: review-skill\ndescription: Review with the project rules\n---\n# Review Skill\n\nUse the private skill body."
  )
  await writeFile(
    join(paths.projectResourceDir("prompts"), "review.md"),
    "---\ndescription: Review one file\nargument-hint: <path>\n---\nReview $1 carefully."
  )

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const contexts: Context[] = []
  faux.setResponses([
    context => {
      contexts.push(context)
      return fauxAssistantMessage("template complete")
    },
    context => {
      contexts.push(context)
      return fauxAssistantMessage("skill complete")
    },
    context => {
      contexts.push(context)
      return fauxAssistantMessage("resources reloaded")
    },
    context => {
      contexts.push(context)
      return fauxAssistantMessage("tools changed")
    },
    context => {
      contexts.push(context)
      return fauxAssistantMessage("tools stable")
    }
  ])
  const { session } = await createAgentRuntime({
    cwd,
    agentDir: globalDir,
    models,
    projectTrust: { type: "trusted", cwd, source: "runtime" },
    session: { type: "new", persist: false }
  })

  try {
    expect(session.promptTemplates.map(template => template.name)).toEqual(["review"])
    expect(session.skills.map(skill => skill.name)).toEqual(["review-skill"])
    expect(session.listResourceCommands()).toEqual([
      { name: "review", description: "Review one file", argumentHint: "<path>" },
      { name: "skill:review-skill", description: "Review with the project rules" }
    ])
    expect(session.resources).toBe(session.resources)
    expect(Object.isFrozen(session.resources)).toBe(true)

    await session.prompt("/review src/index.ts")
    await session.prompt("/skill:review-skill focus on correctness")

    expect(latestUserText(contexts[0]!)).toBe("Review src/index.ts carefully.")
    expect(latestUserText(contexts[1]!)).toContain("Use the private skill body.\n</skill>\n\nfocus on correctness")
    expect(contexts[0]!.systemPrompt).toContain("<name>review-skill</name>")
    expect(contexts[0]!.systemPrompt).toContain(skillPath)
    expect(contexts[0]!.systemPrompt).not.toContain("Use the private skill body.")

    await writeFile(paths.projectAppendSystemPromptFile, "Reloaded policy")
    await session.reload()
    await session.prompt("continue after reload")
    expect(contexts[2]!.systemPrompt).toContain("Reloaded policy")

    session.setActiveTools([])
    await session.prompt("continue without tools")
    await session.prompt("continue with stable tools")
    expect(contexts[3]!.systemPrompt).not.toContain("<available_skills>")
    expect(contexts[3]!.systemPrompt).not.toBe(contexts[2]!.systemPrompt)
    expect(toolSchemas(contexts[3]!)).not.toEqual(toolSchemas(contexts[2]!))
    expect(contexts[4]!.systemPrompt).toBe(contexts[3]!.systemPrompt)
    expect(toolSchemas(contexts[4]!)).toEqual(toolSchemas(contexts[3]!))
  } finally {
    session.dispose()
  }
})

test("runtime resource assembly consumes configured settings paths", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-session-configured-resources-"))
  const globalDir = join(cwd, "global")
  const skillPath = join(globalDir, "configured-skills", "review", "SKILL.md")
  await mkdir(join(globalDir, "configured-skills", "review"), { recursive: true })
  await writeFile(join(globalDir, "settings.json"), JSON.stringify({ skills: ["configured-skills"] }))
  await writeFile(
    skillPath,
    "---\nname: configured\ndescription: Configured runtime skill\n---\nUse the configured skill."
  )

  const { session } = await createAgentRuntime({
    cwd,
    agentDir: globalDir,
    models: createModels(),
    session: { type: "new", persist: false }
  })

  try {
    expect(session.skills.map(skill => [skill.name, skill.filePath])).toEqual([["configured", skillPath]])
  } finally {
    session.dispose()
  }
})

test("steering and follow-up queues retain expanded resource input", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "zi-queued-resources-"))
  const paths = new ZiPaths(cwd, join(cwd, "global"))
  await mkdir(paths.projectResourceDir("prompts"), { recursive: true })
  await writeFile(join(paths.projectResourceDir("prompts"), "review.md"), "Review $1 carefully.")

  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const started = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    async () => {
      started.resolve()
      await release.promise
      return fauxAssistantMessage("first")
    },
    fauxAssistantMessage("steering"),
    fauxAssistantMessage("follow-up")
  ])
  const { session } = await createAgentRuntime({
    cwd,
    agentDir: paths.globalDir,
    models,
    projectTrust: { type: "trusted", cwd, source: "runtime" },
    session: { type: "new", persist: false }
  })

  try {
    const run = session.prompt("start")
    await started.promise
    session.steer("/review steering.ts")
    session.followUp("/review follow-up.ts")
    expect(session.queuedInputs.steering.map(input => input.text)).toEqual(["Review steering.ts carefully."])
    expect(session.queuedInputs.followUp.map(input => input.text)).toEqual(["Review follow-up.ts carefully."])
    release.resolve()
    await run
  } finally {
    session.dispose()
  }
})

function toolSchemas(context: Context) {
  return context.tools?.map(tool => ({ name: tool.name, description: tool.description, parameters: tool.parameters }))
}

function latestUserText(context: Context): string {
  const message = context.messages.findLast(candidate => candidate.role === "user")
  if (!message || !Array.isArray(message.content)) return ""
  return message.content.flatMap(part => (part.type === "text" ? [part.text] : [])).join("\n")
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

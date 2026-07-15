import { expect, test } from "bun:test"
import { mkdir, mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { OpenZiPaths } from "../src/paths.js"
import { DefaultResourceLoader } from "../src/resource-loader.js"

test("resources follow one cwd-bound global and project path policy", async () => {
  const root = await mkdtemp(join(tmpdir(), "openzi-resources-"))
  const cwd = join(root, "project", "nested")
  const paths = new OpenZiPaths(cwd, join(root, "global"))
  await mkdir(paths.globalDir, { recursive: true })
  await mkdir(paths.projectDir, { recursive: true })
  await mkdir(cwd, { recursive: true })
  await writeFile(join(paths.globalDir, "AGENTS.md"), "global instructions")
  await writeFile(join(dirname(cwd), "AGENTS.md"), "project instructions")
  await writeFile(join(cwd, "CLAUDE.md"), "nested instructions")
  await writeFile(paths.globalSystemPromptFile, "global system")
  await writeFile(paths.projectSystemPromptFile, "project system")
  await writeFile(paths.globalAppendSystemPromptFile, "global append")
  await writeFile(paths.projectAppendSystemPromptFile, "project append")

  const loader = new DefaultResourceLoader({ paths })
  await loader.reload()

  expect(loader.get()).toEqual({
    systemPrompt: "project system",
    appendSystemPrompt: ["project append"],
    contextFiles: [
      { path: join(paths.globalDir, "AGENTS.md"), content: "global instructions" },
      { path: join(dirname(cwd), "AGENTS.md"), content: "project instructions" },
      { path: join(cwd, "CLAUDE.md"), content: "nested instructions" }
    ]
  })
})

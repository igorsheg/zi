import { rm } from "node:fs/promises"
import { join } from "node:path"

import { CodeMode, isCodeModeDetails } from "../packages/coding-agent/src/code-mode/code-mode.js"
import type { CodeModeCapableTool } from "../packages/coding-agent/src/code-mode/tool-contract.js"
import { createReadTool } from "../packages/coding-agent/src/tools/read.js"

async function statsResult() {
  return { content: [{ type: "text" as const, text: "3 files, 12 lines" }], details: { files: 3, lines: 12 } }
}

export async function runCodeModeAcceptance(options: {
  readonly executable: string
  readonly cwd?: string
}): Promise<void> {
  const cwd = options.cwd ?? import.meta.dirname
  const input = join(cwd, ".zi-code-mode-acceptance")
  await Bun.write(input, "compiled\nisolated\nbounded\n")
  try {
    const readTool = createReadTool(cwd)
    const statsTool: CodeModeCapableTool = {
      name: "acceptance_stats",
      label: "acceptance stats",
      description: "Return structured acceptance statistics",
      parameters: readTool.parameters,
      execute: statsResult,
      codeMode: {
        outputSchema: {
          type: "object",
          properties: { files: { type: "number" }, lines: { type: "number" } },
          required: ["files", "lines"]
        },
        async execute() {
          return { result: await statsResult(), value: { files: 3, lines: 12 } }
        }
      }
    }
    const tool = new CodeMode(cwd, [options.executable]).createTool([readTool, statsTool])
    const result = await tool.execute(
      "compiled-acceptance",
      {
        code: `async () => {
  const catalog = await Promise.resolve(zi);
  const file = await zi.read({ path: ".zi-code-mode-acceptance" });
  const stats = await zi.acceptance_stats({ path: ".zi-code-mode-acceptance" });
  return {
    content: file,
    lines: stats.lines,
    catalog: catalog === zi,
    then: typeof zi.then,
    unknown: typeof zi.notATool,
    keys: Object.keys(zi),
    frozen: Object.isFrozen(zi),
    process: typeof process,
    bun: typeof Bun,
    require: typeof require,
    fetch: typeof fetch,
    bridge: typeof __ziHostCall
  };
}`
      },
      undefined
    )
    if (!isCodeModeDetails(result.details) || result.details.outcome !== "success") {
      throw new Error(`Compiled code mode failed: ${JSON.stringify(result)}`)
    }
    if (result.details.calls.length !== 2 || result.details.calls.some(call => call.state !== "succeeded")) {
      throw new Error(`Compiled code mode returned an invalid nested trace: ${JSON.stringify(result.details)}`)
    }
    const text = result.content[0]?.type === "text" ? result.content[0].text : ""
    if (
      !text.includes("compiled\\nisolated\\nbounded") ||
      !text.includes('"lines": 12') ||
      !text.includes('"catalog": true') ||
      !text.includes('"then": "undefined"') ||
      !text.includes('"unknown": "undefined"') ||
      !text.includes('"keys": [') ||
      !text.includes('"read"') ||
      !text.includes('"frozen": true') ||
      !text.includes('"process": "undefined"') ||
      !text.includes('"bridge": "undefined"')
    ) {
      throw new Error(`Compiled code mode leaked ambient authority or lost its result: ${text}`)
    }

    const interrupted = await tool.execute("compiled-interrupt", { code: `async () => { while (true) {} }` }, undefined)
    if (!isCodeModeDetails(interrupted.details) || interrupted.details.outcome !== "error") {
      throw new Error(`Compiled code mode did not interrupt a busy guest: ${JSON.stringify(interrupted)}`)
    }
  } finally {
    await rm(input, { force: true })
  }
}

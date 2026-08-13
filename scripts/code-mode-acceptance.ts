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
  let codeMode: CodeMode | undefined
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
    codeMode = new CodeMode(cwd, [options.executable])
    const tool = codeMode.createTool([readTool, statsTool])
    const result = await tool.execute(
      "compiled-acceptance",
      {
        description: "Inspect the compiled Code Mode runtime",
        code: `
  const catalog: typeof zi = await Promise.resolve(zi);
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
    bridge: typeof __ziHostCall,
    imported: typeof (await project.import("node:path")).join
  };
`
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
      !text.includes('"process": "object"') ||
      !text.includes('"bun": "object"') ||
      !text.includes('"fetch": "function"') ||
      !text.includes('"bridge": "undefined"') ||
      !text.includes('"imported": "function"')
    ) {
      throw new Error(`Compiled code mode lost ambient authority or its result: ${text}`)
    }

    await tool.execute(
      "compiled-state",
      {
        description: "Persist compiled runtime state",
        code: `state.compiled = true; scratch.marker = new Map([["ready", 1]]);`
      },
      undefined
    )
    const retained = await tool.execute(
      "compiled-retained",
      {
        description: "Read retained compiled runtime state",
        code: `return { state: state.compiled, scratch: scratch.marker.get("ready") }`
      },
      undefined
    )
    if (
      retained.content[0]?.type !== "text" ||
      !retained.content[0].text.includes('"state": true') ||
      !retained.content[0].text.includes('"scratch": 1')
    ) {
      throw new Error(`Compiled code mode did not retain cell memory: ${JSON.stringify(retained)}`)
    }

    const controller = new AbortController()
    const interrupted = tool.execute(
      "compiled-interrupt",
      { description: "Exercise compiled runtime interruption", code: `while (true) {}` },
      controller.signal
    )
    await Bun.sleep(50)
    controller.abort(new Error("compiled interrupt"))
    try {
      await interrupted
      throw new Error("Compiled code mode did not interrupt a busy cell")
    } catch (cause) {
      if (!(cause instanceof Error) || !cause.message.includes("compiled interrupt")) throw cause
    }
    const recovered = await tool.execute(
      "compiled-recovered",
      {
        description: "Verify compiled runtime recovery",
        code: `return { state: state.compiled, scratch: scratch.marker ?? null }`
      },
      undefined
    )
    if (
      recovered.content[0]?.type !== "text" ||
      !recovered.content[0].text.includes('"state": true') ||
      !recovered.content[0].text.includes('"scratch": null')
    ) {
      throw new Error(`Compiled code mode did not recover after interruption: ${JSON.stringify(recovered)}`)
    }
  } finally {
    await codeMode?.dispose()
    await rm(input, { force: true })
  }
}

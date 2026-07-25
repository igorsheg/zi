import { expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { maxExternalEditorContentBytes, SystemExternalEditor } from "../../src/interactive/external-editor.js"

const fixture = fileURLToPath(new URL("./fixtures/fake-external-editor.mjs", import.meta.url))

test("system external editor uses a private prompt file and restores the terminal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-external-editor-test-"))
  const capture = join(root, "capture.json")
  const terminal = new FakeTerminal()
  const editor = new SystemExternalEditor(terminal)

  try {
    const result = await editor.edit({
      command: `${process.execPath} ${fixture} ${capture}`,
      content: "original",
      cwd: root
    })
    const recorded: unknown = JSON.parse(await readFile(capture, "utf8"))
    if (!isEditorCapture(recorded)) throw new Error("Invalid editor capture")

    expect(result).toEqual({ type: "complete", content: "edited" })
    expect(recorded.content).toBe("original")
    expect(recorded.entries).toEqual(["prompt.md"])
    if (process.platform !== "win32") expect(recorded.directoryMode & 0o077).toBe(0)
    expect(existsSync(dirname(recorded.file))).toBe(false)
    expect(terminal.transitions).toEqual(["suspend", "resume", "render"])
  } finally {
    editor.dispose()
    await rm(root, { recursive: true, force: true })
  }
})

test("system external editor bounds edited content and preserves terminal ownership on failure", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-external-editor-failure-"))
  const capture = join(root, "capture.json")
  const terminal = new FakeTerminal()
  const editor = new SystemExternalEditor(terminal)

  try {
    const failed = await editor.edit({
      command: `${process.execPath} ${fixture} ${capture} fail`,
      content: "original",
      cwd: root
    })
    expect(failed).toEqual({ type: "failed", message: "External editor exited with code 7" })

    const oversized = await editor.edit({
      command: `${process.execPath} ${fixture} ${capture} oversized`,
      content: "original",
      cwd: root
    })
    expect(oversized).toEqual({ type: "failed", message: "Edited prompt exceeds the 1 MiB limit" })

    const rejected = await editor.edit({
      command: `${process.execPath} ${fixture} ${capture}`,
      content: "x".repeat(maxExternalEditorContentBytes + 1),
      cwd: root
    })
    expect(rejected).toEqual({ type: "failed", message: "Prompt exceeds the 1 MiB external editor limit" })
    expect(terminal.transitions).toEqual(["suspend", "resume", "render", "suspend", "resume", "render"])
  } finally {
    editor.dispose()
    await rm(root, { recursive: true, force: true })
  }
})

test("disposing an active external editor kills its child and restores the terminal once", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-external-editor-dispose-"))
  const capture = join(root, "capture.json")
  const terminal = new FakeTerminal()
  const editor = new SystemExternalEditor(terminal)

  try {
    const editing = editor.edit({
      command: `${process.execPath} ${fixture} ${capture} wait`,
      content: "original",
      cwd: root
    })
    expect(
      await editor.edit({ command: `${process.execPath} ${fixture} ${capture}`, content: "second", cwd: root })
    ).toEqual({ type: "failed", message: "External editor is already open" })
    editor.dispose()

    expect(await editing).toMatchObject({ type: "failed" })
    expect(terminal.transitions).toEqual(["suspend", "resume", "render"])
    expect(
      await editor.edit({ command: `${process.execPath} ${fixture} ${capture}`, content: "original", cwd: root })
    ).toEqual({ type: "failed", message: "External editor is unavailable" })
  } finally {
    editor.dispose()
    await rm(root, { recursive: true, force: true })
  }
})

function isEditorCapture(
  value: unknown
): value is { file: string; content: string; entries: string[]; directoryMode: number } {
  if (typeof value !== "object" || value === null) return false
  if (!("file" in value) || typeof value.file !== "string") return false
  if (!("content" in value) || typeof value.content !== "string") return false
  if (!("directoryMode" in value) || typeof value.directoryMode !== "number") return false
  return "entries" in value && Array.isArray(value.entries) && value.entries.every(entry => typeof entry === "string")
}

class FakeTerminal {
  readonly transitions: string[] = []
  isDestroyed = false

  suspend(): void {
    this.transitions.push("suspend")
  }

  resume(): void {
    this.transitions.push("resume")
  }

  requestRender(): void {
    this.transitions.push("render")
  }
}

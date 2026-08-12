import { expect, test } from "bun:test"

import {
  InteractiveKeybindings,
  maxKeysPerBinding,
  type InteractiveKeyEvent
} from "../../src/interactive/interactive-keybindings.js"

test("interactive keybindings resolve semantic prompt and transcript actions", () => {
  const keybindings = new InteractiveKeybindings()

  expect(keybindings.promptAction(key("return"), context())).toBe("submit")
  expect(keybindings.promptAction(key("return", { meta: true }), context())).toBe("follow_up")
  expect(keybindings.promptAction(key("return", { ctrl: true }), context())).toBe("consume")
  expect(keybindings.promptAction(key("return", { ctrl: true }), { ...context(), editorEmpty: false })).toBe(
    "interrupt_send"
  )
  expect(keybindings.promptAction(key("return", { ctrl: true }), { ...context(), hasImages: true })).toBe(
    "interrupt_send"
  )
  expect(
    keybindings.promptAction(key("return", { ctrl: true }), { ...context(), editorEmpty: false, interruptible: false })
  ).toBe("consume")
  expect(keybindings.promptAction(key("escape"), context())).toBe("interrupt")
  expect(keybindings.promptAction(key("g", { ctrl: true }), context())).toBe("background_task")
  expect(
    keybindings.promptAction(key("v", process.platform === "win32" ? { meta: true } : { ctrl: true }), context())
  ).toBe("paste_clipboard")
  expect(keybindings.promptAction(key("g", { ctrl: true }), { ...context(), foregroundShellTask: false })).toBe(
    "external_editor"
  )
  expect(
    keybindings.promptAction(key("g", { ctrl: true }), {
      ...context(),
      foregroundShellTask: false,
      externalEditorEnabled: false
    })
  ).toBeUndefined()
  expect(keybindings.promptAction(key("z", { ctrl: true }), context())).toBe("undo")
  expect(keybindings.promptAction(key("c", { ctrl: true }), context())).toBe("clear")
  expect(keybindings.promptAction(key("d", { ctrl: true }), { ...context(), editorEmpty: false })).toBeUndefined()
  expect(keybindings.promptAction(key("d", { ctrl: true }), { ...context(), hasImages: true })).toBeUndefined()
  expect(keybindings.promptAction(key("escape"), { ...context(), streaming: false })).toBeUndefined()
  expect(keybindings.promptAction(key("up"), context())).toBe("history_previous")
  expect(keybindings.promptAction(key("down"), context())).toBe("history_next")
  expect(keybindings.promptAction(key("up"), { ...context(), historyEnabled: false })).toBeUndefined()
  expect(keybindings.matches(key("c", { ctrl: true }), "app.selection.copy")).toBe(true)
  expect(keybindings.matches(key("c", { super: true }), "app.selection.copy")).toBe(process.platform === "darwin")

  expect(keybindings.promptAction(key("return"), context(true))).toBe("picker_confirm")
  expect(keybindings.promptAction(key("tab"), context(true))).toBe("picker_complete")
  expect(keybindings.promptAction(key("escape"), context(true))).toBe("picker_cancel")
  expect(keybindings.promptAction(key("up"), context(true))).toBe("picker_up")
  expect(keybindings.promptAction(key("down"), context(true))).toBe("picker_down")
  expect(keybindings.promptAction(key("up", { meta: true }), context(true))).toBe("consume")
  expect(keybindings.promptAction(key("return", { option: true }), context())).toBe("follow_up")

  expect(keybindings.transcriptAction(key("pageup"))).toBe("page_up")
  expect(keybindings.transcriptAction(key("up", { ctrl: true, meta: true }))).toBe("line_up")
  expect(keybindings.transcriptAction(key("end", { ctrl: true }))).toBe("tail")
  expect(keybindings.transcriptAction(key("p", { ctrl: true }))).toBeUndefined()
  expect(keybindings.togglesWorkPlan(key("p", { ctrl: true }))).toBe(true)
  expect(keybindings.togglesWorkPlan(key("p", { meta: true }))).toBe(false)

  expect(keybindings.workspaceContextAction(key("escape"), true)).toBe("primary")
  expect(keybindings.workspaceContextAction(key("q"), true)).toBe("close")
  expect(keybindings.workspaceContextAction(key("q"), false)).toBeUndefined()
  expect(keybindings.matches(key("w", { ctrl: true }), "app.workspace.prefix")).toBe(true)
  expect(keybindings.workspaceChordAction(key("h"))).toBe("focus_left")
  expect(keybindings.workspaceChordAction(key("j"))).toBe("focus_down")
  expect(keybindings.workspaceChordAction(key("k"))).toBe("focus_up")
  expect(keybindings.workspaceChordAction(key("l"))).toBe("focus_right")
  expect(keybindings.workspaceChordAction(key("right"))).toBeUndefined()
  expect(keybindings.workspaceChordAction(key("q"))).toBeUndefined()
})

test("interactive keybinding overrides rebind and disable semantic actions per mode", () => {
  const keybindings = new InteractiveKeybindings({
    "app.clear": ["ctrl+x"],
    "app.exit": [],
    "app.editor.external": ["ctrl+e"],
    "app.editor.undo": ["ctrl+u"],
    "app.plan.toggle": ["ctrl+y"],
    "app.workspace.prefix": ["ctrl+b"],
    "app.workspace.close": [],
    "tui.input.historyPrevious": ["ctrl+p"],
    "tui.input.historyNext": []
  })

  expect(keybindings.promptAction(key("c", { ctrl: true }), context())).toBeUndefined()
  expect(keybindings.promptAction(key("x", { ctrl: true }), context())).toBe("clear")
  expect(keybindings.promptAction(key("d", { ctrl: true }), context())).toBeUndefined()
  expect(keybindings.promptAction(key("e", { ctrl: true }), { ...context(), foregroundShellTask: false })).toBe(
    "external_editor"
  )
  expect(keybindings.promptAction(key("z", { ctrl: true }), context())).toBeUndefined()
  expect(keybindings.promptAction(key("u", { ctrl: true }), context())).toBe("undo")
  expect(keybindings.promptAction(key("up"), context())).toBeUndefined()
  expect(keybindings.promptAction(key("p", { ctrl: true }), context())).toBe("history_previous")
  expect(keybindings.promptAction(key("down"), context())).toBeUndefined()
  expect(keybindings.togglesWorkPlan(key("p", { ctrl: true }))).toBe(false)
  expect(keybindings.togglesWorkPlan(key("y", { ctrl: true }))).toBe(true)
  expect(keybindings.matches(key("w", { ctrl: true }), "app.workspace.prefix")).toBe(false)
  expect(keybindings.matches(key("b", { ctrl: true }), "app.workspace.prefix")).toBe(true)
  expect(keybindings.workspaceContextAction(key("q"), true)).toBeUndefined()
  expect(keybindings.getKeys("app.clear")).toEqual(["ctrl+x"])
  expect(() => new InteractiveKeybindings({ "app.clear": ["wat+ctrl+x"] })).toThrow("Unknown key modifier")
})

test("interactive keybindings expose resolved metadata for help and future shortcut conflicts", () => {
  const keybindings = new InteractiveKeybindings({ "app.message.dequeue": ["ctrl+r"] })

  expect(keybindings.get("app.clear")).toEqual({
    id: "app.clear",
    keys: ["ctrl+c"],
    description: "Clear editor or exit on a second press",
    extension: "reserved"
  })
  expect(keybindings.get("app.message.dequeue")).toEqual({
    id: "app.message.dequeue",
    keys: ["ctrl+r"],
    description: "Restore queued messages",
    extension: "overridable"
  })
  expect(keybindings.list().map(binding => binding.id)).toContain("app.transcript.tail")
  expect(keybindings.getHint("app.clipboard.paste")).toBe(process.platform === "win32" ? "Alt+V" : "Ctrl+V")
  expect(keybindings.getKeys("app.selection.copy")).toEqual(
    process.platform === "darwin" ? ["super+c", "ctrl+c"] : ["ctrl+c"]
  )
  expect(keybindings.getHint("app.selection.copy")).toBe(process.platform === "darwin" ? "Cmd+C" : "Ctrl+C")
  expect(keybindings.getHint("app.tools.expand")).toBe("Ctrl+O")
  expect(keybindings.getHint("app.plan.toggle")).toBe("Ctrl+P")
  expect(keybindings.getHint("app.workspace.prefix")).toBe("Ctrl+W")
  expect(keybindings.getHint("app.editor.external")).toBe("Ctrl+G")
  expect(keybindings.getHint("app.editor.undo")).toBe("Ctrl+Z")
  expect(keybindings.getHint("app.message.interruptAndSend")).toBe("Ctrl+Enter")
  expect(keybindings.getHint("app.transcript.tail")).toBe("Ctrl+End")
  expect(keybindings.getHint("tui.select.confirm")).toBe("Enter")
  expect(keybindings.getConflicts()).toEqual([])
  expect(keybindings.get("tui.input.historyPrevious")).toEqual({
    id: "tui.input.historyPrevious",
    keys: ["up"],
    description: "Previous session prompt",
    extension: "overridable"
  })
})

test("interactive keybindings normalize duplicates and report override conflicts", () => {
  const keybindings = new InteractiveKeybindings({ "app.clear": ["CTRL+X", "ctrl+x"], "app.exit": ["ctrl+x"] })

  expect(keybindings.getKeys("app.clear")).toEqual(["ctrl+x"])
  expect(keybindings.getConflicts()).toEqual([{ key: "ctrl+x", keybindings: ["app.clear", "app.exit"] }])

  const defaultConflict = new InteractiveKeybindings({ "app.plan.toggle": ["return"] })
  expect(defaultConflict.getConflicts()).toEqual([
    { key: "return", keybindings: ["tui.input.submit", "tui.select.confirm", "app.plan.toggle"] }
  ])
  expect(defaultConflict.transcriptAction(key("return"))).toBeUndefined()

  const transcriptConflict = new InteractiveKeybindings({ "app.plan.toggle": ["ctrl+end"] })
  expect(transcriptConflict.transcriptAction(key("end", { ctrl: true }))).toBe("tail")
})

test("interactive keybinding overrides reject unknown actions and unbounded key lists", () => {
  const keys = Array.from({ length: maxKeysPerBinding + 1 }, (_, index) => `ctrl+key${index}`)
  expect(() => new InteractiveKeybindings({ "app.clear": keys })).toThrow(`${maxKeysPerBinding}`)

  const unknown: Record<string, readonly string[]> = { "app.unknown": ["ctrl+u"] }
  expect(() => new InteractiveKeybindings(unknown)).toThrow("Unknown interactive keybinding")
})

function context(pickerOpen = false) {
  return {
    pickerOpen,
    editorEmpty: true,
    hasImages: false,
    streaming: true,
    interruptible: true,
    foregroundShellTask: true,
    externalEditorEnabled: true,
    historyEnabled: !pickerOpen
  }
}

function key(
  name: string,
  modifiers: Partial<Pick<InteractiveKeyEvent, "ctrl" | "meta" | "option" | "shift" | "super" | "hyper">> = {}
): InteractiveKeyEvent {
  return { name, ctrl: false, meta: false, option: false, shift: false, super: false, hyper: false, ...modifiers }
}

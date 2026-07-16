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
  expect(keybindings.promptAction(key("escape"), context())).toBe("interrupt")
  expect(keybindings.promptAction(key("g", { ctrl: true }), context())).toBe("background_task")
  expect(
    keybindings.promptAction(key("g", { ctrl: true }), { ...context(), foregroundShellTask: false })
  ).toBeUndefined()
  expect(keybindings.promptAction(key("c", { ctrl: true }), context())).toBe("clear")
  expect(keybindings.promptAction(key("d", { ctrl: true }), { ...context(), editorEmpty: false })).toBeUndefined()
  expect(keybindings.promptAction(key("escape"), { ...context(), streaming: false })).toBeUndefined()

  expect(keybindings.promptAction(key("return"), context(true))).toBe("picker_confirm")
  expect(keybindings.promptAction(key("tab"), context(true))).toBe("picker_complete")
  expect(keybindings.promptAction(key("escape"), context(true))).toBe("picker_cancel")
  expect(keybindings.promptAction(key("up", { meta: true }), context(true))).toBe("consume")

  expect(keybindings.transcriptAction(key("pageup"))).toBe("page_up")
  expect(keybindings.transcriptAction(key("up", { ctrl: true, meta: true }))).toBe("line_up")
  expect(keybindings.transcriptAction(key("end", { ctrl: true }))).toBe("tail")
})

test("interactive keybinding overrides rebind and disable semantic actions per mode", () => {
  const keybindings = new InteractiveKeybindings({ "app.clear": ["ctrl+x"], "app.exit": [] })

  expect(keybindings.promptAction(key("c", { ctrl: true }), context())).toBeUndefined()
  expect(keybindings.promptAction(key("x", { ctrl: true }), context())).toBe("clear")
  expect(keybindings.promptAction(key("d", { ctrl: true }), context())).toBeUndefined()
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
  expect(keybindings.getHint("app.transcript.tail")).toBe("Ctrl+End")
  expect(keybindings.getHint("tui.select.confirm")).toBe("Enter")
})

test("interactive keybindings normalize duplicates and report override conflicts", () => {
  const keybindings = new InteractiveKeybindings({ "app.clear": ["CTRL+X", "ctrl+x"], "app.exit": ["ctrl+x"] })

  expect(keybindings.getKeys("app.clear")).toEqual(["ctrl+x"])
  expect(keybindings.getConflicts()).toEqual([{ key: "ctrl+x", keybindings: ["app.clear", "app.exit"] }])
})

test("interactive keybinding overrides reject unknown actions and unbounded key lists", () => {
  const keys = Array.from({ length: maxKeysPerBinding + 1 }, (_, index) => `ctrl+key${index}`)
  expect(() => new InteractiveKeybindings({ "app.clear": keys })).toThrow(`${maxKeysPerBinding}`)

  const unknown: Record<string, readonly string[]> = { "app.unknown": ["ctrl+u"] }
  expect(() => new InteractiveKeybindings(unknown)).toThrow("Unknown interactive keybinding")
})

function context(pickerOpen = false) {
  return { pickerOpen, editorEmpty: true, streaming: true, foregroundShellTask: true }
}

function key(
  name: string,
  modifiers: Partial<Pick<InteractiveKeyEvent, "ctrl" | "meta" | "shift" | "super" | "hyper">> = {}
): InteractiveKeyEvent {
  return { name, ctrl: false, meta: false, shift: false, super: false, hyper: false, ...modifiers }
}

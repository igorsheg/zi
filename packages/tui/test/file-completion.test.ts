import { expect, test } from "bun:test"

import { promptTextWidth } from "../src/components/cell-text.js"
import {
  FileCompletionController,
  fileCompletionCandidateId,
  fileCompletionInputFromText,
  formatFileReference,
  parseFileCompletionContext as parseFileCompletionInput,
  type FileCompletionContext,
  type FileCompletionSearchSession
} from "../src/interactive/prompt/file-completion.js"
import { createPickerStack } from "../src/interactive/prompt/picker.js"

test("file context parsing recognizes boundaries, the rightmost token, and complete replacement ranges", () => {
  const text = "界 prose (@src/old.ts) and @other"
  const cursor = promptTextWidth("界 prose (@src/")
  expect(parseFileCompletionContext(text, cursor)).toEqual({
    triggerStart: promptTextWidth("界 prose ("),
    tokenEnd: promptTextWidth("界 prose (@src/old.ts)"),
    cursorOffset: cursor,
    query: "src/",
    quoted: false
  })

  expect(parseFileCompletionContext("@first and @second", promptTextWidth("@first and @sec"))).toMatchObject({
    triggerStart: promptTextWidth("@first and "),
    query: "sec"
  })
  expect(parseFileCompletionContext("user@example.com", promptTextWidth("user@example"))).toBeUndefined()
  expect(parseFileCompletionContext("name_@value", promptTextWidth("name_@val"))).toBeUndefined()
  expect(parseFileCompletionContext("(@src", promptTextWidth("(@src"))).toMatchObject({ query: "src" })
})

test("quoted parsing uses display offsets and owns one manually typed closing quote", () => {
  const text = '🙂 @"my folder/old.ts" suffix'
  const cursor = promptTextWidth('🙂 @"my folder/')
  expect(parseFileCompletionContext(text, cursor)).toEqual({
    triggerStart: promptTextWidth("🙂 "),
    tokenEnd: promptTextWidth('🙂 @"my folder/old.ts"'),
    cursorOffset: cursor,
    query: "my folder/",
    quoted: true
  })
  expect(parseFileCompletionContext(text, promptTextWidth('🙂 @"my folder/old.ts"'))).toBeUndefined()
})

test("file contexts reject out-of-project and malformed queries", () => {
  for (const text of ["@../secret", "@/absolute", "@~/secret", "@C:/secret", "@\\\\server/share"]) {
    expect(parseFileCompletionContext(text, promptTextWidth(text))).toBeUndefined()
  }
  expect(parseFileCompletionContext("@src\nnext", promptTextWidth("@src\n"))).toBeUndefined()
  expect(parseFileCompletionContext("@界", 2)).toBeUndefined()
})

test("reference formatting distinguishes files, separators, and quoted directory continuation", () => {
  const context = parseFileCompletionContext("say @ol", promptTextWidth("say @ol"))!
  const file = { path: "src/index.ts", type: "file" as const }
  expect(formatFileReference(file, context, "")).toEqual({
    replacement: "@src/index.ts ",
    cursorAfterTrigger: promptTextWidth("@src/index.ts ")
  })
  expect(formatFileReference(file, context, " ")).toEqual({
    replacement: "@src/index.ts",
    cursorAfterTrigger: promptTextWidth("@src/index.ts ")
  })
  expect(formatFileReference(file, context, "\t")).toEqual({
    replacement: "@src/index.ts",
    cursorAfterTrigger: promptTextWidth("@src/index.ts\t")
  })
  expect(formatFileReference(file, context, ", next")).toEqual({
    replacement: "@src/index.ts",
    cursorAfterTrigger: promptTextWidth("@src/index.ts")
  })

  const quoted = parseFileCompletionContext('@"my f', promptTextWidth('@"my f'))!
  expect(formatFileReference({ path: "my folder", type: "directory" }, quoted, "")).toEqual({
    replacement: '@"my folder/"',
    cursorAfterTrigger: promptTextWidth('@"my folder/')
  })
})

test("file controller debounces, opens the existing picker, and emits one selected range edit", async () => {
  const picker = createPickerStack()
  const session = new FakeFileSession()
  const edits: unknown[] = []
  const controller = new FileCompletionController(picker, edit => edits.push(edit))

  controller.update(session, 1, fileCompletionInputFromText("review @sr", promptTextWidth("review @sr")))
  await Bun.sleep(25)
  expect(session.calls.map(call => call.query)).toEqual(["sr"])
  session.calls[0]!.resolve({ matches: [{ path: "src/index.ts", type: "file" }], truncated: false })
  await Bun.sleep(0)

  const presentation = picker.presentation("review @sr")
  expect(presentation?.frame.id).toBe("files")
  const selectedId = fileCompletionCandidateId({ path: "src/index.ts", type: "file" })
  expect(
    controller.complete(selectedId, fileCompletionInputFromText("review @sr", promptTextWidth("review @sr")))
  ).toBe(true)
  expect(edits).toEqual([
    {
      startOffset: promptTextWidth("review "),
      endOffset: promptTextWidth("review @sr"),
      replacement: "@src/index.ts ",
      cursorOffset: promptTextWidth("review @src/index.ts ")
    }
  ])
  expect(picker.presentation("")).toBeUndefined()
  controller.dispose()
  picker.dispose()
})

test("file acceptance preserves a following newline without inserting a prose separator", async () => {
  const picker = createPickerStack()
  const session = new FakeFileSession()
  const edits: unknown[] = []
  const controller = new FileCompletionController(picker, edit => edits.push(edit))
  const draft = "@sr\nnext"

  controller.update(session, 1, fileCompletionInputFromText(draft, 3))
  await Bun.sleep(25)
  session.calls[0]!.resolve({ matches: [{ path: "src/index.ts", type: "file" }], truncated: false })
  await Bun.sleep(0)
  expect(controller.complete("file:src/index.ts", fileCompletionInputFromText(draft, 3))).toBe(true)
  expect(edits).toEqual([
    { startOffset: 0, endOffset: 3, replacement: "@src/index.ts", cursorOffset: promptTextWidth("@src/index.ts") }
  ])

  controller.dispose()
  picker.dispose()
})

test("file acceptance stays dismissed through its cursor and content notifications", async () => {
  const picker = createPickerStack()
  const session = new FakeFileSession()
  const edits: unknown[] = []
  const controller = new FileCompletionController(picker, edit => edits.push(edit))
  const draft = "@sr, next"

  controller.update(session, 1, fileCompletionInputFromText(draft, 3))
  await Bun.sleep(25)
  session.calls[0]!.resolve({ matches: [{ path: "src/index.ts", type: "file" }], truncated: false })
  await Bun.sleep(0)
  expect(controller.complete("file:src/index.ts", fileCompletionInputFromText(draft, 3))).toBe(true)
  expect(edits).toEqual([
    { startOffset: 0, endOffset: 3, replacement: "@src/index.ts", cursorOffset: promptTextWidth("@src/index.ts") }
  ])

  const completed = "@src/index.ts, next"
  const cursor = promptTextWidth("@src/index.ts")
  controller.update(session, 1, fileCompletionInputFromText(completed, cursor))
  controller.update(session, 2, fileCompletionInputFromText(completed, cursor))
  await Bun.sleep(25)
  expect(session.calls).toHaveLength(1)

  controller.update(session, 3, fileCompletionInputFromText("@src/index.tsx, next", cursor + 1))
  await Bun.sleep(25)
  expect(session.calls).toHaveLength(2)
  controller.dispose()
  picker.dispose()
})

test("file controller aborts stale work, admits only the latest query, and keeps dismissal revision-scoped", async () => {
  const picker = createPickerStack()
  const session = new FakeFileSession()
  const controller = new FileCompletionController(picker, () => {})

  controller.update(session, 1, fileCompletionInputFromText("@s", 2))
  await Bun.sleep(25)
  controller.update(session, 2, fileCompletionInputFromText("@sr", 3))
  expect(session.calls[0]!.signal.aborted).toBe(true)
  await Bun.sleep(25)
  expect(session.calls.map(call => call.query)).toEqual(["s", "sr"])
  session.calls[1]!.resolve({ matches: [{ path: "src", type: "directory" }], truncated: false })
  await Bun.sleep(0)
  expect(picker.presentation("")?.frame.id).toBe("files")

  controller.dismiss()
  controller.update(session, 2, fileCompletionInputFromText("@sr", 0))
  controller.update(session, 2, fileCompletionInputFromText("@sr", 3))
  await Bun.sleep(25)
  expect(session.calls).toHaveLength(2)
  controller.update(session, 3, fileCompletionInputFromText("@src", 4))
  await Bun.sleep(25)
  expect(session.calls).toHaveLength(3)

  controller.dispose()
  expect(session.calls[2]!.signal.aborted).toBe(true)
  picker.dispose()
})

function parseFileCompletionContext(text: string, cursorOffset: number): FileCompletionContext | undefined {
  return parseFileCompletionInput(fileCompletionInputFromText(text, cursorOffset))
}

interface FakeCall {
  readonly query: string
  readonly signal: AbortSignal
  resolve(result: Awaited<ReturnType<FileCompletionSearchSession["searchProjectFiles"]>>): void
}

class FakeFileSession implements FileCompletionSearchSession {
  readonly calls: FakeCall[] = []

  searchProjectFiles(
    query: string,
    signal: AbortSignal
  ): Promise<Awaited<ReturnType<FileCompletionSearchSession["searchProjectFiles"]>>> {
    let resolve!: FakeCall["resolve"]
    let reject!: (cause: unknown) => void
    const promise = new Promise<Awaited<ReturnType<FileCompletionSearchSession["searchProjectFiles"]>>>(
      (settle, fail) => {
        resolve = settle
        reject = fail
      }
    )
    signal.addEventListener(
      "abort",
      () => {
        const error = new Error("aborted")
        error.name = "AbortError"
        reject(error)
      },
      { once: true }
    )
    this.calls.push({ query, signal, resolve })
    return promise
  }
}

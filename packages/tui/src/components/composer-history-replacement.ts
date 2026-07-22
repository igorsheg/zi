import type { TextareaRenderable } from "@opentui/core"
import { maxSessionPromptHistoryEntries } from "@with-zi/coding-agent"

const maxComposerHistoryReplacementSlots = maxSessionPromptHistoryEntries * 2 + 1

interface OpenTuiRenderLibMemory {
  readonly encoder: { encode(text: string): Uint8Array }
  textBufferRegisterMemBuffer(buffer: unknown, bytes: Uint8Array, owned: boolean): number
  textBufferReplaceMemBuffer(buffer: unknown, memId: number, bytes: Uint8Array, owned: boolean): boolean
  editBufferReplaceTextFromMem(buffer: unknown, memId: number): void
}

interface OpenTuiHistoryMemory {
  readonly textBytes: Uint8Array[]
  encode(text: string): Uint8Array
  register(bytes: Uint8Array): number
  recycle(memId: number, bytes: Uint8Array): boolean
  replace(memId: number): void
}

export interface ComposerHistoryReplacementEntry {
  readonly entryId: string
  readonly text: string
}

export interface ComposerHistoryReplacement {
  begin(entry: ComposerHistoryReplacementEntry, replaceText: (text: string) => void): void
  replace(entry: ComposerHistoryReplacementEntry, replaceText: (text: string) => void): void
  restoreDraft(): void
  abandonBrowse(): void
  pinCompletedBrowse(): void
  releaseCompletedBrowse(): void
  reset(): void
  destroy(): void
}

export function createComposerHistoryReplacement(input: TextareaRenderable): ComposerHistoryReplacement {
  // OpenTUI 0.4.5 never reclaims replaceText() registry slots. Each browse uses stable per-entry slots.
  // The next browse starts from a spare; that replacement clears redo, making the completed browse recyclable.
  const extmarks = input.extmarks
  const originalReplaceText = Reflect.get(extmarks, "originalReplaceText")
  if (typeof originalReplaceText !== "function") throw incompatibleOpenTui()
  const memory = openTuiHistoryMemory(input)
  const slots: Array<{ readonly memId: number; readonly bytesIndex: number }> = []
  const freeSlots: number[] = []
  let browseEntrySlots = new Map<string, number>()
  let browseAllocatedSlots = new Set<number>()
  let completedEntrySlots = new Map<string, number>()
  let completedBrowseSlots = new Set<number>()
  let pinnedEntrySlots = new Map<string, number>()
  let prepared: { readonly text: string; readonly memId: number } | undefined

  Reflect.set(extmarks, "originalReplaceText", (text: string) => {
    if (!prepared || prepared.text !== text) {
      Reflect.apply(originalReplaceText, extmarks, [text])
      return
    }
    memory.replace(prepared.memId)
  })

  const release = (released: ReadonlySet<number>) => {
    for (const slot of released) freeSlots.push(slot)
  }

  const assign = (
    entry: ComposerHistoryReplacementEntry
  ): { readonly slotIndex: number; readonly newlyAllocated: boolean } => {
    const assigned = browseEntrySlots.get(entry.entryId)
    if (assigned !== undefined) return { slotIndex: assigned, newlyAllocated: false }
    const pinned = pinnedEntrySlots.get(entry.entryId)
    if (pinned !== undefined) {
      browseEntrySlots.set(entry.entryId, pinned)
      return { slotIndex: pinned, newlyAllocated: false }
    }

    const reusable = freeSlots.pop()
    const slotIndex = reusable ?? slots.length
    if (slotIndex >= maxComposerHistoryReplacementSlots) {
      throw new Error(`Composer history cannot retain more than ${maxComposerHistoryReplacementSlots} native slots`)
    }

    const bytes = memory.encode(entry.text)
    const slot = slots[slotIndex]
    if (slot) {
      if (!memory.recycle(slot.memId, bytes)) throw new Error("Failed to recycle Composer history memory")
      memory.textBytes[slot.bytesIndex] = bytes
    } else {
      const memId = memory.register(bytes)
      const bytesIndex = memory.textBytes.length
      memory.textBytes.push(bytes)
      slots.push({ memId, bytesIndex })
    }
    browseEntrySlots.set(entry.entryId, slotIndex)
    browseAllocatedSlots.add(slotIndex)
    return { slotIndex, newlyAllocated: true }
  }

  const apply = (
    entry: ComposerHistoryReplacementEntry,
    replaceText: (text: string) => void,
    clearsCompletedBrowse: boolean
  ) => {
    const assignment = assign(entry)
    prepared = { text: entry.text, memId: slots[assignment.slotIndex]!.memId }
    try {
      replaceText(entry.text)
    } catch (cause) {
      if (assignment.newlyAllocated) {
        browseEntrySlots.delete(entry.entryId)
        browseAllocatedSlots.delete(assignment.slotIndex)
        freeSlots.push(assignment.slotIndex)
      }
      throw cause
    } finally {
      prepared = undefined
    }
    if (clearsCompletedBrowse) {
      release(completedBrowseSlots)
      completedEntrySlots = new Map()
      completedBrowseSlots = new Set()
    }
  }

  const clearAssignments = () => {
    browseEntrySlots = new Map()
    browseAllocatedSlots = new Set()
    completedEntrySlots = new Map()
    completedBrowseSlots = new Set()
    pinnedEntrySlots = new Map()
    freeSlots.length = 0
  }

  return {
    begin(entry, replaceText) {
      browseEntrySlots = new Map()
      browseAllocatedSlots = new Set()
      apply(entry, replaceText, true)
    },
    replace(entry, replaceText) {
      apply(entry, replaceText, false)
    },
    restoreDraft() {
      completedEntrySlots = new Map(
        [...browseEntrySlots].filter(([, slotIndex]) => browseAllocatedSlots.has(slotIndex))
      )
      completedBrowseSlots = browseAllocatedSlots
      browseEntrySlots = new Map()
      browseAllocatedSlots = new Set()
    },
    abandonBrowse() {
      // Browse replacements can remain in native undo history, so immutable entry mappings stay reusable but pinned.
      for (const [entryId, slotIndex] of browseEntrySlots) pinnedEntrySlots.set(entryId, slotIndex)
      browseEntrySlots = new Map()
      browseAllocatedSlots = new Set()
    },
    pinCompletedBrowse() {
      // Native undo/redo can move completed replacements out of redo, so they are no longer recyclable.
      for (const [entryId, slotIndex] of completedEntrySlots) pinnedEntrySlots.set(entryId, slotIndex)
      completedEntrySlots = new Map()
      completedBrowseSlots = new Set()
    },
    releaseCompletedBrowse() {
      release(completedBrowseSlots)
      completedEntrySlots = new Map()
      completedBrowseSlots = new Set()
    },
    reset() {
      clearAssignments()
      for (let slot = slots.length - 1; slot >= 0; slot--) freeSlots.push(slot)
    },
    destroy() {
      Reflect.set(extmarks, "originalReplaceText", originalReplaceText)
      clearAssignments()
    }
  }
}

function openTuiHistoryMemory(input: TextareaRenderable): OpenTuiHistoryMemory {
  const editBuffer = input.editBuffer
  const lib = Reflect.get(editBuffer, "lib")
  const bufferPtr = Reflect.get(editBuffer, "bufferPtr")
  const textBufferPtr = Reflect.get(editBuffer, "textBufferPtr")
  const textBytes = Reflect.get(editBuffer, "_textBytes")
  if (
    !isOpenTuiRenderLibMemory(lib) ||
    bufferPtr === undefined ||
    textBufferPtr === undefined ||
    !isByteList(textBytes)
  ) {
    throw incompatibleOpenTui()
  }
  return {
    textBytes,
    encode: text => lib.encoder.encode(text),
    register: bytes => lib.textBufferRegisterMemBuffer(textBufferPtr, bytes, false),
    recycle: (memId, bytes) => lib.textBufferReplaceMemBuffer(textBufferPtr, memId, bytes, false),
    replace: memId => lib.editBufferReplaceTextFromMem(bufferPtr, memId)
  }
}

function isOpenTuiRenderLibMemory(value: unknown): value is OpenTuiRenderLibMemory {
  if (!isRecord(value) || !isRecord(value.encoder)) return false
  return (
    typeof value.encoder.encode === "function" &&
    typeof value.textBufferRegisterMemBuffer === "function" &&
    typeof value.textBufferReplaceMemBuffer === "function" &&
    typeof value.editBufferReplaceTextFromMem === "function"
  )
}

function isByteList(value: unknown): value is Uint8Array[] {
  return Array.isArray(value) && value.every(item => item instanceof Uint8Array)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function incompatibleOpenTui(): Error {
  return new Error("OpenTUI 0.4.5 Composer history adapter is incompatible with the installed runtime")
}

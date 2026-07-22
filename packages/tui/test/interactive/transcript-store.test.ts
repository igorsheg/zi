import { describe, expect, test } from "bun:test"

import {
  createTranscriptStore,
  initialTranscriptNavigation,
  transitionTranscriptNavigation,
  type TranscriptNavigation,
  type TranscriptNavigationEvent
} from "../../src/interactive/transcript/navigation.js"

const following: TranscriptNavigation = { type: "following" }
const detachedSeen: TranscriptNavigation = { type: "detached", unseenOutput: false }
const detachedUnseen: TranscriptNavigation = { type: "detached", unseenOutput: true }

describe("transcript navigation", () => {
  test("store owns navigation outside the renderer", () => {
    const store = createTranscriptStore()
    expect(store.$navigation.get()).toEqual(following)
    store.dispatch({ type: "MANUAL_POSITION_CHANGED", atTail: false })
    expect(store.$navigation.get()).toEqual(detachedSeen)
  })

  test("starts by following the tail", () => {
    expect(initialTranscriptNavigation).toEqual(following)
  })

  const cases: readonly [
    name: string,
    state: TranscriptNavigation,
    event: TranscriptNavigationEvent,
    expected: TranscriptNavigation
  ][] = [
    ["output keeps following", following, { type: "OUTPUT_COMMITTED" }, following],
    ["manual movement away detaches", following, { type: "MANUAL_POSITION_CHANGED", atTail: false }, detachedSeen],
    [
      "manual movement at the tail keeps following",
      following,
      { type: "MANUAL_POSITION_CHANGED", atTail: true },
      following
    ],
    ["selection drag detaches", following, { type: "SELECTION_DRAG_STARTED" }, detachedSeen],
    ["jump while following is idempotent", following, { type: "JUMP_TO_TAIL" }, following],
    ["fitting resize keeps following", following, { type: "RESIZE_SETTLED", contentFits: true }, following],
    ["overflowing resize keeps following", following, { type: "RESIZE_SETTLED", contentFits: false }, following],
    ["output marks detached content unseen", detachedSeen, { type: "OUTPUT_COMMITTED" }, detachedUnseen],
    ["repeated output stays coalesced", detachedUnseen, { type: "OUTPUT_COMMITTED" }, detachedUnseen],
    [
      "movement away preserves no unseen output",
      detachedSeen,
      { type: "MANUAL_POSITION_CHANGED", atTail: false },
      detachedSeen
    ],
    [
      "movement away preserves unseen output",
      detachedUnseen,
      { type: "MANUAL_POSITION_CHANGED", atTail: false },
      detachedUnseen
    ],
    [
      "movement to the tail clears unseen output",
      detachedUnseen,
      { type: "MANUAL_POSITION_CHANGED", atTail: true },
      following
    ],
    ["jump clears a detached transcript", detachedSeen, { type: "JUMP_TO_TAIL" }, following],
    ["jump clears unseen output", detachedUnseen, { type: "JUMP_TO_TAIL" }, following],
    ["selection preserves detached state", detachedSeen, { type: "SELECTION_DRAG_STARTED" }, detachedSeen],
    ["selection preserves unseen output", detachedUnseen, { type: "SELECTION_DRAG_STARTED" }, detachedUnseen],
    ["fitting resize reattaches", detachedSeen, { type: "RESIZE_SETTLED", contentFits: true }, following],
    ["fitting resize clears unseen output", detachedUnseen, { type: "RESIZE_SETTLED", contentFits: true }, following],
    [
      "overflowing resize preserves detachment",
      detachedSeen,
      { type: "RESIZE_SETTLED", contentFits: false },
      detachedSeen
    ],
    [
      "overflowing resize preserves unseen output",
      detachedUnseen,
      { type: "RESIZE_SETTLED", contentFits: false },
      detachedUnseen
    ]
  ]

  test.each(cases)("%s", (_name, state, event, expected) => {
    expect(transitionTranscriptNavigation(state, event)).toEqual(expected)
  })

  test("rejects events outside the closed union", () => {
    expect(() =>
      // @ts-expect-error This exercises the runtime exhaustiveness guard.
      transitionTranscriptNavigation(following, { type: "SCROLLBAR_CHANGED" })
    ).toThrow("Unexpected transcript navigation event")
  })
})

export type TranscriptNavigation = { type: "following" } | { type: "detached"; unseenOutput: false | true }

export type TranscriptNavigationEvent =
  | { type: "OUTPUT_COMMITTED" }
  | { type: "MANUAL_POSITION_CHANGED"; atTail: boolean }
  | { type: "SELECTION_DRAG_STARTED" }
  | { type: "JUMP_TO_TAIL" }
  | { type: "RESIZE_SETTLED"; contentFits: boolean }

export const initialTranscriptNavigation: TranscriptNavigation = { type: "following" }

export function transitionTranscriptNavigation(
  state: TranscriptNavigation,
  event: TranscriptNavigationEvent
): TranscriptNavigation {
  switch (event.type) {
    case "OUTPUT_COMMITTED":
      return state.type === "following" || state.unseenOutput ? state : { type: "detached", unseenOutput: true }
    case "MANUAL_POSITION_CHANGED":
      if (event.atTail) return state.type === "following" ? state : initialTranscriptNavigation
      return state.type === "following" ? { type: "detached", unseenOutput: false } : state
    case "SELECTION_DRAG_STARTED":
      return state.type === "following" ? { type: "detached", unseenOutput: false } : state
    case "JUMP_TO_TAIL":
      return state.type === "following" ? state : initialTranscriptNavigation
    case "RESIZE_SETTLED":
      return event.contentFits && state.type === "detached" ? initialTranscriptNavigation : state
    default:
      return assertNever(event)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected transcript navigation event: ${String(value)}`)
}

# Composer-owned picker stack

Below-composer choice flows use one native input and a stack of picker frames. The composer is the terminal's omni input: it remains mounted and focused while command, model, settings, and nested option frames change beneath it.

The previous `/model` selector replaced the composer with a second `TextareaRenderable`. That split focus, duplicated editor mechanics, and made nested selectors a sequence of unrelated screens rather than one navigable interaction.

OpenZi now uses three concrete owners:

- `Composer` owns the only native textarea, its text, cursor, paste/undo history, focus, and atomic paste/image extmarks. Text paste payloads stay with those native markers and expand only at copy or submission; `PromptStore` remains authoritative for active image payloads while marker edits report their retained image references.
- `PickerStack` owns open/closed state, ordered frames, selected row per frame, suspended parent filters, top-frame filtering, and push/pop transitions. It accepts the current composer text as a method argument and does not retain or render an active input.
- `PickerStackView` renders only the active frame below the composer. It contains no textarea and does not interpret selected row IDs.

`PromptView` preserves three vertical regions. Working state, feedback, and queued-input status stay above the composer as transient presentation. The composer rail contains only stable session metadata: cwd on the left, then model/effort and context on the right. Right-rail text is ordered by importance and admits only the largest fitting prefix, so context disappears before model/effort at constrained widths. The rail accepts text, not arbitrary renderables or extension callbacks. `PickerStackView` remains the only below-input choice surface.

`PromptStore` owns the command/model workflow that creates frames and interprets selection. It issues revisioned one-shot input edits with explicit cursor targets when a transition must complete, clear, restore, or safely splice command completion into the composer. These edits are resource synchronization requests, not a mirrored editor model; subsequent native text and cursor remain authoritative in OpenTUI.

The stack API is deliberately mechanical:

```ts
interface PickerStack {
  readonly $state: ReadableAtom<PickerStackState>
  open(frame: PickerFrame): void
  push(frame: PickerFrame, parentFilter: string): void
  replaceTop(frame: PickerFrame, filter: string): void
  queryChanged(filter: string): void
  move(filter: string, direction: -1 | 1): void
  presentation(filter: string): PickerPresentation | undefined
  back(): { type: "closed" } | { type: "revealed"; filter: string }
  close(): void
  dispose(): void
}
```

Only the top frame receives the current composer filter. Pushing captures the parent filter on the child frame. Popping restores that filter while preserving the parent's selection. Open state contains a non-empty frame tuple. Depth, rows per frame, and suspended filter length are bounded at admission; row IDs are unique and configured selection must name an admitted row. Public presentation strips selection indices and suspended filters from the frame definition.

Domain owners provide rows and interpret selected IDs; the stack contains no command registry, settings actions, model mutation, callbacks, or generic dispatch bus. While a picker is open, submit, tab, and vertical-navigation keys cannot fall through to multiline editing, queue restoration, or prompt submission. Every programmatic composer replacement retains focus and applies its admitted cursor target; ordinary transitions target the end, while slash completion targets the inserted command boundary. `PromptView` owns picker observation because it computes available terminal height. `PickerList` retains at most ten visible native rows keyed by row ID within the active frame scope, preserving overlapping siblings across filtering and navigation, resetting identity when the frame ID changes, and releasing rows when they leave the viewport. Selection, cancellation, stale async completion, and session replacement remain transitions of the owning prompt workflow.

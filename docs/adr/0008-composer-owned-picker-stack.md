# Composer-owned picker stack

Below-composer choice flows use one native input and a stack of picker frames. The composer is the terminal's omni input: it remains mounted and focused while command, model, settings, and nested option frames change beneath it.

The previous `/model` selector replaced the composer with a second `TextareaRenderable`. That split focus, duplicated editor mechanics, and made nested selectors a sequence of unrelated screens rather than one navigable interaction.

OpenZi now uses three concrete owners:

- `Composer` owns the only native textarea, its text, cursor, paste/undo history, and focus.
- `PickerStack` owns open/closed state, ordered frames, selected row per frame, suspended parent filters, top-frame filtering, and push/pop transitions. It accepts the current composer text as a method argument and does not retain or render an active input.
- `PickerStackView` renders only the active frame below the composer. It contains no textarea and does not interpret selected row IDs.

`PromptStore` owns the command/model workflow that creates frames and interprets selection. It issues revisioned one-shot input edits when a transition must complete, clear, or restore the composer. These edits are resource synchronization requests, not a mirrored editor model; subsequent native text remains authoritative in OpenTUI.

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

Domain owners provide rows and interpret selected IDs; the stack contains no command registry, settings actions, model mutation, callbacks, or generic dispatch bus. While a picker is open, submit, tab, and vertical-navigation keys cannot fall through to multiline editing, queue restoration, or prompt submission. Tab completion and every programmatic composer replacement retain focus and place the native cursor at the end. Selection, cancellation, stale async completion, and session replacement remain transitions of the owning prompt workflow.

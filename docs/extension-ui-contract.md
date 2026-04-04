# Extension UI Contract — Internal Acceptance Criteria

Extracted from pi-mono's `ExtensionUIContext` (types.ts:108-242) and `TUI` (tui.ts:74-404).
These are the internal primitives F/G/H must expose so the extension API can be built on top.

## F. Focus Model — required primitives

Source: `TUI.setFocus`, `TUI.handleInput`, `TUI.showOverlay`, `Focusable`

### focus ownership
- single focused component at a time (global, not per-container)
- `setFocus(component)` toggles `focused: bool` on Focusable components
- focused component receives all input via `handleInput(key)`
- focused component provides cursor position

### focus save/restore (for overlays + temporary UIs)
- overlay push: save current focus, set focus to overlay component
- overlay pop: restore saved focus
- overlay hide/show: transfer focus to topmost visible capturing overlay, or restore preFocus
- non-capturing overlays: shown without stealing focus

### focus routing
- input goes to `focusedComponent.handleInput()`, NOT through container tree
- cursor comes from `focusedComponent.cursorState()`, NOT from root.cursorState()

### required by extension API
- `setEditorComponent(factory)` → needs setFocus(newEditor) after swap
- `select/input/editor` temporary UIs → needs focus capture + restore on dismiss
- `custom(factory, { overlay })` → needs overlay focus save/restore
- `onTerminalInput(handler)` → needs input listener list before focused component

## G. Transcript Model — required primitives

Source: `chatContainer.addChild`, `addMessageToChat`, `CustomMessageComponent`

### arbitrary component injection
- any Component must be insertable as a chat row
- used by: UserMessage, AssistantMessage, ToolExecution, CustomMessage,
  BashExecution, CompactionSummary, BranchSummary, SkillInvocation,
  Spacer, Text (status/warning/resource listings), DynamicBorder

### mutation operations
- `addChild(component)` — append to end
- `removeChild(component)` — remove specific child (used during streaming: remove streamingComponent)
- `clear()` — remove all children (session reset, /clear command)

### metadata-indexed operations (zi-specific optimization)
- tool lookup by tool_call_id → row index (HashMap, O(1))
- current streaming text index → for appendText() merge
- these are implementation details, not extension-visible

### required by extension API
- `setMessageRenderer(type, renderer)` → CustomMessageComponent uses extension-provided renderer
- custom messages appear in chat via addMessageToChat → chatContainer.addChild

## H. Overlay System — required primitives

Source: `TUI.showOverlay`, `OverlayOptions`, `OverlayHandle`

### overlay lifecycle
- `showOverlay(component, options?) → OverlayHandle`
- `hideOverlay()` — hide topmost
- handle-based: `handle.hide()`, `handle.setHidden(bool)`, `handle.focus()`, `handle.unfocus()`

### overlay entry state
```
component: Component
options: OverlayOptions
preFocus: ?Component       // saved focus to restore
hidden: bool               // temporarily hidden
nonCapturing: bool         // don't steal focus
focusOrder: u64            // z-order for focus resolution
```

### overlay positioning (OverlayOptions)
```
width: absolute | percentage
minWidth: absolute
maxHeight: absolute | percentage
anchor: center | top-left | top-right | bottom-left | bottom-right | top-center | bottom-center
offsetX, offsetY: from anchor
row, col: absolute | percentage
margin: { top, right, bottom, left } | uniform
visible: fn(termWidth, termHeight) → bool   // dynamic visibility
nonCapturing: bool
```

### overlay focus rules
- showing overlay: save preFocus, setFocus(overlay.component) unless nonCapturing
- hiding overlay: focus topmost visible capturing overlay, or restore preFocus
- overlay hide/show toggle: same focus transfer rules
- invisible overlay (terminal too small): redirect focus to next visible or preFocus

### overlay rendering (zi-specific: cell buffer compositing)
- render base tree into buffer first
- for each visible overlay: resolve layout → render into sub-region on top
- z-order: later overlays render on top of earlier ones

### required by extension API
- `custom(factory, { overlay: true, overlayOptions })` → showOverlay + done callback
- `onHandle(handle)` → returns OverlayHandle to extension for hide/show/focus control

## Cross-cutting constraints

### Component identity
- focus comparison uses component identity (ptr equality in zi)
- overlay stack stores component references for focus restore
- removeChild needs identity-based lookup

### Dispose lifecycle
- overlays: component.dispose?() on hide()
- widgets: dispose on replace/remove/session-reset
- footer/header: dispose on replace
- editors: dispose on restore-default

### Theme access
- all extension-created components receive theme
- theme switching must propagate to all components

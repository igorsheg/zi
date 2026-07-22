const exitGestureWindowMs = 500

export type ExitGestureAction = "armed" | "exit"

type ExitGestureState = { readonly type: "ready" } | { readonly type: "armed"; readonly pressedAt: number }

export class ExitGestureController {
  readonly #onExit: () => void
  #state: ExitGestureState = { type: "ready" }

  constructor(onExit: () => void) {
    this.#onExit = onExit
  }

  clear(now = Date.now()): ExitGestureAction {
    if (this.#state.type === "armed" && now - this.#state.pressedAt < exitGestureWindowMs) {
      this.#state = { type: "ready" }
      this.#onExit()
      return "exit"
    }
    this.#state = { type: "armed", pressedAt: now }
    return "armed"
  }

  consume(): void {
    this.#state = { type: "ready" }
  }

  exit(): void {
    this.#onExit()
  }
}

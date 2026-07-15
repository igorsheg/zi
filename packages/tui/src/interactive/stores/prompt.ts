import type {
  BuiltinSlashCommand,
  ImageContent,
  ModelChoice,
  PendingInputDelivery,
  QueuedInputs
} from "@openzi/coding-agent"
import { atom, type ReadableAtom } from "nanostores"

import type { InteractiveCommands } from "../interactive-commands.js"
import { configuredModelChoices, exactModelChoice, filterModelChoices } from "../model-selector.js"
import type { InteractiveStore } from "./interactive.js"

export type PromptFeedback =
  | { readonly type: "none" }
  | { readonly type: "status"; readonly message: string }
  | { readonly type: "error"; readonly message: string }

export type SlashCommandCompletion =
  | { readonly type: "none" }
  | { readonly type: "command"; readonly command: BuiltinSlashCommand }

export type PromptSurface =
  | { readonly type: "composer"; readonly completion: SlashCommandCompletion }
  | { readonly type: "loading_models"; readonly operationId: number; readonly initialSearch: string }
  | {
      readonly type: "model_selector"
      readonly operationId: number
      readonly initialSearch: string
      readonly choices: readonly ModelChoice[]
      readonly selectedIndex: number
      readonly error?: string
    }
  | {
      readonly type: "selecting_model"
      readonly operationId: number
      readonly initialSearch: string
      readonly choices: readonly ModelChoice[]
      readonly selectedIndex: number
    }

export interface PromptState {
  readonly feedback: PromptFeedback
  readonly images: readonly ImageContent[]
  readonly surface: PromptSurface
}

export interface PromptStore {
  readonly $state: ReadableAtom<PromptState>
  submit(text: string, delivery: PendingInputDelivery): boolean
  draftChanged(text: string, cursorOffset: number): void
  completeSlashCommand(): string | undefined
  dismissSlashCommand(): void
  modelQueryChanged(query: string): void
  moveModelSelection(query: string, direction: -1 | 1): void
  selectModel(query: string): boolean
  cancelModelSelector(): boolean
  restoreQueuedInputs(currentText: string): string
  abortAndRestoreQueuedInputs(currentText: string): string
  clear(): void
  dispose(): void
}

const composerSurface = (): PromptSurface => ({ type: "composer", completion: { type: "none" } })

const initialPromptState: PromptState = { feedback: { type: "none" }, images: [], surface: composerSurface() }

export function createPromptStore(mode: InteractiveStore, commands: InteractiveCommands): PromptStore {
  const $state = atom(initialPromptState)
  let disposed = false
  let nextOperationId = 0

  const showError = (cause: unknown) => {
    if (disposed) return
    $state.set({ ...$state.get(), feedback: { type: "error", message: errorMessage(cause) } })
  }

  const closeWithError = (cause: unknown) => {
    if (disposed) return
    $state.set({
      ...$state.get(),
      feedback: { type: "error", message: errorMessage(cause) },
      surface: composerSurface()
    })
  }

  const mergeQueue = (queue: QueuedInputs, currentText: string, showStatus: boolean): string => {
    const entries = [...queue.steering, ...queue.followUp]
    const texts = entries.map(entry => entry.text)
    const images = entries.flatMap(entry => entry.images)
    const state = $state.get()
    $state.set({
      feedback: showStatus
        ? {
            type: "status",
            message:
              texts.length === 0
                ? "No queued messages to restore"
                : `Restored ${texts.length} queued message${texts.length === 1 ? "" : "s"} to editor${
                    images.length === 0 ? "" : ` with ${images.length} image${images.length === 1 ? "" : "s"}`
                  }`
          }
        : { type: "none" },
      images: images.length === 0 ? state.images : [...images, ...state.images],
      surface: state.surface
    })
    return [...texts, currentText].filter(text => text.length > 0).join("\n\n")
  }

  const accepts = (operationId: number, session: ReturnType<InteractiveStore["getSession"]>): boolean => {
    if (disposed || mode.getSession() !== session) return false
    const surface = $state.get().surface
    return surface.type !== "composer" && surface.operationId === operationId
  }

  const select = (
    operationId: number,
    session: ReturnType<InteractiveStore["getSession"]>,
    choices: readonly ModelChoice[],
    selectedIndex: number,
    initialSearch: string
  ) => {
    const choice = choices[selectedIndex]
    if (!choice || !accepts(operationId, session)) return
    const state = $state.get()
    $state.set({ ...state, surface: { type: "selecting_model", operationId, initialSearch, choices, selectedIndex } })
    const apply = async () => {
      try {
        await session.setModel(choice.model)
      } catch (cause) {
        if (accepts(operationId, session)) closeWithError(cause)
        return
      }
      if (!accepts(operationId, session)) return
      $state.set({
        ...$state.get(),
        feedback: { type: "status", message: `Model: ${choice.model.id}` },
        surface: composerSurface()
      })
    }
    void apply()
  }

  const openModels = (initialSearch: string) => {
    const session = mode.getSession()
    const operationId = ++nextOperationId
    $state.set({
      ...$state.get(),
      feedback: { type: "none" },
      surface: { type: "loading_models", operationId, initialSearch }
    })

    const load = async () => {
      let loaded: readonly ModelChoice[]
      try {
        loaded = await session.listModelChoices()
      } catch (cause) {
        if (!accepts(operationId, session)) return
        $state.set({
          ...$state.get(),
          surface: {
            type: "model_selector",
            operationId,
            initialSearch,
            choices: [],
            selectedIndex: 0,
            error: errorMessage(cause)
          }
        })
        return
      }

      if (!accepts(operationId, session)) return
      const choices = configuredModelChoices(loaded, session.model)
      const exact = initialSearch ? exactModelChoice(initialSearch, choices) : undefined
      if (exact) {
        const selectedIndex = choices.indexOf(exact)
        select(operationId, session, choices, selectedIndex, initialSearch)
        return
      }
      $state.set({
        ...$state.get(),
        surface: {
          type: "model_selector",
          operationId,
          initialSearch,
          choices,
          selectedIndex: currentModelIndex(choices, session.model)
        }
      })
    }
    void load()
  }

  return {
    $state,
    submit(text, delivery) {
      const trimmed = text.trim()
      if (!trimmed || $state.get().surface.type !== "composer") return false

      const command = commands.parse(trimmed)
      if (command) {
        const commandType = command.type
        switch (commandType) {
          case "model":
            openModels(command.search)
            return true
          default:
            return assertNever(commandType)
        }
      }

      try {
        const settled = mode.submit({ text: trimmed, images: $state.get().images, delivery })
        $state.set(initialPromptState)
        void settled.catch(showError)
        return true
      } catch (cause) {
        showError(cause)
        return false
      }
    },
    draftChanged(text, cursorOffset) {
      const state = $state.get()
      if (state.surface.type !== "composer") return
      const command = commands.suggestions(text, cursorOffset)[0]
      const completion: SlashCommandCompletion = command ? { type: "command", command } : { type: "none" }
      if (sameCompletion(completion, state.surface.completion)) return
      $state.set({ ...state, surface: { type: "composer", completion } })
    },
    completeSlashCommand() {
      const state = $state.get()
      if (state.surface.type !== "composer" || state.surface.completion.type !== "command") return undefined
      $state.set({ ...state, surface: composerSurface() })
      return commands.completion(state.surface.completion.command)
    },
    dismissSlashCommand() {
      const state = $state.get()
      if (state.surface.type !== "composer" || state.surface.completion.type === "none") return
      $state.set({ ...state, surface: composerSurface() })
    },
    modelQueryChanged(query) {
      const state = $state.get()
      if (state.surface.type !== "model_selector") return
      const choices = filterModelChoices(state.surface.choices, query)
      const selectedIndex = Math.min(state.surface.selectedIndex, Math.max(0, choices.length - 1))
      if (selectedIndex === state.surface.selectedIndex) return
      $state.set({ ...state, surface: { ...state.surface, selectedIndex } })
    },
    moveModelSelection(query, direction) {
      const state = $state.get()
      if (state.surface.type !== "model_selector") return
      const choices = filterModelChoices(state.surface.choices, query)
      if (choices.length === 0) return
      const selectedIndex =
        direction === -1
          ? state.surface.selectedIndex === 0
            ? choices.length - 1
            : state.surface.selectedIndex - 1
          : state.surface.selectedIndex === choices.length - 1
            ? 0
            : state.surface.selectedIndex + 1
      $state.set({ ...state, surface: { ...state.surface, selectedIndex } })
    },
    selectModel(query) {
      const state = $state.get()
      if (state.surface.type !== "model_selector") return false
      const choices = filterModelChoices(state.surface.choices, query)
      const selectedIndex = Math.min(state.surface.selectedIndex, Math.max(0, choices.length - 1))
      if (!choices[selectedIndex]) return false
      select(state.surface.operationId, mode.getSession(), choices, selectedIndex, state.surface.initialSearch)
      return true
    },
    cancelModelSelector() {
      const state = $state.get()
      if (state.surface.type === "composer") return false
      $state.set({ ...state, surface: composerSurface() })
      return true
    },
    restoreQueuedInputs(currentText) {
      try {
        return mergeQueue(mode.restoreQueuedInputs(), currentText, true)
      } catch (cause) {
        showError(cause)
        return currentText
      }
    },
    abortAndRestoreQueuedInputs(currentText) {
      try {
        const aborted = mode.abortAndRestoreQueuedInputs()
        const text = mergeQueue(aborted, currentText, false)
        void aborted.settled.catch(showError)
        return text
      } catch (cause) {
        showError(cause)
        return currentText
      }
    },
    clear() {
      $state.set(initialPromptState)
    },
    dispose() {
      disposed = true
    }
  }
}

function sameCompletion(left: SlashCommandCompletion, right: SlashCommandCompletion): boolean {
  if (left.type === "none" || right.type === "none") return left.type === right.type
  return left.command.name === right.command.name
}

function currentModelIndex(choices: readonly ModelChoice[], current: ModelChoice["model"]): number {
  const index = choices.findIndex(
    choice => choice.model.provider === current.provider && choice.model.id === current.id
  )
  return index < 0 ? 0 : index
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected interactive command: ${String(value)}`)
}

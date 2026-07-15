import type {
  BuiltinSlashCommand,
  ImageContent,
  ModelChoice,
  PendingInputDelivery,
  QueuedInputs
} from "@openzi/coding-agent"
import { atom, type ReadableAtom } from "nanostores"

import { glyphs } from "../../glyphs.js"
import type { InteractiveCommands } from "../interactive-commands.js"
import { configuredModelChoices, exactModelChoice, sameModel } from "../model-selector.js"
import type { InteractiveStore } from "./interactive.js"
import { createPickerStack, type PickerFrame, type PickerStack } from "./picker-stack.js"

export type PromptFeedback =
  | { readonly type: "none" }
  | { readonly type: "status"; readonly message: string }
  | { readonly type: "error"; readonly message: string }

export type PromptWorkflow =
  | { readonly type: "idle" }
  | { readonly type: "loading_models"; readonly operationId: number }
  | { readonly type: "choosing_model"; readonly operationId: number; readonly choices: readonly ModelChoice[] }
  | { readonly type: "selecting_model"; readonly operationId: number }

export interface PromptInputEdit {
  readonly revision: number
  readonly text: string
}

export interface PromptState {
  readonly feedback: PromptFeedback
  readonly images: readonly ImageContent[]
  readonly workflow: PromptWorkflow
  readonly inputEdit: PromptInputEdit
}

export interface PromptStore {
  readonly $state: ReadableAtom<PromptState>
  readonly picker: PickerStack
  submit(text: string, delivery: PendingInputDelivery): boolean
  draftChanged(text: string, cursorOffset: number): void
  completePicker(text: string, cursorOffset: number): boolean
  activatePicker(text: string, cursorOffset: number): boolean
  movePicker(filter: string, direction: -1 | 1): void
  backPicker(): boolean
  restoreQueuedInputs(currentText: string): string
  abortAndRestoreQueuedInputs(currentText: string): string
  clear(): void
  dispose(): void
}

const initialPromptState: PromptState = {
  feedback: { type: "none" },
  images: [],
  workflow: { type: "idle" },
  inputEdit: { revision: 0, text: "" }
}

const commandFrameId = "commands"
const modelFrameId = "models"

export function createPromptStore(mode: InteractiveStore, commands: InteractiveCommands): PromptStore {
  const $state = atom(initialPromptState)
  const picker = createPickerStack()
  let disposed = false
  let nextOperationId = 0

  const requestInput = (text: string) => {
    const state = $state.get()
    $state.set({ ...state, inputEdit: { revision: state.inputEdit.revision + 1, text } })
  }

  const showError = (cause: unknown) => {
    if (disposed) return
    $state.set({ ...$state.get(), feedback: { type: "error", message: errorMessage(cause) } })
  }

  const closeModelPicker = (feedback: PromptFeedback) => {
    if (disposed) return
    picker.close()
    const state = $state.get()
    $state.set({ ...state, feedback, workflow: { type: "idle" } })
    requestInput("")
  }

  const mergeQueue = (queue: QueuedInputs, currentText: string, showStatus: boolean): string => {
    const entries = [...queue.steering, ...queue.followUp]
    const texts = entries.map(entry => entry.text)
    const images = entries.flatMap(entry => entry.images)
    const state = $state.get()
    $state.set({
      ...state,
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
      images: images.length === 0 ? state.images : [...images, ...state.images]
    })
    return [...texts, currentText].filter(text => text.length > 0).join("\n\n")
  }

  const accepts = (operationId: number, session: ReturnType<InteractiveStore["getSession"]>): boolean => {
    if (disposed || mode.getSession() !== session) return false
    const workflow = $state.get().workflow
    return workflow.type !== "idle" && workflow.operationId === operationId
  }

  const selectModel = (
    operationId: number,
    session: ReturnType<InteractiveStore["getSession"]>,
    choice: ModelChoice
  ) => {
    if (!accepts(operationId, session)) return
    const state = $state.get()
    $state.set({ ...state, workflow: { type: "selecting_model", operationId } })
    const presentation = picker.presentation("")
    if (presentation) {
      picker.replaceTop(
        { ...presentation.frame, emptyText: "Selecting model…", footer: `Selecting ${choice.model.id}…` },
        ""
      )
    }
    requestInput("")

    const apply = async () => {
      try {
        await session.setModel(choice.model)
      } catch (cause) {
        if (accepts(operationId, session)) closeModelPicker({ type: "error", message: errorMessage(cause) })
        return
      }
      if (!accepts(operationId, session)) return
      closeModelPicker({ type: "status", message: `Model: ${choice.model.id}` })
    }
    void apply()
  }

  const openModels = (initialSearch: string, parentFilter?: string) => {
    const session = mode.getSession()
    const operationId = ++nextOperationId
    const state = $state.get()
    $state.set({ ...state, feedback: { type: "none" }, workflow: { type: "loading_models", operationId } })
    const loading = modelFrame([], session.model, "Loading models…")
    if (parentFilter === undefined) picker.open(loading)
    else picker.push(loading, parentFilter)
    requestInput(initialSearch)

    const load = async () => {
      let loaded: readonly ModelChoice[]
      try {
        loaded = await session.listModelChoices()
      } catch (cause) {
        if (!accepts(operationId, session)) return
        picker.replaceTop({ ...loading, emptyText: errorMessage(cause) }, initialSearch)
        $state.set({ ...$state.get(), workflow: { type: "choosing_model", operationId, choices: [] } })
        return
      }

      if (!accepts(operationId, session)) return
      const choices = configuredModelChoices(loaded, session.model)
      const exact = initialSearch ? exactModelChoice(initialSearch, choices) : undefined
      if (exact) {
        selectModel(operationId, session, exact)
        return
      }
      picker.replaceTop(modelFrame(choices, session.model), initialSearch)
      $state.set({ ...$state.get(), workflow: { type: "choosing_model", operationId, choices } })
    }
    void load()
  }

  const dispatchCommand = (command: ReturnType<InteractiveCommands["parse"]>, parentFilter?: string): boolean => {
    if (!command) return false
    const commandType = command.type
    switch (commandType) {
      case "model":
        openModels(command.search, parentFilter)
        return true
      default:
        return assertNever(commandType)
    }
  }

  const commandFor = (text: string, cursorOffset: number, selectedId: string): BuiltinSlashCommand | undefined =>
    commands.suggestions(text, cursorOffset).find(command => command.name === selectedId)

  return {
    $state,
    picker,
    submit(text, delivery) {
      const trimmed = text.trim()
      if (!trimmed || $state.get().workflow.type !== "idle") return false

      const command = commands.parse(trimmed)
      if (dispatchCommand(command)) return true

      try {
        const settled = mode.submit({ text: trimmed, images: $state.get().images, delivery })
        picker.close()
        const state = $state.get()
        $state.set({ ...initialPromptState, inputEdit: { revision: state.inputEdit.revision + 1, text: "" } })
        void settled.catch(showError)
        return true
      } catch (cause) {
        showError(cause)
        return false
      }
    },
    draftChanged(text, cursorOffset) {
      const workflow = $state.get().workflow
      if (workflow.type !== "idle") {
        picker.queryChanged(text)
        return
      }

      const suggestions = commands.suggestions(text, cursorOffset)
      if (suggestions.length === 0) {
        if (picker.presentation(text)?.frame.id === commandFrameId) picker.close()
        return
      }
      const frame = commandFrame(suggestions)
      if (picker.presentation(text)?.frame.id === commandFrameId) picker.replaceTop(frame, text)
      else picker.open(frame)
    },
    completePicker(text, cursorOffset) {
      const presentation = picker.presentation(text)
      if (presentation?.frame.id !== commandFrameId || !presentation.selectedId) return false
      const command = commandFor(text, cursorOffset, presentation.selectedId)
      if (!command) return false
      picker.close()
      requestInput(commands.completion(command))
      return true
    },
    activatePicker(text, cursorOffset) {
      const presentation = picker.presentation(text)
      if (!presentation?.selectedId) return false

      if (presentation.frame.id === commandFrameId) {
        const command = commandFor(text, cursorOffset, presentation.selectedId)
        if (!command) return false
        return dispatchCommand(commands.parse(commands.completion(command).trim()), text)
      }

      if (presentation.frame.id === modelFrameId) {
        const workflow = $state.get().workflow
        if (workflow.type !== "choosing_model") return false
        const choice = workflow.choices.find(candidate => modelId(candidate) === presentation.selectedId)
        if (!choice) return false
        selectModel(workflow.operationId, mode.getSession(), choice)
        return true
      }

      return false
    },
    movePicker(filter, direction) {
      picker.move(filter, direction)
    },
    backPicker() {
      const presentation = picker.presentation("")
      if (!presentation) return false
      if (presentation.frame.id === commandFrameId) {
        picker.close()
        return true
      }

      const result = picker.back()
      const state = $state.get()
      $state.set({ ...state, workflow: { type: "idle" } })
      if (result.type === "revealed") requestInput(result.filter)
      else requestInput("")
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
      picker.close()
      const state = $state.get()
      $state.set({ ...initialPromptState, inputEdit: { revision: state.inputEdit.revision + 1, text: "" } })
    },
    dispose() {
      if (disposed) return
      disposed = true
      picker.dispose()
    }
  }
}

function commandFrame(commands: readonly BuiltinSlashCommand[]): PickerFrame {
  return {
    id: commandFrameId,
    title: "",
    filter: "none",
    rows: commands.map(command => ({
      id: command.name,
      label: `/${command.name}`,
      ...(command.argumentHint ? { detail: command.argumentHint } : {}),
      metadata: command.description,
      searchText: `${command.name} ${command.description} ${command.argumentHint ?? ""}`
    }))
  }
}

function modelFrame(
  choices: readonly ModelChoice[],
  current: ModelChoice["model"],
  emptyText = "No matching models"
): PickerFrame {
  return {
    id: modelFrameId,
    title: "Models",
    hint: "Only showing models from configured providers. Use /login to add providers.",
    filter: "fuzzy",
    emptyText,
    rows: choices.map(choice => ({
      id: modelId(choice),
      label: choice.model.id,
      detail: `[${choice.model.provider}]`,
      ...(sameModel(choice.model, current) ? { metadata: glyphs.check } : {}),
      searchText: modelSearchText(choice)
    })),
    ...(choices.some(choice => sameModel(choice.model, current)) ? { selectedId: modelIdFor(current) } : {})
  }
}

function modelSearchText(choice: ModelChoice): string {
  const { id, name, provider } = choice.model
  return `${provider} ${provider}/${id} ${provider} ${id}${name ? ` ${name}` : ""}`
}

function modelId(choice: ModelChoice): string {
  return modelIdFor(choice.model)
}

function modelIdFor(model: ModelChoice["model"]): string {
  return `${model.provider}/${model.id}`
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected interactive command: ${String(value)}`)
}

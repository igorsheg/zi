import type {
  AuthenticationEvent,
  AuthenticationMethod,
  AuthenticationPrompt,
  BuiltinSlashCommand,
  ImageContent,
  ModelChoice,
  PendingInputDelivery,
  QueuedInputs,
  StoredCredential
} from "@openzi/coding-agent"
import { atom, type ReadableAtom } from "nanostores"

import type { InteractiveCommands } from "../interactive-commands.js"
import { configuredModelChoices, exactModelChoice } from "../model-selector.js"
import {
  authenticationMethodId,
  authMethodFrame,
  authOptionFrame,
  authProviderFrame,
  commandFrame,
  logoutFrame,
  modelChoiceId,
  modelFrame,
  promptPickerFrameIds
} from "../prompt-picker-frames.js"
import type { InteractiveStore } from "./interactive.js"
import { createPickerStack, type PickerStack } from "./picker-stack.js"

export type PromptFeedback =
  | { readonly type: "none" }
  | { readonly type: "status"; readonly message: string }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "auth_link"; readonly requestId: number; readonly message: string; readonly url: string }

export type PromptWorkflow =
  | { readonly type: "idle" }
  | { readonly type: "loading_models"; readonly operationId: number }
  | { readonly type: "choosing_model"; readonly operationId: number; readonly choices: readonly ModelChoice[] }
  | { readonly type: "selecting_model"; readonly operationId: number }
  | {
      readonly type: "choosing_auth_provider"
      readonly operationId: number
      readonly methods: readonly AuthenticationMethod[]
    }
  | {
      readonly type: "choosing_auth_method"
      readonly operationId: number
      readonly methods: readonly AuthenticationMethod[]
    }
  | { readonly type: "authenticating"; readonly operationId: number; readonly providerId: string }
  | {
      readonly type: "auth_prompt"
      readonly operationId: number
      readonly providerId: string
      readonly promptType: "text" | "secret" | "manual_code"
    }
  | {
      readonly type: "choosing_auth_option"
      readonly operationId: number
      readonly providerId: string
      readonly options: readonly { readonly id: string; readonly label: string; readonly description?: string }[]
    }
  | { readonly type: "loading_logout"; readonly operationId: number }
  | {
      readonly type: "choosing_logout"
      readonly operationId: number
      readonly credentials: readonly StoredCredential[]
    }
  | { readonly type: "logging_out"; readonly operationId: number; readonly providerId: string }

export type PromptInputMode = "draft" | "auth_text" | "auth_secret"

export interface PromptInputEdit {
  readonly revision: number
  readonly text: string
}

export interface PromptState {
  readonly feedback: PromptFeedback
  readonly images: readonly ImageContent[]
  readonly workflow: PromptWorkflow
  readonly inputMode: PromptInputMode
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
  inputMode: "draft",
  inputEdit: { revision: 0, text: "" }
}

export function createPromptStore(mode: InteractiveStore, commands: InteractiveCommands): PromptStore {
  const $state = atom(initialPromptState)
  const picker = createPickerStack()
  let disposed = false
  let nextOperationId = 0
  let nextBrowserRequestId = 0
  let activeAuthenticationSession: ReturnType<InteractiveStore["getSession"]> | undefined
  let pendingAuthPrompt:
    | {
        readonly operationId: number
        readonly resolve: (answer: string) => void
        readonly reject: (cause: unknown) => void
        readonly cleanup: () => void
      }
    | undefined

  const requestInput = (text: string) => {
    const state = $state.get()
    $state.set({ ...state, inputEdit: { revision: state.inputEdit.revision + 1, text } })
  }

  const showError = (cause: unknown) => {
    if (disposed) return
    $state.set({ ...$state.get(), feedback: { type: "error", message: errorMessage(cause) } })
  }

  const finishAuthentication = (feedback: PromptFeedback) => {
    if (disposed) return
    pendingAuthPrompt?.cleanup()
    pendingAuthPrompt = undefined
    activeAuthenticationSession = undefined
    picker.close()
    const state = $state.get()
    $state.set({ ...state, feedback, workflow: { type: "idle" }, inputMode: "draft" })
    requestInput("")
  }

  const cancelAuthentication = () => {
    const workflow = $state.get().workflow
    if (
      workflow.type !== "authenticating" &&
      workflow.type !== "auth_prompt" &&
      workflow.type !== "choosing_auth_option"
    ) {
      return false
    }
    pendingAuthPrompt?.cleanup()
    pendingAuthPrompt?.reject(new Error("Authentication cancelled"))
    pendingAuthPrompt = undefined
    const session = activeAuthenticationSession ?? mode.getSession()
    activeAuthenticationSession = undefined
    const state = $state.get()
    $state.set({ ...state, feedback: { type: "none" }, workflow: { type: "idle" }, inputMode: "draft" })
    requestInput("")
    try {
      void session.abort().catch(showError)
    } catch (cause) {
      if (!disposed) showError(cause)
    }
    return true
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
    const current = session.modelState.type === "selected" ? session.modelState.model : undefined
    const loading = modelFrame([], current, "Loading models…")
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
      const choices = configuredModelChoices(loaded, current)
      const exact = initialSearch ? exactModelChoice(initialSearch, choices) : undefined
      if (exact) {
        selectModel(operationId, session, exact)
        return
      }
      picker.replaceTop(modelFrame(choices, current), initialSearch)
      $state.set({ ...$state.get(), workflow: { type: "choosing_model", operationId, choices } })
    }
    void load()
  }

  const startAuthentication = (method: AuthenticationMethod) => {
    const session = mode.getSession()
    activeAuthenticationSession = session
    const operationId = ++nextOperationId
    picker.close()
    const state = $state.get()
    $state.set({
      ...state,
      feedback: { type: "status", message: `Starting ${method.name}…` },
      workflow: { type: "authenticating", operationId, providerId: method.providerId },
      inputMode: "draft"
    })
    requestInput("")

    const prompt = (authPrompt: AuthenticationPrompt): Promise<string> => {
      if (!accepts(operationId, session)) return Promise.reject(new Error("Authentication cancelled"))
      return new Promise((resolve, reject) => {
        const onAbort = () => {
          if (pendingAuthPrompt?.operationId !== operationId) return
          pendingAuthPrompt = undefined
          picker.close()
          const current = $state.get()
          $state.set({
            ...current,
            workflow: { type: "authenticating", operationId, providerId: method.providerId },
            inputMode: "draft"
          })
          requestInput("")
          reject(new Error("Authentication prompt cancelled"))
        }
        authPrompt.signal?.addEventListener("abort", onAbort, { once: true })
        pendingAuthPrompt = {
          operationId,
          resolve,
          reject,
          cleanup: () => authPrompt.signal?.removeEventListener("abort", onAbort)
        }
        const next = $state.get()
        if (authPrompt.type === "select") {
          picker.open(authOptionFrame(authPrompt.options))
          $state.set({
            ...next,
            feedback: { type: "status", message: authPrompt.message },
            workflow: {
              type: "choosing_auth_option",
              operationId,
              providerId: method.providerId,
              options: authPrompt.options
            },
            inputMode: "draft"
          })
        } else {
          $state.set({
            ...next,
            feedback: { type: "status", message: authPrompt.message },
            workflow: { type: "auth_prompt", operationId, providerId: method.providerId, promptType: authPrompt.type },
            inputMode: authPrompt.type === "secret" ? "auth_secret" : "auth_text"
          })
        }
        requestInput("")
      })
    }

    const authenticate = async () => {
      try {
        await session.login(method.providerId, method.type, {
          prompt,
          notify(event) {
            if (!accepts(operationId, session)) return
            const next = $state.get()
            $state.set({ ...next, feedback: authenticationEventFeedback(event, ++nextBrowserRequestId) })
          }
        })
      } catch (cause) {
        if (accepts(operationId, session)) finishAuthentication({ type: "error", message: errorMessage(cause) })
        return
      }
      if (!accepts(operationId, session)) return
      finishAuthentication({ type: "status", message: `Logged in to ${method.providerName}` })
    }
    void authenticate()
  }

  const openLogin = (provider: string, parentFilter?: string) => {
    const methods = mode.getSession().authenticationMethods()
    if (methods.length === 0) {
      showError("No providers support interactive login")
      return
    }
    const operationId = ++nextOperationId
    const normalized = provider.trim().toLowerCase()
    const exact = normalized ? methods.filter(method => method.providerId.toLowerCase() === normalized) : []
    if (exact.length === 1) {
      startAuthentication(exact[0]!)
      return
    }
    if (exact.length > 1) {
      const frame = authMethodFrame(exact)
      if (parentFilter === undefined) picker.open(frame)
      else picker.push(frame, parentFilter)
      const state = $state.get()
      $state.set({
        ...state,
        feedback: { type: "none" },
        workflow: { type: "choosing_auth_method", operationId, methods: exact },
        inputMode: "draft"
      })
      requestInput("")
      return
    }

    const frame = authProviderFrame(methods)
    if (parentFilter === undefined) picker.open(frame)
    else picker.push(frame, parentFilter)
    const state = $state.get()
    $state.set({
      ...state,
      feedback: { type: "none" },
      workflow: { type: "choosing_auth_provider", operationId, methods },
      inputMode: "draft"
    })
    requestInput(provider)
  }

  const logoutProvider = (
    operationId: number,
    session: ReturnType<InteractiveStore["getSession"]>,
    providerId: string
  ) => {
    picker.close()
    const state = $state.get()
    $state.set({
      ...state,
      feedback: { type: "status", message: `Removing stored credentials for ${providerId}…` },
      workflow: { type: "logging_out", operationId, providerId },
      inputMode: "draft"
    })
    requestInput("")
    const apply = async () => {
      try {
        await session.logout(providerId)
      } catch (cause) {
        if (accepts(operationId, session)) finishAuthentication({ type: "error", message: errorMessage(cause) })
        return
      }
      if (!accepts(operationId, session)) return
      finishAuthentication({
        type: "status",
        message: `Logged out of ${providerId}; environment and external configuration remain available`
      })
    }
    void apply()
  }

  const logout = () => {
    const session = mode.getSession()
    const operationId = ++nextOperationId
    const state = $state.get()
    $state.set({
      ...state,
      feedback: { type: "status", message: "Loading stored credentials…" },
      workflow: { type: "loading_logout", operationId },
      inputMode: "draft"
    })
    requestInput("")
    const load = async () => {
      let stored: readonly StoredCredential[]
      try {
        stored = await session.storedCredentials()
      } catch (cause) {
        if (accepts(operationId, session)) finishAuthentication({ type: "error", message: errorMessage(cause) })
        return
      }
      if (!accepts(operationId, session)) return
      if (stored.length === 0) {
        finishAuthentication({ type: "status", message: "No stored credentials to remove" })
        return
      }
      if (stored.length === 1) {
        logoutProvider(operationId, session, stored[0]!.providerId)
        return
      }
      picker.open(logoutFrame(stored))
      const next = $state.get()
      $state.set({
        ...next,
        feedback: { type: "none" },
        workflow: { type: "choosing_logout", operationId, credentials: stored }
      })
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
      case "login":
        openLogin(command.provider, parentFilter)
        return true
      case "logout":
        logout()
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
      const workflow = $state.get().workflow
      if (workflow.type === "auth_prompt") {
        if (!text || pendingAuthPrompt?.operationId !== workflow.operationId) return false
        const pending = pendingAuthPrompt
        pending.cleanup()
        pendingAuthPrompt = undefined
        const state = $state.get()
        $state.set({
          ...state,
          workflow: { type: "authenticating", operationId: workflow.operationId, providerId: workflow.providerId },
          inputMode: "draft"
        })
        requestInput("")
        pending.resolve(text)
        return true
      }

      const trimmed = text.trim()
      if (!trimmed || workflow.type !== "idle") return false

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
      if (workflow.type === "auth_prompt" || workflow.type === "authenticating") return
      if (workflow.type !== "idle") {
        picker.queryChanged(text)
        return
      }

      const suggestions = commands.suggestions(text, cursorOffset)
      if (suggestions.length === 0) {
        if (picker.presentation(text)?.frame.id === promptPickerFrameIds.commands) picker.close()
        return
      }
      const frame = commandFrame(suggestions)
      if (picker.presentation(text)?.frame.id === promptPickerFrameIds.commands) picker.replaceTop(frame, text)
      else picker.open(frame)
    },
    completePicker(text, cursorOffset) {
      const presentation = picker.presentation(text)
      if (presentation?.frame.id !== promptPickerFrameIds.commands || !presentation.selectedId) return false
      const command = commandFor(text, cursorOffset, presentation.selectedId)
      if (!command) return false
      picker.close()
      requestInput(commands.completion(command))
      return true
    },
    activatePicker(text, cursorOffset) {
      const presentation = picker.presentation(text)
      if (!presentation?.selectedId) return false

      if (presentation.frame.id === promptPickerFrameIds.commands) {
        const command = commandFor(text, cursorOffset, presentation.selectedId)
        if (!command) return false
        return dispatchCommand(commands.parse(commands.completion(command).trim()), text)
      }

      if (presentation.frame.id === promptPickerFrameIds.models) {
        const workflow = $state.get().workflow
        if (workflow.type !== "choosing_model") return false
        const choice = workflow.choices.find(candidate => modelChoiceId(candidate) === presentation.selectedId)
        if (!choice) return false
        selectModel(workflow.operationId, mode.getSession(), choice)
        return true
      }

      if (presentation.frame.id === promptPickerFrameIds.authProviders) {
        const workflow = $state.get().workflow
        if (workflow.type !== "choosing_auth_provider") return false
        const methods = workflow.methods.filter(method => method.providerId === presentation.selectedId)
        if (methods.length === 1) {
          startAuthentication(methods[0]!)
          return true
        }
        if (methods.length === 0) return false
        picker.push(authMethodFrame(methods), text || presentation.selectedId)
        const state = $state.get()
        $state.set({ ...state, workflow: { type: "choosing_auth_method", operationId: workflow.operationId, methods } })
        requestInput("")
        return true
      }

      if (presentation.frame.id === promptPickerFrameIds.authMethods) {
        const workflow = $state.get().workflow
        if (workflow.type !== "choosing_auth_method") return false
        const method = workflow.methods.find(candidate => authenticationMethodId(candidate) === presentation.selectedId)
        if (!method) return false
        startAuthentication(method)
        return true
      }

      if (presentation.frame.id === promptPickerFrameIds.authOptions) {
        const workflow = $state.get().workflow
        if (workflow.type !== "choosing_auth_option" || pendingAuthPrompt?.operationId !== workflow.operationId) {
          return false
        }
        const option = workflow.options.find(candidate => candidate.id === presentation.selectedId)
        if (!option) return false
        const pending = pendingAuthPrompt
        pending.cleanup()
        pendingAuthPrompt = undefined
        picker.close()
        const state = $state.get()
        $state.set({
          ...state,
          workflow: { type: "authenticating", operationId: workflow.operationId, providerId: workflow.providerId },
          inputMode: "draft"
        })
        requestInput("")
        pending.resolve(option.id)
        return true
      }

      if (presentation.frame.id === promptPickerFrameIds.logoutProviders) {
        const workflow = $state.get().workflow
        if (workflow.type !== "choosing_logout") return false
        const credential = workflow.credentials.find(candidate => candidate.providerId === presentation.selectedId)
        if (!credential) return false
        logoutProvider(workflow.operationId, mode.getSession(), credential.providerId)
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
      if (presentation.frame.id === promptPickerFrameIds.commands) {
        picker.close()
        return true
      }
      if (presentation.frame.id === promptPickerFrameIds.authOptions) return cancelAuthentication()

      const result = picker.back()
      const state = $state.get()
      if (presentation.frame.id === promptPickerFrameIds.authMethods && result.type === "revealed") {
        const operationId =
          state.workflow.type === "choosing_auth_method" ? state.workflow.operationId : ++nextOperationId
        const allMethods = mode.getSession().authenticationMethods()
        const revealedProviderFrame =
          picker.presentation(result.filter)?.frame.id === promptPickerFrameIds.authProviders
        $state.set({
          ...state,
          workflow: revealedProviderFrame
            ? { type: "choosing_auth_provider", operationId, methods: allMethods }
            : { type: "idle" }
        })
      } else {
        $state.set({ ...state, workflow: { type: "idle" } })
      }
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
      if (cancelAuthentication()) return ""
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
      if (cancelAuthentication()) return
      picker.close()
      const state = $state.get()
      $state.set({ ...initialPromptState, inputEdit: { revision: state.inputEdit.revision + 1, text: "" } })
    },
    dispose() {
      if (disposed) return
      cancelAuthentication()
      disposed = true
      picker.dispose()
    }
  }
}

function authenticationEventFeedback(event: AuthenticationEvent, requestId: number): PromptFeedback {
  switch (event.type) {
    case "auth_url":
      return { type: "auth_link", requestId, message: event.instructions ?? "Open", url: event.url }
    case "device_code":
      return { type: "auth_link", requestId, message: `Enter ${event.userCode} at`, url: event.verificationUri }
    case "progress":
      return { type: "status", message: event.message }
    default:
      return assertNever(event)
  }
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function assertNever(value: never): never {
  throw new Error(`Unexpected closed value: ${String(value)}`)
}

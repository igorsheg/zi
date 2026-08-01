import type {
  AgentSession,
  AuthenticationEvent,
  AuthenticationMethod,
  AuthenticationPrompt,
  ImageContent,
  ModelChoice,
  PendingInputDelivery,
  ProjectTrustSelection,
  QueueMode,
  QueuedInputs,
  SessionReloadResult,
  SettingsScope,
  SessionListResult,
  SessionReplacementCancellation,
  StoredCredential,
  ThinkingLevel
} from "@with-zi/coding-agent"
import { atom, type ReadableAtom } from "nanostores"

import { promptTextWidth } from "../../components/cell-text.js"
import {
  detectClipboardImageMimeType,
  maxClipboardImageBytes,
  maxPastedTextBytes,
  type ClipboardContent,
  type ClipboardReader
} from "../clipboard.js"
import type { InteractiveStore } from "../interactive-store.js"
import type { InteractiveCommand, SlashController } from "../slash-controller.js"
import type { ReloadNoticeOutcome, SystemNoticeActions } from "../system-notifications.js"
import { FileCompletionController, type FileCompletionInput, type FileCompletionRangeEdit } from "./file-completion.js"
import {
  authenticationMethodId,
  authMethodFrame,
  authOptionFrame,
  authProviderFrame,
  codexFastModeValuesFrame,
  codexSettingsFrame,
  commandFrame,
  logoutFrame,
  modelChoiceId,
  modelFrame,
  projectTrustFrame,
  projectTrustSelection,
  promptPickerFrameIds,
  sessionFrame,
  settingLabel,
  settingsFrame,
  settingsScopeFrame,
  settingValuesFrame
} from "./frames.js"
import { configuredModelChoices, exactModelChoice } from "./model-choices.js"
import { createPickerStack, type PickerPresentation, type PickerStack } from "./picker.js"
import {
  initialPromptState,
  type AuthCeremony,
  type EditableSetting,
  type EditableSettingValue,
  type PromptFeedback,
  type PromptState,
  type PromptWorkflow
} from "./state.js"

export interface PromptStore {
  readonly $state: ReadableAtom<PromptState>
  readonly picker: PickerStack
  submit(text: string, delivery: PendingInputDelivery): boolean
  draftChanged(text: string, input: FileCompletionInput): void
  cursorChanged(text: string, input: FileCompletionInput): void
  completePicker(text: string, input: FileCompletionInput): boolean
  activatePicker(text: string, input: FileCompletionInput): boolean
  movePicker(filter: string, direction: -1 | 1): void
  backPicker(): boolean
  requestProjectTrust(cwd: string): void
  restoreQueuedInputs(currentText: string): string
  abortAndRestoreQueuedInputs(currentText: string): string
  pasteClipboard(): Promise<string | undefined>
  attachImage(image: Extract<ClipboardContent, { type: "image" }>): boolean
  imageMarkersChanged(images: readonly ImageContent[]): void
  reportFeedback(feedback: PromptFeedback): void
  clear(): void
  dispose(): void
}

interface PendingAuthPrompt {
  readonly operationId: number
  readonly resolve: (answer: string) => void
  readonly reject: (cause: unknown) => void
  readonly cleanup: () => void
}

type ClipboardReadState =
  | { readonly type: "idle" }
  | {
      readonly type: "reading"
      readonly operationId: number
      readonly session: AgentSession
      readonly controller: AbortController
    }

export const maxPromptClipboardImages = 8
export const maxPromptClipboardEncodedBytes = 8 * 1024 * 1024

const unavailableClipboard: ClipboardReader = { read: async () => undefined }
const unavailableSystemNotices: SystemNoticeActions = {
  backgroundTaskCapacityExceeded() {},
  reloadCompleted() {},
  reloadFailed() {}
}

export interface PromptSessionActions {
  listSessions(): Promise<SessionListResult>
  startNewSession(): Promise<void>
  resumeSession(path: string): Promise<void>
  decideProjectTrust(selection: ProjectTrustSelection): Promise<void>
  dismissProjectTrust(): void
  cancelReplacement(): SessionReplacementCancellation
}

export function createPromptStore(
  interactive: InteractiveStore,
  slash: SlashController,
  sessionActions?: PromptSessionActions,
  clipboard: ClipboardReader = unavailableClipboard,
  systemNotices: SystemNoticeActions = unavailableSystemNotices
): PromptStore {
  return new PromptController(interactive, slash, sessionActions, clipboard, systemNotices)
}

class PromptController implements PromptStore {
  readonly $state = atom(initialPromptState)
  readonly picker = createPickerStack()

  readonly #interactive: InteractiveStore
  readonly #slash: SlashController
  readonly #sessionActions: PromptSessionActions | undefined
  readonly #clipboard: ClipboardReader
  readonly #systemNotices: SystemNoticeActions
  readonly #fileCompletion: FileCompletionController
  #clipboardRead: ClipboardReadState = { type: "idle" }
  #draftRevision = 0
  #disposed = false
  #nextOperationId = 0
  #nextBrowserRequestId = 0
  #pendingAuthPrompt: PendingAuthPrompt | undefined
  #cancelledCompactionOperationId: number | undefined

  constructor(
    interactive: InteractiveStore,
    slash: SlashController,
    sessionActions: PromptSessionActions | undefined,
    clipboard: ClipboardReader,
    systemNotices: SystemNoticeActions
  ) {
    this.#interactive = interactive
    this.#slash = slash
    this.#sessionActions = sessionActions
    this.#clipboard = clipboard
    this.#systemNotices = systemNotices
    this.#fileCompletion = new FileCompletionController(this.picker, edit => this.#requestRange(edit))
  }

  submit(text: string, delivery: PendingInputDelivery): boolean {
    const workflow = this.$state.get().workflow
    if (workflow.type === "auth_prompt") return this.#submitAuthenticationPrompt(text, workflow)

    const trimmed = text.trim()
    const state = this.$state.get()
    if ((!trimmed && state.images.length === 0) || workflow.type !== "idle") return false

    const command = trimmed ? this.#slash.parse(trimmed) : undefined
    if (this.#dispatchCommand(command)) return true

    this.#fileCompletion.close()
    try {
      const model = this.#interactive.getSession().modelState
      if (state.images.length > 0 && (model.type !== "selected" || !model.model.input.includes("image"))) {
        this.reportFeedback({ type: "warning", message: "The current model does not accept image input" })
        return false
      }
      const settled = this.#interactive.submit({ text: trimmed, images: state.images, delivery })
      this.#cancelClipboardRead()
      this.picker.close()
      this.$state.set({
        ...initialPromptState,
        inputEdit: { type: "replace", revision: state.inputEdit.revision + 1, text: "", cursorOffset: 0 }
      })
      void settled.catch(cause => this.#showError(cause))
      return true
    } catch (cause) {
      this.#showError(cause)
      return false
    }
  }

  draftChanged(text: string, input: FileCompletionInput): void {
    this.#draftRevision++
    this.#completionContextChanged(text, input, true)
  }

  cursorChanged(text: string, input: FileCompletionInput): void {
    this.#completionContextChanged(text, input, false)
  }

  completePicker(text: string, input: FileCompletionInput): boolean {
    const presentation = this.picker.presentation(text)
    if (!presentation?.selectedId || presentation.frame.disabled) return false
    if (presentation.frame.id === promptPickerFrameIds.files) {
      return this.#fileCompletion.complete(presentation.selectedId, input)
    }
    if (presentation.frame.id !== promptPickerFrameIds.commands) return false
    const result = this.#slash.complete(text, input.cursorOffset, presentation.selectedId)
    switch (result.type) {
      case "unavailable":
        this.picker.close()
        return false
      case "edit":
        this.picker.close()
        this.#requestInput(result.text, result.cursorOffset)
        return true
      default:
        return assertNever(result)
    }
  }

  activatePicker(text: string, input: FileCompletionInput): boolean {
    const presentation = this.picker.presentation(text)
    if (!presentation?.selectedId || presentation.frame.disabled) return false

    const workflow = this.$state.get().workflow
    switch (workflow.type) {
      case "idle":
        if (presentation.frame.id === promptPickerFrameIds.commands) {
          return this.#activateCommand(presentation, text, input.cursorOffset)
        }
        if (presentation.frame.id === promptPickerFrameIds.files) {
          return this.#fileCompletion.complete(presentation.selectedId, input)
        }
        return false
      case "choosing_codex_setting":
        return this.#activateCodexSetting(workflow, presentation, text)
      case "choosing_codex_fast_mode":
        return this.#activateCodexFastMode(workflow, presentation)
      case "choosing_settings_scope":
        return this.#activateSettingsScope(workflow, presentation, text)
      case "choosing_setting":
        return this.#activateSetting(workflow, presentation, text)
      case "choosing_setting_value":
        return this.#activateSettingValue(workflow, presentation)
      case "choosing_model":
        return this.#activateModel(workflow, presentation)
      case "choosing_auth_provider":
        return this.#activateAuthProvider(workflow, presentation, text)
      case "choosing_auth_method":
        return this.#activateAuthMethod(workflow, presentation)
      case "choosing_auth_option":
        return this.#activateAuthOption(workflow, presentation)
      case "choosing_logout":
        return this.#activateLogout(workflow, presentation)
      case "choosing_session":
        return this.#activateSession(workflow, presentation)
      case "choosing_project_trust":
        return this.#activateProjectTrust(workflow, presentation)
      case "loading_models":
      case "selecting_model":
      case "authenticating":
      case "auth_prompt":
      case "loading_logout":
      case "logging_out":
      case "compacting":
      case "reloading":
      case "starting_session":
      case "loading_sessions":
      case "resuming_session":
      case "cancelling_session":
      case "saving_project_trust":
        return false
      default:
        return assertNever(workflow)
    }
  }

  movePicker(filter: string, direction: -1 | 1): void {
    this.picker.move(filter, direction)
  }

  backPicker(): boolean {
    const presentation = this.picker.presentation("")
    if (!presentation) return false

    const workflow = this.$state.get().workflow
    if (
      workflow.type === "resuming_session" ||
      workflow.type === "saving_project_trust" ||
      workflow.type === "cancelling_session"
    ) {
      return this.#cancelSessionReplacement()
    }
    if (workflow.type === "idle" && presentation.frame.id === promptPickerFrameIds.commands) {
      this.picker.close()
      return true
    }
    if (workflow.type === "idle" && presentation.frame.id === promptPickerFrameIds.files) {
      this.#fileCompletion.dismiss()
      return true
    }
    if (workflow.type === "choosing_auth_option") return this.#cancelAuthentication()
    if (workflow.type === "choosing_project_trust") {
      this.picker.close()
      this.#sessionActions?.dismissProjectTrust()
      this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
      this.#requestInput("")
      return true
    }

    const result = this.picker.back()
    switch (workflow.type) {
      case "choosing_codex_fast_mode":
        if (result.type === "revealed") {
          this.$state.set({
            ...this.$state.get(),
            workflow: { type: "choosing_codex_setting", operationId: workflow.operationId, session: workflow.session }
          })
        } else {
          this.#setIdle()
        }
        break
      case "choosing_setting_value":
        if (result.type === "revealed") {
          this.$state.set({
            ...this.$state.get(),
            workflow: {
              type: "choosing_setting",
              operationId: workflow.operationId,
              session: workflow.session,
              scope: workflow.scope
            }
          })
        } else {
          this.#setIdle()
        }
        break
      case "choosing_setting":
        if (result.type === "revealed") {
          this.$state.set({
            ...this.$state.get(),
            workflow: { type: "choosing_settings_scope", operationId: workflow.operationId, session: workflow.session }
          })
        } else {
          this.#setIdle()
        }
        break
      case "choosing_auth_method": {
        const providerFrame =
          result.type === "revealed" &&
          this.picker.presentation(result.filter)?.frame.id === promptPickerFrameIds.authProviders
        this.$state.set({
          ...this.$state.get(),
          workflow: providerFrame
            ? {
                type: "choosing_auth_provider",
                operationId: workflow.operationId,
                session: workflow.session,
                methods: workflow.session.authenticationMethods()
              }
            : { type: "idle" }
        })
        break
      }
      case "idle":
      case "loading_models":
      case "choosing_model":
      case "selecting_model":
      case "choosing_auth_provider":
      case "authenticating":
      case "auth_prompt":
      case "loading_logout":
      case "choosing_logout":
      case "logging_out":
      case "compacting":
      case "reloading":
      case "starting_session":
      case "loading_sessions":
      case "choosing_session":
      case "choosing_codex_setting":
      case "choosing_settings_scope":
        this.#setIdle()
        break
      default:
        assertNever(workflow)
    }

    this.#requestInput(result.type === "revealed" ? result.filter : "")
    return true
  }

  requestProjectTrust(cwd: string): void {
    if (this.#disposed || this.$state.get().workflow.type !== "idle") return
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.picker.open(projectTrustFrame(cwd))
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "choosing_project_trust", operationId, session, cwd }
    })
    this.#requestInput("")
  }

  restoreQueuedInputs(currentText: string): string {
    try {
      return this.#mergeQueue(this.#interactive.restoreQueuedInputs(), currentText, true)
    } catch (cause) {
      this.#showError(cause)
      return currentText
    }
  }

  abortAndRestoreQueuedInputs(currentText: string): string {
    if (this.#cancelAuthentication() || this.#cancelCompaction() || this.#cancelSessionReplacement()) return ""
    try {
      const aborted = this.#interactive.abortAndRestoreQueuedInputs()
      const text = this.#mergeQueue(aborted, currentText, false)
      void aborted.settled.catch(cause => this.#showError(cause))
      return text
    } catch (cause) {
      this.#showError(cause)
      return currentText
    }
  }

  async pasteClipboard(): Promise<string | undefined> {
    if (this.#disposed) return undefined
    let session: AgentSession
    try {
      session = this.#interactive.getSession()
    } catch (cause) {
      this.#showError(cause)
      return undefined
    }
    this.#cancelClipboardRead()
    const reading: Extract<ClipboardReadState, { type: "reading" }> = {
      type: "reading",
      operationId: ++this.#nextOperationId,
      session,
      controller: new AbortController()
    }
    this.#clipboardRead = reading

    let content: ClipboardContent | undefined
    try {
      content = await this.#clipboard.read(reading.controller.signal)
    } catch (cause) {
      if (!this.#finishClipboardRead(reading)) return undefined
      if (reading.controller.signal.aborted) return undefined
      this.#showError(cause)
      return undefined
    }
    if (!this.#finishClipboardRead(reading)) return undefined

    if (!content) {
      this.reportFeedback({ type: "warning", message: "Clipboard is empty or unavailable" })
      return undefined
    }
    if (content.type === "image") {
      this.attachImage(content)
      return undefined
    }
    if (Buffer.byteLength(content.text) > maxPastedTextBytes) {
      this.reportFeedback({ type: "error", message: "Clipboard text exceeds the 1 MiB paste limit" })
      return undefined
    }
    return content.text
  }

  attachImage(image: Extract<ClipboardContent, { type: "image" }>): boolean {
    if (this.#disposed) return false
    const state = this.$state.get()
    if (state.workflow.type !== "idle") {
      this.reportFeedback({ type: "warning", message: "Images cannot be attached during the active prompt workflow" })
      return false
    }

    let session: AgentSession
    try {
      session = this.#interactive.getSession()
    } catch (cause) {
      this.#showError(cause)
      return false
    }
    if (session.modelState.type !== "selected" || !session.modelState.model.input.includes("image")) {
      this.reportFeedback({ type: "warning", message: "The current model does not accept image input" })
      return false
    }
    if (image.bytes.byteLength === 0 || image.bytes.byteLength > maxClipboardImageBytes) {
      this.reportFeedback({ type: "error", message: "Clipboard image exceeds the 4.5 MiB encoded image limit" })
      return false
    }

    const mimeType = detectClipboardImageMimeType(image.bytes)
    if (!mimeType) {
      this.reportFeedback({ type: "warning", message: "Clipboard image must be PNG, JPEG, WebP, or GIF" })
      return false
    }
    if (state.images.length >= maxPromptClipboardImages) {
      this.reportFeedback({
        type: "error",
        message: `A prompt cannot contain more than ${maxPromptClipboardImages} pasted images`
      })
      return false
    }

    const data = Buffer.from(image.bytes).toString("base64")
    const retainedBytes = state.images.reduce((bytes, entry) => bytes + Buffer.byteLength(entry.data), 0)
    if (retainedBytes + Buffer.byteLength(data) > maxPromptClipboardEncodedBytes) {
      this.reportFeedback({ type: "error", message: "Pasted images exceed the 8 MiB prompt attachment limit" })
      return false
    }

    const images = [...state.images, { type: "image" as const, data, mimeType }]
    this.$state.set({
      ...state,
      images,
      feedback: {
        type: "status",
        message: `Attached image ${images.length} (${mimeType.slice("image/".length).toUpperCase()})`
      }
    })
    return true
  }

  imageMarkersChanged(images: readonly ImageContent[]): void {
    if (this.#disposed) return
    const state = this.$state.get()
    if (
      images.length > maxPromptClipboardImages ||
      images.reduce((bytes, image) => bytes + Buffer.byteLength(image.data), 0) > maxPromptClipboardEncodedBytes
    ) {
      return
    }
    if (images.length === state.images.length && images.every((image, index) => image === state.images[index])) return

    const feedback: PromptFeedback =
      images.length < state.images.length
        ? imageMarkerFeedback("Removed", state.images.length - images.length)
        : images.length > state.images.length
          ? imageMarkerFeedback("Restored", images.length - state.images.length)
          : state.feedback
    this.$state.set({ ...state, images: [...images], feedback })
  }

  reportFeedback(feedback: PromptFeedback): void {
    if (this.#disposed) return
    this.$state.set({ ...this.$state.get(), feedback })
  }

  clear(): void {
    this.#cancelClipboardRead()
    if (this.#cancelAuthentication() || this.#cancelCompaction() || this.#cancelSessionReplacement()) return
    this.#fileCompletion.close()
    this.picker.close()
    const state = this.$state.get()
    this.$state.set({
      ...initialPromptState,
      inputEdit: { type: "replace", revision: state.inputEdit.revision + 1, text: "", cursorOffset: 0 }
    })
  }

  dispose(): void {
    if (this.#disposed) return
    this.#cancelClipboardRead()
    this.#cancelAuthentication()
    this.#cancelCompaction()
    this.#cancelSessionReplacement()
    this.#disposed = true
    this.#fileCompletion.dispose()
    this.picker.dispose()
  }

  #activateCommand(presentation: PickerPresentation, text: string, cursorOffset: number): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.commands || !presentation.selectedId) return false
    const result = this.#slash.activate(text, cursorOffset, presentation.selectedId)
    switch (result.type) {
      case "unavailable":
        this.picker.close()
        return false
      case "edit":
        this.picker.close()
        this.#requestInput(result.text, result.cursorOffset)
        return true
      case "intent":
        return this.#dispatchCommand(result.command, text)
      default:
        return assertNever(result)
    }
  }

  #activateCodexSetting(
    workflow: Extract<PromptWorkflow, { type: "choosing_codex_setting" }>,
    presentation: PickerPresentation,
    text: string
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.codexSettings || presentation.selectedId !== "fast-mode") {
      return false
    }
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    this.picker.push(codexFastModeValuesFrame(workflow.session), text || presentation.selectedId)
    this.$state.set({
      ...this.$state.get(),
      workflow: { type: "choosing_codex_fast_mode", operationId: workflow.operationId, session: workflow.session }
    })
    this.#requestInput("")
    return true
  }

  #activateCodexFastMode(
    workflow: Extract<PromptWorkflow, { type: "choosing_codex_fast_mode" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.codexSettingValues || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    if (presentation.selectedId !== "true" && presentation.selectedId !== "false") return false

    let mutation: ReturnType<AgentSession["setCodexFastMode"]>
    try {
      mutation = workflow.session.setCodexFastMode(presentation.selectedId === "true")
    } catch (cause) {
      this.#showError(cause)
      return false
    }
    if (!this.#accepts(workflow.operationId, workflow.session)) return false

    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: {
        type: "status",
        message:
          mutation.requested === mutation.effective
            ? `Codex Fast mode: ${settingValueLabel(mutation.effective)}`
            : `Codex Fast mode saved as ${settingValueLabel(mutation.requested)}; project settings keep ${settingValueLabel(mutation.effective)} effective`
      },
      workflow: { type: "idle" }
    })
    this.#requestInput("")
    return true
  }

  #activateSettingsScope(
    workflow: Extract<PromptWorkflow, { type: "choosing_settings_scope" }>,
    presentation: PickerPresentation,
    text: string
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.settingsScopes || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const scope = settingsScope(presentation.selectedId)
    if (!scope) return false
    this.picker.push(settingsFrame(workflow.session, scope), text || presentation.selectedId)
    this.$state.set({
      ...this.$state.get(),
      workflow: { type: "choosing_setting", operationId: workflow.operationId, session: workflow.session, scope }
    })
    this.#requestInput("")
    return true
  }

  #activateSetting(
    workflow: Extract<PromptWorkflow, { type: "choosing_setting" }>,
    presentation: PickerPresentation,
    text: string
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.settings || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const setting = editableSetting(presentation.selectedId)
    if (!setting) return false
    this.picker.push(settingValuesFrame(workflow.session, workflow.scope, setting), text || presentation.selectedId)
    this.$state.set({
      ...this.$state.get(),
      workflow: {
        type: "choosing_setting_value",
        operationId: workflow.operationId,
        session: workflow.session,
        scope: workflow.scope,
        setting
      }
    })
    this.#requestInput("")
    return true
  }

  #activateSettingValue(
    workflow: Extract<PromptWorkflow, { type: "choosing_setting_value" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.settingValues || !presentation.selectedId) return false
    return this.#applySetting(workflow, presentation.selectedId)
  }

  #activateModel(
    workflow: Extract<PromptWorkflow, { type: "choosing_model" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.models || !presentation.selectedId) return false
    const choice = workflow.choices.find(candidate => modelChoiceId(candidate) === presentation.selectedId)
    if (!choice) return false
    this.#selectModel(workflow.operationId, workflow.session, choice)
    return true
  }

  #activateAuthProvider(
    workflow: Extract<PromptWorkflow, { type: "choosing_auth_provider" }>,
    presentation: PickerPresentation,
    text: string
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.authProviders || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const methods = workflow.methods.filter(method => method.providerId === presentation.selectedId)
    if (methods.length === 1) {
      this.#startAuthentication(workflow.session, methods[0]!)
      return true
    }
    if (methods.length === 0) return false
    this.picker.push(authMethodFrame(methods), text || presentation.selectedId)
    this.$state.set({
      ...this.$state.get(),
      workflow: { type: "choosing_auth_method", operationId: workflow.operationId, session: workflow.session, methods }
    })
    this.#requestInput("")
    return true
  }

  #activateAuthMethod(
    workflow: Extract<PromptWorkflow, { type: "choosing_auth_method" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.authMethods || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const method = workflow.methods.find(candidate => authenticationMethodId(candidate) === presentation.selectedId)
    if (!method) return false
    this.#startAuthentication(workflow.session, method)
    return true
  }

  #activateAuthOption(
    workflow: Extract<PromptWorkflow, { type: "choosing_auth_option" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.authOptions || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    if (this.#pendingAuthPrompt?.operationId !== workflow.operationId) return false
    const option = workflow.options.find(candidate => candidate.id === presentation.selectedId)
    if (!option) return false

    const pending = this.#pendingAuthPrompt
    pending.cleanup()
    this.#pendingAuthPrompt = undefined
    this.picker.close()
    const state = this.$state.get()
    this.$state.set({
      ...state,
      authCeremony: clearCeremonyChoice(state.authCeremony),
      workflow: {
        type: "authenticating",
        operationId: workflow.operationId,
        session: workflow.session,
        providerId: workflow.providerId
      }
    })
    this.#requestInput("")
    pending.resolve(option.id)
    return true
  }

  #activateLogout(
    workflow: Extract<PromptWorkflow, { type: "choosing_logout" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.logoutProviders || !presentation.selectedId) return false
    const credential = workflow.credentials.find(candidate => candidate.providerId === presentation.selectedId)
    if (!credential) return false
    this.#logoutProvider(workflow.operationId, workflow.session, credential.providerId)
    return true
  }

  #activateSession(
    workflow: Extract<PromptWorkflow, { type: "choosing_session" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.sessions || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const selected = workflow.sessions.find(session => session.path === presentation.selectedId)
    if (!selected) return false
    if (selected.path === workflow.session.sessionManager.file) {
      this.picker.close()
      this.$state.set({
        ...this.$state.get(),
        feedback: { type: "status", message: "Session already active" },
        workflow: { type: "idle" }
      })
      this.#requestInput("")
      return true
    }
    const actions = this.#sessionActions
    if (!actions) {
      this.#showError("Session runtime is unavailable")
      return false
    }

    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: "Resuming session…" },
      workflow: { type: "resuming_session", operationId: workflow.operationId, session: workflow.session }
    })
    this.picker.replaceTop({ ...presentation.frame, footer: "Resuming session…" }, "")
    this.#requestInput("")

    const resume = async () => {
      try {
        await actions.resumeSession(selected.path)
      } catch (cause) {
        if (!this.#accepts(workflow.operationId, workflow.session)) return
        this.picker.replaceTop(sessionFrame(workflow.sessions, workflow.session.sessionManager.file), "")
        this.$state.set({ ...this.$state.get(), feedback: { type: "error", message: errorMessage(cause) }, workflow })
        return
      }
      if (!this.#accepts(workflow.operationId, workflow.session)) return
      this.picker.close()
      this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
      this.#requestInput("")
    }
    void resume()
    return true
  }

  #activateProjectTrust(
    workflow: Extract<PromptWorkflow, { type: "choosing_project_trust" }>,
    presentation: PickerPresentation
  ): boolean {
    if (presentation.frame.id !== promptPickerFrameIds.projectTrust || !presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const selected = projectTrustSelection(presentation.selectedId)
    if (!selected) return false
    const actions = this.#sessionActions
    if (!actions) {
      this.#showError("Session runtime is unavailable")
      return false
    }

    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: "Applying project trust…" },
      workflow: {
        type: "saving_project_trust",
        operationId: workflow.operationId,
        session: workflow.session,
        cwd: workflow.cwd,
        selection: selected.selection
      }
    })
    this.picker.replaceTop(projectTrustFrame(workflow.cwd, selected.id, true), "")
    this.#requestInput("")

    const apply = async () => {
      try {
        await actions.decideProjectTrust(selected.selection)
      } catch (cause) {
        if (!this.#accepts(workflow.operationId, workflow.session)) return
        this.picker.replaceTop(projectTrustFrame(workflow.cwd, selected.id), "")
        this.$state.set({ ...this.$state.get(), feedback: { type: "error", message: errorMessage(cause) }, workflow })
        return
      }
      if (!this.#accepts(workflow.operationId, workflow.session)) return
      this.picker.close()
      this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
      this.#requestInput("")
    }
    void apply()
    return true
  }

  #dispatchCommand(command: InteractiveCommand | undefined, parentFilter?: string): boolean {
    if (!command) return false
    this.#fileCompletion.close()
    switch (command.type) {
      case "model":
        this.#openModels(command.search, parentFilter)
        return true
      case "login":
        this.#openLogin(command.provider, parentFilter)
        return true
      case "logout":
        this.#logout()
        return true
      case "settings":
        this.#openSettings(parentFilter)
        return true
      case "codex_settings":
        this.#openCodexSettings(parentFilter)
        return true
      case "compact":
        this.#compact(command.instructions)
        return true
      case "reload":
        this.#reload()
        return true
      case "new_session":
        this.#startNewSession()
        return true
      case "resume_session":
        this.#openSessions(parentFilter)
        return true
      default:
        return assertNever(command)
    }
  }

  #compact(instructions: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.#cancelledCompactionOperationId = undefined
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "compacting", operationId, session }
    })
    this.#requestInput("")

    const compact = async () => {
      try {
        const result = await session.compact(instructions || undefined)
        if (!this.#accepts(operationId, session)) return
        this.#cancelledCompactionOperationId = undefined
        this.$state.set({
          ...this.$state.get(),
          feedback: {
            type: "status",
            message: `Compacted ${formatTokens(result.tokensBefore)} → ~${formatTokens(result.estimatedTokensAfter)} context tokens.`
          },
          workflow: { type: "idle" }
        })
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        const cancelled = this.#cancelledCompactionOperationId === operationId
        this.#cancelledCompactionOperationId = undefined
        this.$state.set({
          ...this.$state.get(),
          feedback: cancelled ? { type: "none" } : { type: "error", message: errorMessage(cause) },
          workflow: { type: "idle" }
        })
      }
    }
    void compact()
  }

  #reload(): void {
    const session = this.#interactive.getSession()
    if (session.isStreaming) {
      this.reportFeedback({ type: "warning", message: "Wait for the current response before reloading" })
      return
    }
    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: "Reloading…" },
      workflow: { type: "reloading", operationId, session }
    })
    this.#requestInput("")

    const reload = async () => {
      let result: SessionReloadResult
      try {
        result = await session.reload()
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
        this.#systemNotices.reloadFailed(errorMessage(cause))
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#slash.invalidateCatalog()
      const outcome = reloadNoticeOutcome(result)
      const message = reloadStatusMessage(result)
      this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
      this.#systemNotices.reloadCompleted(outcome, message)
    }
    void reload()
  }

  #startNewSession(): void {
    const actions = this.#sessionActions
    if (!actions) {
      this.#showError("Session runtime is unavailable")
      return
    }
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: "Starting new session…" },
      workflow: { type: "starting_session", operationId, session }
    })
    this.#requestInput("")

    const start = async () => {
      try {
        await actions.startNewSession()
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.$state.set({
            ...this.$state.get(),
            feedback: { type: "error", message: errorMessage(cause) },
            workflow: { type: "idle" }
          })
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
      this.#requestInput("")
    }
    void start()
  }

  #openSessions(parentFilter?: string): void {
    const actions = this.#sessionActions
    if (!actions) {
      this.#showError("Session runtime is unavailable")
      return
    }
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    const loading = sessionFrame([], session.sessionManager.file, { emptyText: "Loading sessions…" })
    if (parentFilter === undefined) this.picker.open(loading)
    else this.picker.push(loading, parentFilter)
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "loading_sessions", operationId, session }
    })
    this.#requestInput("")

    const load = async () => {
      let listed: SessionListResult
      try {
        listed = await actions.listSessions()
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        this.picker.replaceTop(sessionFrame([], session.sessionManager.file, { emptyText: errorMessage(cause) }), "")
        this.$state.set({
          ...this.$state.get(),
          workflow: { type: "choosing_session", operationId, session, sessions: [] }
        })
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.picker.replaceTop(
        sessionFrame(listed.sessions, session.sessionManager.file, {
          invalid: listed.invalid,
          omitted: listed.omitted
        }),
        ""
      )
      this.$state.set({
        ...this.$state.get(),
        workflow: { type: "choosing_session", operationId, session, sessions: listed.sessions }
      })
    }
    void load()
  }

  #openModels(initialSearch: string, parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "loading_models", operationId, session }
    })
    const current = session.modelState.type === "selected" ? session.modelState.model : undefined
    const loading = modelFrame([], current, "Loading models…")
    if (parentFilter === undefined) this.picker.open(loading)
    else this.picker.push(loading, parentFilter)
    this.#requestInput(initialSearch)

    const load = async () => {
      let loaded: readonly ModelChoice[]
      try {
        loaded = await session.listModelChoices()
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        this.picker.replaceTop({ ...loading, emptyText: errorMessage(cause) }, initialSearch)
        this.$state.set({
          ...this.$state.get(),
          workflow: { type: "choosing_model", operationId, session, choices: [] }
        })
        return
      }

      if (!this.#accepts(operationId, session)) return
      const choices = configuredModelChoices(loaded, current)
      const exact = initialSearch ? exactModelChoice(initialSearch, choices) : undefined
      if (exact) {
        this.#selectModel(operationId, session, exact)
        return
      }
      this.picker.replaceTop(modelFrame(choices, current), initialSearch)
      this.$state.set({ ...this.$state.get(), workflow: { type: "choosing_model", operationId, session, choices } })
    }
    void load()
  }

  #selectModel(operationId: number, session: AgentSession, choice: ModelChoice): void {
    if (!this.#accepts(operationId, session)) return
    this.$state.set({ ...this.$state.get(), workflow: { type: "selecting_model", operationId, session } })
    const presentation = this.picker.presentation("")
    if (presentation) {
      this.picker.replaceTop(
        { ...presentation.frame, emptyText: "Selecting model…", footer: `Selecting ${choice.model.id}…` },
        ""
      )
    }
    this.#requestInput("")

    const apply = async () => {
      try {
        await session.setModel(choice.model)
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.#closeModelPicker({ type: "error", message: errorMessage(cause) })
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#closeModelPicker({ type: "status", message: `Model: ${choice.model.id}` })
    }
    void apply()
  }

  #closeModelPicker(feedback: PromptFeedback): void {
    if (this.#disposed) return
    this.picker.close()
    this.$state.set({ ...this.$state.get(), feedback, workflow: { type: "idle" } })
    this.#requestInput("")
  }

  #openLogin(provider: string, parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const methods = session.authenticationMethods()
    if (methods.length === 0) {
      this.#showError("No providers support interactive login")
      return
    }

    const operationId = ++this.#nextOperationId
    const normalized = provider.trim().toLowerCase()
    const exact = normalized ? methods.filter(method => method.providerId.toLowerCase() === normalized) : []
    if (exact.length === 1) {
      this.#startAuthentication(session, exact[0]!)
      return
    }
    if (exact.length > 1) {
      const frame = authMethodFrame(exact)
      if (parentFilter === undefined) this.picker.open(frame)
      else this.picker.push(frame, parentFilter)
      this.$state.set({
        ...this.$state.get(),
        feedback: { type: "none" },
        workflow: { type: "choosing_auth_method", operationId, session, methods: exact }
      })
      this.#requestInput("")
      return
    }

    const frame = authProviderFrame(methods)
    if (parentFilter === undefined) this.picker.open(frame)
    else this.picker.push(frame, parentFilter)
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "choosing_auth_provider", operationId, session, methods }
    })
    this.#requestInput(provider)
  }

  #startAuthentication(session: AgentSession, method: AuthenticationMethod): void {
    if (this.#interactive.getSession() !== session) return
    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      authCeremony: { providerName: method.providerName, methodName: method.name, status: `Starting ${method.name}…` },
      workflow: { type: "authenticating", operationId, session, providerId: method.providerId }
    })
    this.#requestInput("")

    const prompt = (authPrompt: AuthenticationPrompt): Promise<string> => {
      if (!this.#accepts(operationId, session)) return Promise.reject(new Error("Authentication cancelled"))
      return new Promise((resolve, reject) => {
        const onAbort = () => {
          if (this.#pendingAuthPrompt?.operationId !== operationId) return
          this.#pendingAuthPrompt = undefined
          this.picker.close()
          const state = this.$state.get()
          this.$state.set({
            ...state,
            authCeremony: clearCeremonyPrompt(state.authCeremony),
            workflow: { type: "authenticating", operationId, session, providerId: method.providerId }
          })
          this.#requestInput("")
          reject(new Error("Authentication prompt cancelled"))
        }
        authPrompt.signal?.addEventListener("abort", onAbort, { once: true })
        this.#pendingAuthPrompt = {
          operationId,
          resolve,
          reject,
          cleanup: () => authPrompt.signal?.removeEventListener("abort", onAbort)
        }

        const state = this.$state.get()
        const ceremony = state.authCeremony ?? { providerName: method.providerName, methodName: method.name }
        if (authPrompt.type === "select") {
          this.picker.open(authOptionFrame(authPrompt.options))
          this.$state.set({
            ...state,
            authCeremony: withCeremonyStatus(clearCeremonyPrompt(ceremony) ?? ceremony, authPrompt.message),
            workflow: {
              type: "choosing_auth_option",
              operationId,
              session,
              providerId: method.providerId,
              options: authPrompt.options
            }
          })
        } else {
          this.$state.set({
            ...state,
            authCeremony: withCeremonyPrompt(clearCeremonyStartingStatus(ceremony), {
              type: authPrompt.type,
              message: authPrompt.message,
              ...(authPrompt.placeholder ? { placeholder: authPrompt.placeholder } : {})
            }),
            workflow: {
              type: "auth_prompt",
              operationId,
              session,
              providerId: method.providerId,
              promptType: authPrompt.type
            }
          })
        }
        this.#requestInput("")
      })
    }

    const authenticate = async () => {
      try {
        await session.login(method.providerId, method.type, {
          prompt,
          notify: event => {
            if (!this.#accepts(operationId, session)) return
            const state = this.$state.get()
            const ceremony = state.authCeremony ?? { providerName: method.providerName, methodName: method.name }
            this.$state.set({
              ...state,
              authCeremony: applyAuthenticationEvent(ceremony, event, ++this.#nextBrowserRequestId)
            })
          }
        })
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.#finishAuthentication({ type: "error", message: errorMessage(cause) })
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#finishAuthentication({ type: "status", message: `Logged in to ${method.providerName}` })
    }
    void authenticate()
  }

  #submitAuthenticationPrompt(text: string, workflow: Extract<PromptWorkflow, { type: "auth_prompt" }>): boolean {
    if (!text || this.#pendingAuthPrompt?.operationId !== workflow.operationId) return false
    const pending = this.#pendingAuthPrompt
    pending.cleanup()
    this.#pendingAuthPrompt = undefined
    const state = this.$state.get()
    this.$state.set({
      ...state,
      authCeremony: clearCeremonyPrompt(state.authCeremony),
      workflow: {
        type: "authenticating",
        operationId: workflow.operationId,
        session: workflow.session,
        providerId: workflow.providerId
      }
    })
    this.#requestInput("")
    pending.resolve(text)
    return true
  }

  #cancelAuthentication(): boolean {
    const workflow = this.$state.get().workflow
    if (
      workflow.type !== "authenticating" &&
      workflow.type !== "auth_prompt" &&
      workflow.type !== "choosing_auth_option"
    ) {
      return false
    }

    this.#pendingAuthPrompt?.cleanup()
    this.#pendingAuthPrompt?.reject(new Error("Authentication cancelled"))
    this.#pendingAuthPrompt = undefined
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      authCeremony: undefined,
      workflow: { type: "idle" }
    })
    this.#requestInput("")
    try {
      void workflow.session.abort().catch(cause => this.#showError(cause))
    } catch (cause) {
      this.#showError(cause)
    }
    return true
  }

  #cancelCompaction(): boolean {
    const workflow = this.$state.get().workflow
    if (workflow.type !== "compacting") return false
    if (this.#cancelledCompactionOperationId === workflow.operationId) return true
    this.#cancelledCompactionOperationId = workflow.operationId
    try {
      const settled = workflow.session.abort()
      this.$state.set({ ...this.$state.get() })
      void settled.catch(() => {})
    } catch {
      // Session disposal already owns the stale operation.
    }
    return true
  }

  #cancelSessionReplacement(): boolean {
    const workflow = this.$state.get().workflow
    if (workflow.type === "cancelling_session") return true
    if (
      workflow.type !== "starting_session" &&
      workflow.type !== "resuming_session" &&
      workflow.type !== "saving_project_trust"
    ) {
      return false
    }
    const cancellation = this.#sessionActions?.cancelReplacement()
    if (!cancellation || cancellation.type !== "cancelled") return true

    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: "Cancelling session change…" },
      workflow: { type: "cancelling_session", operationId, session: workflow.session }
    })
    this.#requestInput("")
    const settleCancellation = async () => {
      try {
        await cancellation.settled
      } catch (cause) {
        if (this.#accepts(operationId, workflow.session)) this.#showError(cause)
        return
      }
      if (!this.#accepts(operationId, workflow.session)) return
      this.$state.set({ ...this.$state.get(), feedback: { type: "none" }, workflow: { type: "idle" } })
    }
    void settleCancellation()
    return true
  }

  #finishAuthentication(feedback: PromptFeedback): void {
    if (this.#disposed) return
    this.#pendingAuthPrompt?.cleanup()
    this.#pendingAuthPrompt = undefined
    this.picker.close()
    this.$state.set({ ...this.$state.get(), feedback, authCeremony: undefined, workflow: { type: "idle" } })
    this.#requestInput("")
  }

  #logout(): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: "Loading stored credentials…" },
      workflow: { type: "loading_logout", operationId, session }
    })
    this.#requestInput("")

    const load = async () => {
      let stored: readonly StoredCredential[]
      try {
        stored = await session.storedCredentials()
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.#finishAuthentication({ type: "error", message: errorMessage(cause) })
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      if (stored.length === 0) {
        this.#finishAuthentication({ type: "status", message: "No stored credentials to remove" })
        return
      }
      if (stored.length === 1) {
        this.#logoutProvider(operationId, session, stored[0]!.providerId)
        return
      }
      this.picker.open(logoutFrame(stored))
      this.$state.set({
        ...this.$state.get(),
        feedback: { type: "none" },
        workflow: { type: "choosing_logout", operationId, session, credentials: stored }
      })
    }
    void load()
  }

  #logoutProvider(operationId: number, session: AgentSession, providerId: string): void {
    if (!this.#accepts(operationId, session)) return
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "status", message: `Removing stored credentials for ${providerId}…` },
      workflow: { type: "logging_out", operationId, session, providerId }
    })
    this.#requestInput("")

    const apply = async () => {
      try {
        await session.logout(providerId)
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.#finishAuthentication({ type: "error", message: errorMessage(cause) })
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#finishAuthentication({
        type: "status",
        message: `Logged out of ${providerId}; environment and external configuration remain available`
      })
    }
    void apply()
  }

  #openCodexSettings(parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    const frame = codexSettingsFrame(session)
    if (parentFilter === undefined) this.picker.open(frame)
    else this.picker.push(frame, parentFilter)
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "choosing_codex_setting", operationId, session }
    })
    this.#requestInput("")
  }

  #openSettings(parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    const frame = settingsScopeFrame()
    if (parentFilter === undefined) this.picker.open(frame)
    else this.picker.push(frame, parentFilter)
    this.$state.set({
      ...this.$state.get(),
      feedback: { type: "none" },
      workflow: { type: "choosing_settings_scope", operationId, session }
    })
    this.#requestInput("")
  }

  #applySetting(workflow: Extract<PromptWorkflow, { type: "choosing_setting_value" }>, value: string): boolean {
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    let mutation: { readonly requested: EditableSettingValue; readonly effective: EditableSettingValue }
    try {
      switch (workflow.setting) {
        case "defaultThinkingLevel":
          if (!isThinkingLevel(value)) return false
          mutation = workflow.session.setThinkingLevel(value, workflow.scope)
          break
        case "steeringMode":
          if (!isQueueMode(value)) return false
          mutation = workflow.session.setSteeringMode(value, workflow.scope)
          break
        case "followUpMode":
          if (!isQueueMode(value)) return false
          mutation = workflow.session.setFollowUpMode(value, workflow.scope)
          break
        case "compactionEnabled":
          if (value !== "true" && value !== "false") return false
          mutation = workflow.session.setCompactionEnabled(value === "true", workflow.scope)
          break
        case "retryEnabled":
          if (value !== "true" && value !== "false") return false
          mutation = workflow.session.setRetryEnabled(value === "true", workflow.scope)
          break
        default:
          return assertNever(workflow.setting)
      }
    } catch (cause) {
      this.#showError(cause)
      return false
    }
    if (!this.#accepts(workflow.operationId, workflow.session)) return false

    this.picker.close()
    const shadowed = mutation.requested !== mutation.effective
    this.$state.set({
      ...this.$state.get(),
      feedback: {
        type: "status",
        message: shadowed
          ? `${settingLabel(workflow.setting)} saved as ${settingValueLabel(mutation.requested)}; project override keeps ${settingValueLabel(mutation.effective)} effective`
          : `${settingLabel(workflow.setting)}: ${settingValueLabel(mutation.effective)} (${workflow.scope})`
      },
      workflow: { type: "idle" }
    })
    this.#requestInput("")
    return true
  }

  #accepts(operationId: number, session: AgentSession): boolean {
    if (this.#disposed || this.#interactive.getSession() !== session) return false
    const workflow = this.$state.get().workflow
    return workflow.type !== "idle" && workflow.operationId === operationId && workflow.session === session
  }

  #finishClipboardRead(reading: Extract<ClipboardReadState, { type: "reading" }>): boolean {
    const accepted =
      !this.#disposed && this.#clipboardRead === reading && this.#interactive.getSession() === reading.session
    if (this.#clipboardRead === reading) this.#clipboardRead = { type: "idle" }
    return accepted
  }

  #cancelClipboardRead(): void {
    const reading = this.#clipboardRead
    if (reading.type === "idle") return
    this.#clipboardRead = { type: "idle" }
    reading.controller.abort()
  }

  #mergeQueue(queue: QueuedInputs, currentText: string, showStatus: boolean): string {
    const entries = [...queue.steering, ...queue.followUp]
    const texts = entries.map(entry => entry.text)
    const images = entries.flatMap(entry => entry.images)
    const state = this.$state.get()
    this.$state.set({
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
    return [...texts, currentText].filter(value => value.length > 0).join("\n\n")
  }

  #completionContextChanged(text: string, input: FileCompletionInput, allowCommandOpen: boolean): void {
    const workflow = this.$state.get().workflow
    if (workflow.type === "auth_prompt" || workflow.type === "authenticating") {
      this.#fileCompletion.close()
      return
    }
    if (workflow.type !== "idle") {
      this.#fileCompletion.close()
      if (allowCommandOpen) this.picker.queryChanged(text)
      return
    }

    const suggestions = this.#slash.suggestions(text, input.cursorOffset)
    const presentation = this.picker.presentation(text)
    if (suggestions.length > 0) {
      this.#fileCompletion.close()
      if (!allowCommandOpen && presentation?.frame.id !== promptPickerFrameIds.commands) return
      const frame = commandFrame(suggestions)
      if (presentation?.frame.id === promptPickerFrameIds.commands) this.picker.replaceTop(frame, text)
      else this.picker.open(frame)
      return
    }
    if (presentation?.frame.id === promptPickerFrameIds.commands) this.picker.close()
    this.#fileCompletion.update(this.#interactive.getSession(), this.#draftRevision, input)
  }

  #requestInput(text: string, cursorOffset = promptTextWidth(text)): void {
    this.#fileCompletion.close()
    const state = this.$state.get()
    this.$state.set({
      ...state,
      inputEdit: { type: "replace", revision: state.inputEdit.revision + 1, text, cursorOffset }
    })
  }

  #requestRange(edit: FileCompletionRangeEdit): void {
    const state = this.$state.get()
    this.$state.set({ ...state, inputEdit: { type: "range", revision: state.inputEdit.revision + 1, ...edit } })
  }

  #setIdle(): void {
    this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
  }

  #showError(cause: unknown): void {
    if (this.#disposed) return
    this.$state.set({ ...this.$state.get(), feedback: { type: "error", message: errorMessage(cause) } })
  }
}

function imageMarkerFeedback(action: "Removed" | "Restored", count: number): PromptFeedback {
  return { type: "status", message: `${action} ${count} attached image${count === 1 ? "" : "s"}` }
}

function applyAuthenticationEvent(ceremony: AuthCeremony, event: AuthenticationEvent, requestId: number): AuthCeremony {
  switch (event.type) {
    case "auth_url":
      return {
        ...clearCeremonyTransientStatus(ceremony),
        url: { href: event.url, requestId, ...(event.instructions ? { instructions: event.instructions } : {}) }
      }
    case "device_code": {
      const waiting =
        ceremony.status && !isTransientCeremonyStatus(ceremony.status) ? ceremony.status : "Waiting for authentication…"
      return {
        ...withCeremonyStatus(ceremony, waiting),
        device: { userCode: event.userCode, verificationUri: event.verificationUri, requestId }
      }
    }
    case "progress":
      return withCeremonyStatus(ceremony, event.message)
    case "info":
      return {
        ...clearCeremonyTransientStatus(ceremony),
        info: { message: event.message, ...(event.links ? { links: event.links } : {}) }
      }
    default:
      return assertNever(event)
  }
}

function clearCeremonyPrompt(ceremony: AuthCeremony | undefined): AuthCeremony | undefined {
  if (!ceremony?.prompt) return ceremony
  const { prompt: _prompt, ...rest } = ceremony
  return rest
}

function clearCeremonyChoice(ceremony: AuthCeremony | undefined): AuthCeremony | undefined {
  if (!ceremony) return undefined
  const { prompt: _prompt, status: _status, ...rest } = ceremony
  return rest
}

function clearCeremonyStartingStatus(ceremony: AuthCeremony): AuthCeremony {
  if (!ceremony.status?.startsWith("Starting ")) return ceremony
  const { status: _status, ...rest } = ceremony
  return rest
}

function clearCeremonyTransientStatus(ceremony: AuthCeremony): AuthCeremony {
  if (!ceremony.status || !isTransientCeremonyStatus(ceremony.status)) return ceremony
  const { status: _status, ...rest } = ceremony
  return rest
}

function withCeremonyStatus(ceremony: AuthCeremony, status: string): AuthCeremony {
  return { ...ceremony, status }
}

function withCeremonyPrompt(ceremony: AuthCeremony, prompt: NonNullable<AuthCeremony["prompt"]>): AuthCeremony {
  return { ...ceremony, prompt }
}

function isTransientCeremonyStatus(status: string): boolean {
  return status.startsWith("Starting ") || status.startsWith("Select ") || status.startsWith("Choose ")
}

function settingsScope(value: string): SettingsScope | undefined {
  return value === "global" || value === "project" ? value : undefined
}

function editableSetting(value: string): EditableSetting | undefined {
  return value === "defaultThinkingLevel" ||
    value === "steeringMode" ||
    value === "followUpMode" ||
    value === "compactionEnabled" ||
    value === "retryEnabled"
    ? value
    : undefined
}

function isQueueMode(value: string): value is QueueMode {
  return value === "all" || value === "one-at-a-time"
}

function isThinkingLevel(value: string): value is ThinkingLevel {
  return (
    value === "off" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh" ||
    value === "max"
  )
}

function settingValueLabel(value: EditableSettingValue): string {
  return typeof value === "boolean" ? (value ? "On" : "Off") : value
}

function formatTokens(tokens: number): string {
  if (tokens < 1_000) return String(tokens)
  if (tokens < 1_000_000) return `${Math.round(tokens / 1_000)}k`
  return `${(tokens / 1_000_000).toFixed(1).replace(/\.0$/, "")}m`
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

function reloadNoticeOutcome(result: SessionReloadResult): ReloadNoticeOutcome {
  const outcome = result.extensions?.outcome
  if (outcome === "failed") return "error"
  if (outcome === "retained" || outcome === "superseded") return "warning"
  if (firstReloadDiagnostic(result)) return "warning"
  return "success"
}

function reloadStatusMessage(result: SessionReloadResult): string {
  const outcome = result.extensions?.outcome
  const base =
    outcome === "replaced"
      ? "Reloaded settings, resources, and extensions"
      : outcome === "retained"
        ? "Reloaded settings and resources; kept the previous extension generation"
        : outcome === "disabled"
          ? "Reloaded settings and resources; extensions disabled"
          : outcome === "failed"
            ? "Reload failed after retiring the previous extension generation"
            : outcome === "superseded"
              ? "Reload was superseded"
              : "Reloaded settings and resources"
  const detail = firstReloadDiagnostic(result)
  return detail ? `${base}: ${detail}` : base
}

function firstReloadDiagnostic(result: SessionReloadResult): string | undefined {
  const remaining = reloadDiagnosticRemaining(result)
  const extension =
    result.extensions?.diagnostics.find(diagnostic => diagnostic.severity === "error") ??
    result.extensions?.diagnostics[0]
  if (extension) {
    return formatReloadDiagnostic(extension.path ?? extension.extensionId, extension.message, remaining)
  }

  const settings = result.settingsErrors[0]
  if (settings) {
    return formatReloadDiagnostic(settings.path, settings.error.message, remaining)
  }

  const resource = result.resources.diagnostics[0]
  if (resource) {
    return formatReloadDiagnostic(resourceDiagnosticPath(resource), resourceDiagnosticMessage(resource), remaining)
  }

  const omitted = result.extensions?.omittedDiagnostics ?? 0
  if (omitted > 0) return `${omitted} omitted extension diagnostic${omitted === 1 ? "" : "s"}`
  return undefined
}

/** Count of diagnostics not shown once the first one is displayed. Includes omitted extension diagnostics. */
function reloadDiagnosticRemaining(result: SessionReloadResult): number {
  const total =
    result.settingsErrors.length +
    result.resources.diagnostics.length +
    (result.extensions?.diagnostics.length ?? 0) +
    (result.extensions?.omittedDiagnostics ?? 0)
  return Math.max(0, total - 1)
}

function formatReloadDiagnostic(source: string | undefined, message: string, remaining: number): string {
  const body = source ? `${source}: ${message}` : message
  return remaining > 0 ? `${body} (+${remaining} more)` : body
}

function resourceDiagnosticPath(
  diagnostic: SessionReloadResult["resources"]["diagnostics"][number]
): string | undefined {
  switch (diagnostic.type) {
    case "warning":
      return diagnostic.path
    case "collision":
      return diagnostic.loserPath
    case "limit":
      return diagnostic.path
    default:
      return assertNever(diagnostic)
  }
}

function resourceDiagnosticMessage(diagnostic: SessionReloadResult["resources"]["diagnostics"][number]): string {
  switch (diagnostic.type) {
    case "warning":
      return diagnostic.message
    case "collision":
      return `${diagnostic.resource} "${diagnostic.name}" collides with ${diagnostic.winnerPath}`
    case "limit":
      return diagnostic.message
    default:
      return assertNever(diagnostic)
  }
}

function assertNever(value: never): never {
  throw new Error(`Unexpected closed value: ${String(value)}`)
}

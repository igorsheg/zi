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
import type { BuiltInNoticeActions, ReloadNoticeOutcome } from "../built-in-notifications.js"
import {
  detectClipboardImageMimeType,
  maxClipboardImageBytes,
  maxPastedTextBytes,
  type ClipboardContent,
  type ClipboardReader
} from "../clipboard.js"
import type { InteractiveStore } from "../interactive-store.js"
import type { InteractiveCommand, SlashController } from "../slash-controller.js"
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
  agentFrame,
  settingsFrame,
  settingsScopeFrame,
  settingValuesFrame
} from "./frames.js"
import { configuredModelChoices, exactModelChoice } from "./model-choices.js"
import { createPickerStack, type PickerFrame, type PickerPresentation, type PickerStack } from "./picker.js"
import {
  initialPromptState,
  type AuthCeremony,
  type EditableSetting,
  type EditableSettingValue,
  type PickerWorkflow,
  type PromptState,
  type PromptWorkflow
} from "./state.js"

export type PromptSubmissionIntent = PendingInputDelivery | "interrupt"

export interface PromptStore {
  readonly $state: ReadableAtom<PromptState>
  readonly picker: PickerStack
  submit(text: string, delivery: PromptSubmissionIntent): boolean
  draftChanged(text: string, input: FileCompletionInput): void
  cursorChanged(text: string, input: FileCompletionInput): void
  handlePickerTab(text: string, input: FileCompletionInput): boolean
  activatePicker(text: string, input: FileCompletionInput): boolean
  movePicker(filter: string, direction: -1 | 1): void
  backPicker(): boolean
  requestProjectTrust(cwd: string): void
  restoreQueuedInputs(currentText: string): string
  abortAndRestoreQueuedInputs(currentText: string): string
  pasteClipboard(): Promise<string | undefined>
  attachImage(image: Extract<ClipboardContent, { type: "image" }>): boolean
  imageMarkersChanged(images: readonly ImageContent[]): void
  clear(): boolean
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

type ModelRefreshState =
  | { readonly type: "idle" }
  | {
      readonly type: "refreshing"
      readonly operationId: number
      readonly session: AgentSession
      readonly controller: AbortController
    }

export const maxPromptClipboardImages = 8
export const maxPromptClipboardEncodedBytes = 8 * 1024 * 1024

const unavailableClipboard: ClipboardReader = { read: async () => undefined }
const unavailableMessageCopy: PromptMessageCopy = { copyLastAssistant() {} }
const unavailableNotices: BuiltInNoticeActions = {
  promptProgress() {},
  promptInfo() {},
  promptWarning() {},
  promptError() {},
  clearPrompt() {},
  backgroundTaskCapacityExceeded() {},
  reloadCompleted() {},
  reloadFailed() {}
}

export interface PromptMessageCopy {
  copyLastAssistant(session: Pick<AgentSession, "getLastAssistantText">): void
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
  notices: BuiltInNoticeActions = unavailableNotices,
  messageCopy: PromptMessageCopy = unavailableMessageCopy
): PromptStore {
  return new PromptController(interactive, slash, sessionActions, clipboard, notices, messageCopy)
}

class PromptController implements PromptStore {
  readonly $state = atom(initialPromptState)
  readonly picker = createPickerStack()

  readonly #interactive: InteractiveStore
  readonly #slash: SlashController
  readonly #sessionActions: PromptSessionActions | undefined
  readonly #clipboard: ClipboardReader
  readonly #notices: BuiltInNoticeActions
  readonly #messageCopy: PromptMessageCopy
  readonly #fileCompletion: FileCompletionController
  #clipboardRead: ClipboardReadState = { type: "idle" }
  #modelRefresh: ModelRefreshState = { type: "idle" }
  #draftRevision = 0
  #disposed = false
  #nextOperationId = 0
  #nextBrowserRequestId = 0
  #pendingAuthPrompt: PendingAuthPrompt | undefined
  #cancelledCompactionOperationId: number | undefined
  #cancelledExtensionCommandOperationId: number | undefined

  constructor(
    interactive: InteractiveStore,
    slash: SlashController,
    sessionActions: PromptSessionActions | undefined,
    clipboard: ClipboardReader,
    notices: BuiltInNoticeActions,
    messageCopy: PromptMessageCopy
  ) {
    this.#interactive = interactive
    this.#slash = slash
    this.#sessionActions = sessionActions
    this.#clipboard = clipboard
    this.#notices = notices
    this.#messageCopy = messageCopy
    this.#fileCompletion = new FileCompletionController(this.picker, edit => this.#requestRange(edit))
  }

  submit(text: string, delivery: PromptSubmissionIntent): boolean {
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
        this.#warn("The current model does not accept image input")
        return false
      }
      const settled =
        delivery === "interrupt"
          ? this.#interactive.interruptAndSubmit({ text: trimmed, images: state.images })
          : this.#interactive.submit({ text: trimmed, images: state.images, delivery })
      this.#cancelClipboardRead()
      this.picker.close()
      this.$state.set({
        ...initialPromptState,
        inputEdit: { type: "replace", revision: state.inputEdit.revision + 1, text: "", cursorOffset: 0 }
      })
      this.#notices.clearPrompt()
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

  handlePickerTab(text: string, input: FileCompletionInput): boolean {
    const presentation = this.picker.presentation(text)
    if (!presentation || presentation.frame.disabled) return false
    if (presentation.workflow?.type === "choosing_agent") {
      return this.#toggleAgentScope(presentation.workflow)
    }
    if (!presentation.selectedId) return false
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

    // The presented frame carries its choosing workflow; frames without one
    // are transient (completion popups, loading and progress rows) and admit
    // interaction only while the prompt is idle.
    const workflow = presentation.workflow
    if (!workflow) {
      if (this.$state.get().workflow.type !== "idle") return false
      if (presentation.frame.id === promptPickerFrameIds.commands) {
        return this.#activateCommand(presentation, text, input.cursorOffset)
      }
      if (presentation.frame.id === promptPickerFrameIds.files) {
        return this.#fileCompletion.complete(presentation.selectedId, input)
      }
      return false
    }

    switch (workflow.type) {
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
      case "choosing_agent":
        return false
      case "choosing_project_trust":
        return this.#activateProjectTrust(workflow, presentation)
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
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.clearPrompt()
      this.#requestInput("")
      return true
    }

    this.#cancelModelRefresh()
    const result = this.picker.back()
    if (result.type === "revealed" && result.workflow) {
      // The revealed frame restores its own choosing workflow; transient
      // frames (completion popups, loading rows) leave the prompt idle.
      this.$state.set({ ...this.$state.get(), workflow: result.workflow })
    } else {
      this.#setIdle()
    }
    this.#requestInput(result.type === "revealed" ? result.filter : "")
    return true
  }

  requestProjectTrust(cwd: string): void {
    if (this.#disposed || this.$state.get().workflow.type !== "idle") return
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.#admitChoosing(projectTrustFrame(cwd), { type: "choosing_project_trust", operationId, session, cwd })
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
    if (
      this.#cancelAuthentication() ||
      this.#cancelCompaction() ||
      this.#cancelExtensionCommand() ||
      this.#cancelSessionReplacement()
    ) {
      return ""
    }
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
      this.#warn("Clipboard is empty or unavailable")
      return undefined
    }
    if (content.type === "image") {
      this.attachImage(content)
      return undefined
    }
    if (Buffer.byteLength(content.text) > maxPastedTextBytes) {
      this.#error("Clipboard text exceeds the 1 MiB paste limit")
      return undefined
    }
    return content.text
  }

  attachImage(image: Extract<ClipboardContent, { type: "image" }>): boolean {
    if (this.#disposed) return false
    const state = this.$state.get()
    if (state.workflow.type !== "idle") {
      this.#warn("Images cannot be attached during the active prompt workflow")
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
      this.#warn("The current model does not accept image input")
      return false
    }
    if (image.bytes.byteLength === 0 || image.bytes.byteLength > maxClipboardImageBytes) {
      this.#error("Clipboard image exceeds the 4.5 MiB encoded image limit")
      return false
    }

    const mimeType = detectClipboardImageMimeType(image.bytes)
    if (!mimeType) {
      this.#warn("Clipboard image must be PNG, JPEG, WebP, or GIF")
      return false
    }
    if (state.images.length >= maxPromptClipboardImages) {
      this.#error(`A prompt cannot contain more than ${maxPromptClipboardImages} pasted images`)
      return false
    }

    const data = Buffer.from(image.bytes).toString("base64")
    const retainedBytes = state.images.reduce((bytes, entry) => bytes + Buffer.byteLength(entry.data), 0)
    if (retainedBytes + Buffer.byteLength(data) > maxPromptClipboardEncodedBytes) {
      this.#error("Pasted images exceed the 8 MiB prompt attachment limit")
      return false
    }

    const images = [...state.images, { type: "image" as const, data, mimeType }]
    this.$state.set({ ...state, images })
    this.#notices.promptInfo(`Attached image ${images.length} (${mimeType.slice("image/".length).toUpperCase()})`)
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

    this.$state.set({ ...state, images: [...images] })
    if (images.length < state.images.length) {
      this.#notices.promptInfo(imageMarkerNotice("Removed", state.images.length - images.length))
    } else if (images.length > state.images.length) {
      this.#notices.promptInfo(imageMarkerNotice("Restored", images.length - state.images.length))
    }
  }

  #warn(message: string): void {
    if (!this.#disposed) this.#notices.promptWarning(message)
  }

  #error(message: string): void {
    if (!this.#disposed) this.#notices.promptError(message)
  }

  clear(): boolean {
    this.#cancelClipboardRead()
    this.#cancelModelRefresh()
    if (
      this.#cancelAuthentication() ||
      this.#cancelCompaction() ||
      this.#cancelExtensionCommand() ||
      this.#cancelSessionReplacement()
    ) {
      return false
    }
    this.#fileCompletion.close()
    this.picker.close()
    const state = this.$state.get()
    this.$state.set({ ...initialPromptState, inputEdit: { type: "clear", revision: state.inputEdit.revision + 1 } })
    this.#notices.clearPrompt()
    return true
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#cancelClipboardRead()
    this.#cancelModelRefresh()
    this.#cancelAuthentication()
    this.#cancelCompaction()
    this.#cancelExtensionCommand()
    this.#cancelSessionReplacement()
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
    if (presentation.selectedId !== "fast-mode") return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    this.#admitChoosing(
      codexFastModeValuesFrame(workflow.session),
      { type: "choosing_codex_fast_mode", operationId: workflow.operationId, session: workflow.session },
      text
    )
    this.#requestInput("")
    return true
  }

  #activateCodexFastMode(
    workflow: Extract<PromptWorkflow, { type: "choosing_codex_fast_mode" }>,
    presentation: PickerPresentation
  ): boolean {
    if (!presentation.selectedId) return false
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

    this.#notices.promptInfo(
      mutation.requested === mutation.effective
        ? `Codex Fast mode: ${settingValueLabel(mutation.effective)}`
        : `Codex Fast mode saved as ${settingValueLabel(mutation.requested)}; project settings keep ${settingValueLabel(mutation.effective)} effective`
    )
    this.#returnToParentChooser()
    return true
  }

  #activateSettingsScope(
    workflow: Extract<PromptWorkflow, { type: "choosing_settings_scope" }>,
    presentation: PickerPresentation,
    text: string
  ): boolean {
    if (!presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const scope = settingsScope(presentation.selectedId)
    if (!scope) return false
    this.#admitChoosing(
      settingsFrame(workflow.session, scope),
      { type: "choosing_setting", operationId: workflow.operationId, session: workflow.session, scope },
      text
    )
    this.#requestInput("")
    return true
  }

  #activateSetting(
    workflow: Extract<PromptWorkflow, { type: "choosing_setting" }>,
    presentation: PickerPresentation,
    text: string
  ): boolean {
    if (!presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const setting = editableSetting(presentation.selectedId)
    if (!setting) return false
    this.#admitChoosing(
      settingValuesFrame(workflow.session, workflow.scope, setting),
      {
        type: "choosing_setting_value",
        operationId: workflow.operationId,
        session: workflow.session,
        scope: workflow.scope,
        setting
      },
      text
    )
    this.#requestInput("")
    return true
  }

  #activateSettingValue(
    workflow: Extract<PromptWorkflow, { type: "choosing_setting_value" }>,
    presentation: PickerPresentation
  ): boolean {
    if (!presentation.selectedId) return false
    return this.#applySetting(workflow, presentation.selectedId)
  }

  #activateModel(
    workflow: Extract<PromptWorkflow, { type: "choosing_model" }>,
    presentation: PickerPresentation
  ): boolean {
    if (!presentation.selectedId) return false
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
    if (!presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const methods = workflow.methods.filter(method => method.providerId === presentation.selectedId)
    if (methods.length === 1) {
      this.#startAuthentication(workflow.session, methods[0]!)
      return true
    }
    if (methods.length === 0) return false
    this.#admitChoosing(
      authMethodFrame(methods),
      { type: "choosing_auth_method", operationId: workflow.operationId, session: workflow.session, methods },
      text
    )
    this.#requestInput("")
    return true
  }

  #activateAuthMethod(
    workflow: Extract<PromptWorkflow, { type: "choosing_auth_method" }>,
    presentation: PickerPresentation
  ): boolean {
    if (!presentation.selectedId) return false
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
    if (!presentation.selectedId) return false
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
    if (!presentation.selectedId) return false
    const credential = workflow.credentials.find(candidate => candidate.providerId === presentation.selectedId)
    if (!credential) return false
    this.#logoutProvider(workflow.operationId, workflow.session, credential.providerId)
    return true
  }

  #activateSession(
    workflow: Extract<PromptWorkflow, { type: "choosing_session" }>,
    presentation: PickerPresentation
  ): boolean {
    if (!presentation.selectedId) return false
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const selected = workflow.sessions.find(session => session.path === presentation.selectedId)
    if (!selected) return false
    if (selected.path === workflow.session.sessionManager.file) {
      this.picker.close()
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.promptInfo("Session already active")
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
      workflow: { type: "resuming_session", operationId: workflow.operationId, session: workflow.session }
    })
    this.#notices.clearPrompt()
    this.picker.replaceTop({ ...presentation.frame, footer: "Resuming session…" }, "")
    this.#requestInput("")

    const resume = async () => {
      try {
        await actions.resumeSession(selected.path)
      } catch (cause) {
        if (!this.#accepts(workflow.operationId, workflow.session)) return
        this.#replaceChoosing(sessionFrame(workflow.sessions, workflow.session.sessionManager.file), "", workflow)
        this.#notices.promptError(errorMessage(cause))
        return
      }
      if (!this.#accepts(workflow.operationId, workflow.session)) return
      this.picker.close()
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.clearPrompt()
      this.#requestInput("")
    }
    void resume()
    return true
  }

  #toggleAgentScope(workflow: Extract<PromptWorkflow, { type: "choosing_agent" }>): boolean {
    if (!this.#accepts(workflow.operationId, workflow.session)) return false
    const next: Extract<PromptWorkflow, { type: "choosing_agent" }> = {
      ...workflow,
      scope: workflow.scope === "running" ? "all" : "running"
    }
    this.picker.replaceTopRetainingQuery(agentFrame(next.snapshots, next.scope), next)
    this.$state.set({ ...this.$state.get(), workflow: next })
    return true
  }

  #activateProjectTrust(
    workflow: Extract<PromptWorkflow, { type: "choosing_project_trust" }>,
    presentation: PickerPresentation
  ): boolean {
    if (!presentation.selectedId) return false
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
      workflow: {
        type: "saving_project_trust",
        operationId: workflow.operationId,
        session: workflow.session,
        cwd: workflow.cwd,
        selection: selected.selection
      }
    })
    this.picker.replaceTop(projectTrustFrame(workflow.cwd, selected.id, true), "")
    this.#notices.clearPrompt()
    this.#requestInput("")

    const apply = async () => {
      try {
        await actions.decideProjectTrust(selected.selection)
      } catch (cause) {
        if (!this.#accepts(workflow.operationId, workflow.session)) return
        this.#replaceChoosing(projectTrustFrame(workflow.cwd, selected.id), "", workflow)
        this.#notices.promptError(errorMessage(cause))
        return
      }
      if (!this.#accepts(workflow.operationId, workflow.session)) return
      this.picker.close()
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.clearPrompt()
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
      case "copy":
        this.picker.close()
        this.#messageCopy.copyLastAssistant(this.#interactive.getSession())
        this.#requestInput("")
        return true
      case "extension_command":
        this.#runExtensionCommand(command.name, command.arguments)
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
      case "agents":
        this.#openAgents(parentFilter)
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
    this.$state.set({ ...this.$state.get(), workflow: { type: "compacting", operationId, session } })
    this.#notices.clearPrompt()
    this.#requestInput("")

    const compact = async () => {
      try {
        const result = await session.compact(instructions || undefined)
        if (!this.#accepts(operationId, session)) return
        this.#cancelledCompactionOperationId = undefined
        this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
        this.#notices.promptInfo(
          `Compacted ${formatTokens(result.tokensBefore)} → ~${formatTokens(result.estimatedTokensAfter)} context tokens.`
        )
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        const cancelled = this.#cancelledCompactionOperationId === operationId
        this.#cancelledCompactionOperationId = undefined
        this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
        if (cancelled) this.#notices.clearPrompt()
        else this.#notices.promptError(errorMessage(cause))
      }
    }
    void compact()
  }

  #runExtensionCommand(name: string, arguments_: string): void {
    const session = this.#interactive.getSession()
    if (session.isStreaming || session.isAborting) {
      this.#warn("Wait for the current response before running a command")
      return
    }
    const operationId = ++this.#nextOperationId
    this.#cancelledExtensionCommandOperationId = undefined
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      workflow: { type: "running_extension_command", operationId, session, name }
    })
    this.#notices.promptProgress(`Running /${name}…`)
    this.#requestInput("")

    const run = async () => {
      try {
        const message = await session.invokeExtensionCommand(name, arguments_)
        if (!this.#accepts(operationId, session)) return
        this.#cancelledExtensionCommandOperationId = undefined
        this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
        if (message === undefined || message.length === 0) this.#notices.clearPrompt()
        else this.#notices.promptInfo(message)
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        const cancelled = this.#cancelledExtensionCommandOperationId === operationId
        this.#cancelledExtensionCommandOperationId = undefined
        this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
        if (cancelled) this.#notices.clearPrompt()
        else this.#notices.promptError(errorMessage(cause))
      }
    }
    void run()
  }

  #reload(): void {
    const session = this.#interactive.getSession()
    if (session.isStreaming) {
      this.#warn("Wait for the current response before reloading")
      return
    }
    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({ ...this.$state.get(), workflow: { type: "reloading", operationId, session } })
    this.#notices.promptProgress("Reloading…")
    this.#requestInput("")

    const reload = async () => {
      let result: SessionReloadResult
      try {
        result = await session.reload()
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
        this.#notices.reloadFailed(errorMessage(cause))
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#slash.invalidateCatalog()
      const outcome = reloadNoticeOutcome(result)
      const message = reloadNoticeMessage(result)
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.reloadCompleted(outcome, message)
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
    this.$state.set({ ...this.$state.get(), workflow: { type: "starting_session", operationId, session } })
    this.#notices.promptProgress("Starting new session…")
    this.#requestInput("")

    const start = async () => {
      try {
        await actions.startNewSession()
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
          this.#notices.promptError(errorMessage(cause))
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.clearPrompt()
      this.#requestInput("")
    }
    void start()
  }

  #openAgents(parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    const snapshots = session.agentSnapshots()
    this.#admitChoosing(
      agentFrame(snapshots, "running"),
      { type: "choosing_agent", operationId, session, snapshots, scope: "running" },
      parentFilter
    )
    this.#requestInput("")
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
    this.$state.set({ ...this.$state.get(), workflow: { type: "loading_sessions", operationId, session } })
    this.#notices.clearPrompt()
    this.#requestInput("")

    const load = async () => {
      let listed: SessionListResult
      try {
        listed = await actions.listSessions()
      } catch (cause) {
        if (!this.#accepts(operationId, session)) return
        const choosing: PickerWorkflow = { type: "choosing_session", operationId, session, sessions: [] }
        this.#replaceChoosing(
          sessionFrame([], session.sessionManager.file, { emptyText: errorMessage(cause) }),
          "",
          choosing
        )
        return
      }
      if (!this.#accepts(operationId, session)) return
      const choosing: PickerWorkflow = { type: "choosing_session", operationId, session, sessions: listed.sessions }
      this.#replaceChoosing(
        sessionFrame(listed.sessions, session.sessionManager.file, {
          invalid: listed.invalid,
          omitted: listed.omitted
        }),
        "",
        choosing
      )
    }
    void load()
  }

  #openModels(initialSearch: string, parentFilter?: string): void {
    this.#cancelModelRefresh()
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.$state.set({ ...this.$state.get(), workflow: { type: "loading_models", operationId, session } })
    this.#notices.clearPrompt()
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
        const choosing: PickerWorkflow = { type: "choosing_model", operationId, session, choices: [] }
        this.#replaceChoosing({ ...loading, emptyText: errorMessage(cause) }, initialSearch, choosing)
        return
      }

      if (!this.#accepts(operationId, session)) return
      const choices = configuredModelChoices(loaded, current)
      const exact = initialSearch ? exactModelChoice(initialSearch, choices) : undefined
      if (exact) {
        this.#selectModel(operationId, session, exact)
        return
      }
      const choosing: PickerWorkflow = { type: "choosing_model", operationId, session, choices }
      this.#replaceChoosing(
        modelFrame(choices, current, "No matching models", "Refreshing model catalogs…"),
        initialSearch,
        choosing
      )
      this.#startModelRefresh(operationId, session)
    }
    void load()
  }

  #startModelRefresh(operationId: number, session: AgentSession): void {
    const refresh: Extract<ModelRefreshState, { type: "refreshing" }> = {
      type: "refreshing",
      operationId,
      session,
      controller: new AbortController()
    }
    this.#modelRefresh = refresh

    const run = async () => {
      try {
        const result = await session.refreshModelChoices(refresh.controller.signal)
        const workflow = this.#finishModelRefresh(refresh)
        if (!workflow) return
        if (result.type === "complete") {
          this.#replaceRefreshedModels(workflow, result.choices, modelRefreshCompletionFooter(result.failedProviders))
        } else {
          this.#replaceRefreshedModels(
            workflow,
            workflow.choices,
            result.reason === "timeout"
              ? "Model refresh timed out; showing cached models."
              : "Model refresh cancelled; showing cached models."
          )
        }
      } catch {
        const workflow = this.#finishModelRefresh(refresh)
        if (!workflow) return
        this.#replaceRefreshedModels(
          workflow,
          workflow.choices,
          "Could not refresh model catalogs; showing cached models."
        )
      }
    }
    void run()
  }

  #finishModelRefresh(
    refresh: Extract<ModelRefreshState, { type: "refreshing" }>
  ): Extract<PromptWorkflow, { type: "choosing_model" }> | undefined {
    const workflow = this.$state.get().workflow
    const accepted =
      !this.#disposed &&
      this.#modelRefresh === refresh &&
      this.#interactive.getSession() === refresh.session &&
      workflow.type === "choosing_model" &&
      workflow.operationId === refresh.operationId &&
      workflow.session === refresh.session
    if (this.#modelRefresh === refresh) this.#modelRefresh = { type: "idle" }
    if (accepted) return workflow
    refresh.controller.abort()
    return undefined
  }

  #replaceRefreshedModels(
    workflow: Extract<PromptWorkflow, { type: "choosing_model" }>,
    loaded: readonly ModelChoice[],
    footer: string | undefined
  ): void {
    const current = workflow.session.modelState.type === "selected" ? workflow.session.modelState.model : undefined
    const choices = configuredModelChoices(loaded, current)
    const choosing: PickerWorkflow = { ...workflow, choices }
    this.picker.replaceTopRetainingQuery(modelFrame(choices, current, "No matching models", footer), choosing)
    this.$state.set({ ...this.$state.get(), workflow: choosing })
  }

  #cancelModelRefresh(): void {
    const refresh = this.#modelRefresh
    if (refresh.type === "idle") return
    this.#modelRefresh = { type: "idle" }
    refresh.controller.abort()
  }

  #selectModel(operationId: number, session: AgentSession, choice: ModelChoice): void {
    if (!this.#accepts(operationId, session)) return
    this.#cancelModelRefresh()
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
          this.picker.close()
          this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
          this.#notices.promptError(errorMessage(cause))
          this.#requestInput("")
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.picker.close()
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.promptInfo(`Model: ${choice.model.id}`)
      this.#requestInput("")
    }
    void apply()
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
      this.#admitChoosing(
        authMethodFrame(exact),
        { type: "choosing_auth_method", operationId, session, methods: exact },
        parentFilter
      )
      this.#requestInput("")
      return
    }

    this.#admitChoosing(
      authProviderFrame(methods),
      { type: "choosing_auth_provider", operationId, session, methods },
      parentFilter
    )
    this.#requestInput(provider)
  }

  #startAuthentication(session: AgentSession, method: AuthenticationMethod): void {
    if (this.#interactive.getSession() !== session) return
    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      authCeremony: { providerName: method.providerName, methodName: method.name, status: `Starting ${method.name}…` },
      workflow: { type: "authenticating", operationId, session, providerId: method.providerId }
    })
    this.#notices.clearPrompt()
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
          this.picker.open(authOptionFrame(authPrompt.options), {
            type: "choosing_auth_option",
            operationId,
            session,
            providerId: method.providerId,
            options: authPrompt.options
          })
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
          this.#finishAuthentication("error", errorMessage(cause))
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#finishAuthentication("info", `Logged in to ${method.providerName}`)
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
    this.$state.set({ ...this.$state.get(), authCeremony: undefined, workflow: { type: "idle" } })
    this.#notices.clearPrompt()
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

  #cancelExtensionCommand(): boolean {
    const workflow = this.$state.get().workflow
    if (workflow.type !== "running_extension_command") return false
    if (this.#cancelledExtensionCommandOperationId === workflow.operationId) return true
    this.#cancelledExtensionCommandOperationId = workflow.operationId
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
    if (this.#disposed) {
      void cancellation.settled.catch(() => {})
      return true
    }

    const operationId = ++this.#nextOperationId
    this.picker.close()
    this.$state.set({
      ...this.$state.get(),
      workflow: { type: "cancelling_session", operationId, session: workflow.session }
    })
    this.#notices.promptProgress("Cancelling session change…")
    this.#requestInput("")
    const settleCancellation = async () => {
      try {
        await cancellation.settled
      } catch (cause) {
        if (this.#accepts(operationId, workflow.session)) this.#showError(cause)
        return
      }
      if (!this.#accepts(operationId, workflow.session)) return
      this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
      this.#notices.clearPrompt()
    }
    void settleCancellation()
    return true
  }

  #finishAuthentication(outcome: "info" | "error", message: string): void {
    if (this.#disposed) return
    this.#pendingAuthPrompt?.cleanup()
    this.#pendingAuthPrompt = undefined
    this.picker.close()
    this.$state.set({ ...this.$state.get(), authCeremony: undefined, workflow: { type: "idle" } })
    if (outcome === "info") this.#notices.promptInfo(message)
    else this.#notices.promptError(message)
    this.#requestInput("")
  }

  #logout(): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.$state.set({ ...this.$state.get(), workflow: { type: "loading_logout", operationId, session } })
    this.#notices.promptProgress("Loading stored credentials…")
    this.#requestInput("")

    const load = async () => {
      let stored: readonly StoredCredential[]
      try {
        stored = await session.storedCredentials()
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.#finishAuthentication("error", errorMessage(cause))
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      if (stored.length === 0) {
        this.#finishAuthentication("info", "No stored credentials to remove")
        return
      }
      if (stored.length === 1) {
        this.#logoutProvider(operationId, session, stored[0]!.providerId)
        return
      }
      this.#admitChoosing(logoutFrame(stored), { type: "choosing_logout", operationId, session, credentials: stored })
    }
    void load()
  }

  #logoutProvider(operationId: number, session: AgentSession, providerId: string): void {
    if (!this.#accepts(operationId, session)) return
    this.picker.close()
    this.$state.set({ ...this.$state.get(), workflow: { type: "logging_out", operationId, session, providerId } })
    this.#notices.promptProgress(`Removing stored credentials for ${providerId}…`)
    this.#requestInput("")

    const apply = async () => {
      try {
        await session.logout(providerId)
      } catch (cause) {
        if (this.#accepts(operationId, session)) {
          this.#finishAuthentication("error", errorMessage(cause))
        }
        return
      }
      if (!this.#accepts(operationId, session)) return
      this.#finishAuthentication(
        "info",
        `Logged out of ${providerId}; environment and external configuration remain available`
      )
    }
    void apply()
  }

  #openCodexSettings(parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.#admitChoosing(
      codexSettingsFrame(session),
      { type: "choosing_codex_setting", operationId, session },
      parentFilter
    )
    this.#requestInput("")
  }

  #openSettings(parentFilter?: string): void {
    const session = this.#interactive.getSession()
    const operationId = ++this.#nextOperationId
    this.#admitChoosing(settingsScopeFrame(), { type: "choosing_settings_scope", operationId, session }, parentFilter)
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

    const shadowed = mutation.requested !== mutation.effective
    this.#notices.promptInfo(
      shadowed
        ? `${settingLabel(workflow.setting)} saved as ${settingValueLabel(mutation.requested)}; project override keeps ${settingValueLabel(mutation.effective)} effective`
        : `${settingLabel(workflow.setting)}: ${settingValueLabel(mutation.effective)} (${workflow.scope})`
    )
    // Settings are a batch-edit surface: a committed value returns to the
    // parent list with its filter and selection intact.
    this.#returnToParentChooser()
    return true
  }

  #accepts(operationId: number, session: AgentSession): boolean {
    this.#cancelStaleModelRefresh()
    if (this.#disposed || this.#interactive.getSession() !== session) return false
    const workflow = this.$state.get().workflow
    return workflow.type !== "idle" && workflow.operationId === operationId && workflow.session === session
  }

  #cancelStaleModelRefresh(): void {
    const refresh = this.#modelRefresh
    if (refresh.type === "idle" || this.#disposed) return
    const workflow = this.$state.get().workflow
    if (
      this.#interactive.getSession() === refresh.session &&
      workflow.type === "choosing_model" &&
      workflow.operationId === refresh.operationId &&
      workflow.session === refresh.session
    ) {
      return
    }
    this.#cancelModelRefresh()
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

  #mergeQueue(queue: QueuedInputs, currentText: string, showNotice: boolean): string {
    const entries = [...queue.steering, ...queue.followUp]
    const texts = entries.map(entry => entry.text)
    const images = entries.flatMap(entry => entry.images)
    const state = this.$state.get()
    this.$state.set({ ...state, images: images.length === 0 ? state.images : [...images, ...state.images] })
    if (showNotice) {
      this.#notices.promptInfo(
        texts.length === 0
          ? "No queued messages to restore"
          : `Restored ${texts.length} queued message${texts.length === 1 ? "" : "s"} to editor${
              images.length === 0 ? "" : ` with ${images.length} image${images.length === 1 ? "" : "s"}`
            }`
      )
    } else {
      this.#notices.clearPrompt()
    }
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
    this.#cancelModelRefresh()
    this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
    this.#notices.clearPrompt()
  }

  #admitChoosing(frame: PickerFrame, workflow: PickerWorkflow, parentFilter?: string): void {
    if (parentFilter === undefined) this.picker.open(frame, workflow)
    else this.picker.push(frame, parentFilter, workflow)
    this.$state.set({ ...this.$state.get(), workflow })
    this.#notices.clearPrompt()
  }

  #replaceChoosing(frame: PickerFrame, filter: string, workflow: PickerWorkflow): void {
    this.picker.replaceTop(frame, filter, workflow)
    this.$state.set({ ...this.$state.get(), workflow })
  }

  #returnToParentChooser(): void {
    const result = this.picker.back()
    if (result.type === "revealed" && result.workflow) {
      const selectedId = this.picker.presentation(result.filter)?.selectedId
      let frame: PickerFrame | undefined
      switch (result.workflow.type) {
        case "choosing_codex_setting":
          frame = codexSettingsFrame(result.workflow.session)
          break
        case "choosing_setting":
          frame = settingsFrame(result.workflow.session, result.workflow.scope)
          break
      }
      if (frame) {
        this.#replaceChoosing({ ...frame, ...(selectedId ? { selectedId } : {}) }, result.filter, result.workflow)
      } else {
        this.$state.set({ ...this.$state.get(), workflow: result.workflow })
      }
      this.#requestInput(result.filter)
      return
    }
    this.$state.set({ ...this.$state.get(), workflow: { type: "idle" } })
    this.#requestInput("")
  }

  #showError(cause: unknown): void {
    if (!this.#disposed) this.#notices.promptError(errorMessage(cause))
  }
}

function modelRefreshCompletionFooter(failedProviders: readonly string[]): string {
  if (failedProviders.length === 0) return "Model catalogs refreshed."
  if (failedProviders.length === 1) {
    return `Could not refresh ${failedProviders[0]}; showing cached models.`
  }
  return `Could not refresh ${failedProviders.length} model catalogs; showing cached models.`
}

function imageMarkerNotice(action: "Removed" | "Restored", count: number): string {
  return `${action} ${count} attached image${count === 1 ? "" : "s"}`
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

function reloadNoticeMessage(result: SessionReloadResult): string {
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

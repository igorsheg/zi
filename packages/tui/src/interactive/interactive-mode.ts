import { basename } from "node:path"

import { BoxRenderable, CliRenderEvents, type CliRenderer, type SyntaxStyle } from "@opentui/core"
import type {
  AgentSession,
  AgentSessionRuntime,
  ProjectTrustResolution,
  SessionBootstrapDiagnostic
} from "@with-zi/coding-agent"

import { createSyntaxStyle, defaultTheme, type Theme } from "../theme.js"
import { type BrowserOpener, SystemBrowserOpener } from "./browser-opener.js"
import {
  type ClipboardReader,
  type ClipboardWriter,
  SystemClipboardReader,
  SystemClipboardWriter
} from "./clipboard.js"
import {
  captureTuiMemorySnapshot,
  TuiDiagnosticsOverlay,
  type TuiDiagnosticFlags,
  type TuiMemorySnapshot
} from "./diagnostics.js"
import { ExitGestureController } from "./exit-gesture.js"
import { type ExternalEditor, SystemExternalEditor } from "./external-editor.js"
import { InteractiveKeybindings, type InteractiveKeybindingOverrides } from "./interactive-keybindings.js"
import { createInteractiveStore, type InteractiveStore } from "./interactive-store.js"
import {
  NotificationCenter,
  type NotificationAPI,
  type NotificationCenterOptions,
  type NotificationLevel,
  type NotificationOptions,
  validateNotificationCenterOptions
} from "./notifications.js"
import type { PromptSessionActions } from "./prompt/store.js"
import { SessionScreen } from "./screen.js"
import { SelectionCopyController } from "./selection-copy.js"
import { SlashController } from "./slash-controller.js"
import { SystemNotificationPresenter, type SystemNoticeActions } from "./system-notifications.js"
import type { TranscriptDiagnostics } from "./transcript/view.js"

type InitialProjectTrustState =
  | { readonly type: "pending"; readonly settled: Promise<void>; readonly resolve: () => void }
  | { readonly type: "settled"; readonly settled: Promise<void> }

export interface InteractiveModeOptions {
  readonly renderer: CliRenderer
  readonly session: AgentSession
  readonly sessionRuntime?: AgentSessionRuntime
  readonly onExit: () => void
  readonly keybindingOverrides?: InteractiveKeybindingOverrides
  readonly theme?: Theme
  readonly browserOpener?: BrowserOpener
  readonly clipboardReader?: ClipboardReader
  readonly clipboardWriter?: ClipboardWriter
  readonly externalEditor?: ExternalEditor
  readonly diagnostics?: TuiDiagnosticFlags
  readonly notificationOptions?: NotificationCenterOptions
  readonly bootstrapDiagnostic?: SessionBootstrapDiagnostic
}

export class InteractiveMode {
  readonly root: BoxRenderable
  readonly store: InteractiveStore
  readonly notifications: NotificationAPI

  readonly #renderer: CliRenderer
  readonly #sessionRuntime: AgentSessionRuntime | undefined
  readonly #sessionActions: PromptSessionActions | undefined
  readonly #browserOpener: BrowserOpener
  readonly #clipboardReader: ClipboardReader
  readonly #clipboardWriter: ClipboardWriter
  readonly #externalEditor: ExternalEditor
  readonly #exitGestures: ExitGestureController
  readonly #theme: Theme
  readonly #syntaxStyle: SyntaxStyle
  readonly #slash: SlashController
  readonly #keybindings: InteractiveKeybindings
  readonly #selectionCopy: SelectionCopyController
  readonly #diagnosticFlags: TuiDiagnosticFlags
  readonly #diagnostics: TuiDiagnosticsOverlay | undefined
  readonly #notifications: NotificationCenter
  readonly #systemNotifications: SystemNotificationPresenter
  #initialProjectTrust = createInitialProjectTrustState()
  #screen: SessionScreen
  #releaseGeneration: () => void
  #disposed = false

  constructor({
    renderer,
    session,
    sessionRuntime,
    onExit,
    keybindingOverrides,
    theme = defaultTheme,
    browserOpener = new SystemBrowserOpener(),
    clipboardReader = new SystemClipboardReader(),
    clipboardWriter,
    externalEditor,
    diagnostics = { showTimeToFirstDraw: false, showStats: false, showMemory: false },
    notificationOptions,
    bootstrapDiagnostic
  }: InteractiveModeOptions) {
    if (sessionRuntime && sessionRuntime.session !== session) {
      throw new Error("InteractiveMode session must be the session runtime current session")
    }
    validateNotificationCenterOptions(notificationOptions)
    this.#renderer = renderer
    this.#sessionRuntime = sessionRuntime
    this.#sessionActions = sessionRuntime
      ? {
          listSessions: () => sessionRuntime.listSessions(),
          startNewSession: async () => {
            const next = await sessionRuntime.newSession()
            if (!this.#disposed) this.replaceSession(next.session, next.bootstrapDiagnostic)
          },
          resumeSession: async path => {
            const next = await sessionRuntime.switchSession(path)
            if (!this.#disposed) this.replaceSession(next.session, next.bootstrapDiagnostic)
          },
          decideProjectTrust: async selection => {
            const next = await sessionRuntime.decideProjectTrust(selection)
            if (!this.#disposed) this.replaceSession(next.session, next.bootstrapDiagnostic)
          },
          dismissProjectTrust: () => {
            if (!this.#disposed) {
              this.#systemNotifications.setProjectTrust("Project .zi configuration remains disabled for this session")
            }
            this.#settleInitialProjectTrust()
          },
          cancelReplacement: () => sessionRuntime.cancelReplacement()
        }
      : undefined
    this.#browserOpener = browserOpener
    this.#clipboardReader = clipboardReader
    this.#clipboardWriter = clipboardWriter ?? new SystemClipboardWriter(text => renderer.copyToClipboardOSC52(text))
    this.#externalEditor = externalEditor ?? new SystemExternalEditor(renderer)
    this.#exitGestures = new ExitGestureController(onExit)
    this.store = createInteractiveStore(session)
    this.#theme = theme
    this.#syntaxStyle = createSyntaxStyle(theme)
    this.#slash = new SlashController(
      () => this.store.getSession(),
      () => this.store.$generation.get()
    )
    this.#keybindings = new InteractiveKeybindings(keybindingOverrides)
    this.#selectionCopy = new SelectionCopyController(
      renderer,
      this.#keybindings,
      this.#clipboardWriter,
      () => this.#exitGestures.consume(),
      () => this.#systemNotifications.copySucceeded(),
      message => this.#systemNotifications.copyFailed(message)
    )
    this.#diagnosticFlags = diagnostics
    this.root = new BoxRenderable(renderer, {
      id: "interactive-mode",
      width: "100%",
      height: "100%",
      flexDirection: "column",
      backgroundColor: theme.surface.app
    })
    const notifications = new NotificationCenter(renderer, theme, notificationOptions)
    let systemNotifications: SystemNotificationPresenter
    try {
      systemNotifications = new SystemNotificationPresenter(this.store, notifications)
    } catch (cause) {
      notifications.dispose()
      throw cause
    }
    let screen: SessionScreen
    try {
      screen = this.#createScreen(systemNotifications)
    } catch (cause) {
      systemNotifications.dispose()
      notifications.dispose()
      throw cause
    }
    try {
      this.root.add(screen.root)
      notifications.attach(screen.transcript.root)
    } catch (cause) {
      screen.destroy()
      systemNotifications.dispose()
      notifications.dispose()
      throw cause
    }
    this.#notifications = notifications
    this.notifications = notifications
    this.#systemNotifications = systemNotifications
    this.#screen = screen
    this.#diagnostics =
      diagnostics.showTimeToFirstDraw || diagnostics.showStats || diagnostics.showMemory
        ? new TuiDiagnosticsOverlay(
            renderer,
            diagnostics,
            () => this.#screen.transcript,
            diagnostics.showMemory ? () => this.captureMemoryDiagnostics() : undefined,
            theme
          )
        : undefined
    if (this.#diagnostics) this.root.add(this.#diagnostics.root)
    renderer.root.add(this.root)
    this.#screen.prompt.focus()
    renderer.on(CliRenderEvents.SELECTION, this.#preservePromptFocus)

    this.#releaseGeneration = this.store.$generation.listen(() => this.#replaceScreen())
    this.#showBootstrapWarning(bootstrapDiagnostic)
    this.#showExtensionWarning(session)
    this.#presentProjectTrust(sessionRuntime?.projectTrust)
  }

  notify(msg: string | null | undefined, level?: NotificationLevel | null, opts?: NotificationOptions): void {
    this.#notifications.notify(msg, level, opts)
  }

  waitForInitialProjectTrust(): Promise<void> {
    return this.#initialProjectTrust.settled
  }

  replaceSession(session: AgentSession, diagnostic?: SessionBootstrapDiagnostic): void {
    if (this.#sessionRuntime && this.#sessionRuntime.session !== session) {
      throw new Error("InteractiveMode can only bind the current session runtime session")
    }
    this.store.replaceSession(session)
    this.#showBootstrapWarning(diagnostic)
    this.#showExtensionWarning(session)
    this.#presentProjectTrust(this.#sessionRuntime?.projectTrust)
  }

  get transcriptDiagnostics(): TranscriptDiagnostics {
    return this.#screen.transcript.diagnostics
  }

  captureMemoryDiagnostics(): TuiMemorySnapshot {
    return captureTuiMemorySnapshot(this.#renderer, this.store.getSession(), this.#screen.transcript.retainedRootCount)
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#settleInitialProjectTrust()
    this.#releaseGeneration()
    this.#selectionCopy.dispose()
    this.#renderer.off(CliRenderEvents.SELECTION, this.#preservePromptFocus)
    this.#diagnostics?.destroy()
    this.#systemNotifications.dispose()
    this.#notifications.dispose()
    this.#screen.destroy()
    this.#externalEditor.dispose()
    this.#browserOpener.dispose()
    this.root.destroyRecursively()
    this.#syntaxStyle.destroy()
    this.store.dispose()
  }

  #preservePromptFocus = (): void => {
    this.#screen.prompt.focus()
  }

  #showBootstrapWarning(diagnostic: SessionBootstrapDiagnostic | undefined): void {
    this.#systemNotifications.setBootstrap(diagnostic?.message)
  }

  #showExtensionWarning(session: AgentSession): void {
    const snapshot = session.extensionHostSnapshot
    if (!snapshot) {
      this.#systemNotifications.setExtension(undefined)
      return
    }
    const diagnostic = snapshot.diagnostics[0] ?? snapshot.failure
    if (!diagnostic) {
      this.#systemNotifications.setExtension(undefined)
      return
    }
    const source = diagnostic.path ? `${basename(diagnostic.path)}: ` : ""
    const omitted = snapshot.omittedDiagnostics + Math.max(0, snapshot.diagnostics.length - 1)
    const suffix = omitted > 0 ? ` (${omitted} additional diagnostics)` : ""
    this.#systemNotifications.setExtension(`Extension ${source}${diagnostic.message.replace(/[\r\n]+/g, " ")}${suffix}`)
  }

  #presentProjectTrust(trust: ProjectTrustResolution | undefined): void {
    if (!trust) {
      this.#systemNotifications.setProjectTrust(undefined)
      this.#settleInitialProjectTrust()
      return
    }
    switch (trust.type) {
      case "unresolved":
        this.#systemNotifications.setProjectTrust(undefined)
        this.#screen.prompt.requestProjectTrust(trust.cwd)
        return
      case "untrusted":
        this.#systemNotifications.setProjectTrust(trust.diagnostic?.message)
        this.#settleInitialProjectTrust()
        return
      case "trusted":
      case "not_required":
        this.#systemNotifications.setProjectTrust(undefined)
        this.#settleInitialProjectTrust()
        return
      default:
        assertNever(trust)
    }
  }

  #settleInitialProjectTrust(): void {
    const trust = this.#initialProjectTrust
    if (trust.type === "settled") return
    this.#initialProjectTrust = { type: "settled", settled: trust.settled }
    trust.resolve()
  }

  #replaceScreen(): void {
    this.#notifications.detach()
    this.#screen.destroy()
    this.#screen = this.#createScreen(this.#systemNotifications)
    this.root.add(this.#screen.root)
    this.#notifications.attach(this.#screen.transcript.root)
    this.#screen.prompt.focus()
  }

  #createScreen(systemNotices: SystemNoticeActions): SessionScreen {
    return new SessionScreen(
      this.#renderer,
      this.store,
      this.#slash,
      this.#keybindings,
      this.#exitGestures,
      this.#browserOpener,
      this.#clipboardReader,
      this.#externalEditor,
      this.#theme,
      this.#syntaxStyle,
      this.#diagnosticFlags.showTimeToFirstDraw || this.#diagnosticFlags.showStats || this.#diagnosticFlags.showMemory,
      systemNotices,
      this.#sessionActions
    )
  }
}

function createInitialProjectTrustState(): InitialProjectTrustState {
  let resolve!: () => void
  const settled = new Promise<void>(resolvePromise => {
    resolve = resolvePromise
  })
  return { type: "pending", settled, resolve }
}

function assertNever(value: never): never {
  throw new Error(`Unknown project trust resolution: ${String(value)}`)
}

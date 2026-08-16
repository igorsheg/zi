import type { AgentMessage, AgentSession, AgentSnapshot, ShellTaskSnapshot } from "@with-zi/coding-agent"
import type { ReadableAtom } from "nanostores"

import type { ActiveTool } from "../interactive-store.js"

export interface TranscriptSession extends Pick<
  AgentSession,
  "messages" | "streamingMessage" | "isStreaming" | "isAborting" | "retryStatus" | "compactionStatus" | "workPlan"
> {
  readonly sessionManager?: { readonly header: { readonly cwd: string } }
  readonly shellTasks?: readonly ShellTaskSnapshot[]
  agentSnapshots?(): readonly AgentSnapshot[]
}

export interface TranscriptSource {
  readonly $promptRevision: ReadableAtom<number>
  readonly $transcriptRevision: ReadableAtom<number>
  readonly $activeTools: ReadableAtom<ReadonlyMap<string, ActiveTool>>
  getSession(): TranscriptSession
}

export type { AgentMessage }

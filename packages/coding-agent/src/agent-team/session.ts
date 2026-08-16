import type { AgentSession } from "../agent-session.js"
import type { AgentMessage } from "../messages.js"
import { type AgentTeamMailAdmission, type AgentTeamRoot, type AgentTeamSessionOwner } from "./agent-team.js"
import type { AgentMailInput, AgentMailPublication } from "./mail.js"
import { agentTurnResult } from "./result.js"

export function createAgentTeamSessionOwner(session: AgentSession): AgentTeamSessionOwner {
  return new ProductionAgentTeamSessionOwner(session)
}

export function createAgentTeamRoot(session: AgentSession): AgentTeamRoot {
  return {
    sessionId: session.sessionId,
    admitMail(input) {
      const publication: AgentMailPublication = session.isStreaming ? "boundary" : "append"
      return session.admitAgentMail(input, publication)
    }
  }
}

class ProductionAgentTeamSessionOwner implements AgentTeamSessionOwner {
  readonly sessionId: string
  readonly #session: AgentSession
  #interruption: "requested" | "turn_timeout" | "shutdown" | undefined

  constructor(session: AgentSession) {
    this.#session = session
    this.sessionId = session.sessionId
  }

  startTurn(input: AgentMailInput, commit: Parameters<AgentSession["startAgentTurn"]>[1]) {
    this.#interruption = undefined
    const startedAt = Date.now()
    const admission = this.#session.startAgentTurn(input, commit)
    const result = () =>
      agentTurnResult(turnMessages(this.#session, admission.entry.id), Date.now() - startedAt, this.#interruption)
    return { entry: admission.entry, settled: admission.settled.then(result, result) }
  }

  admitMail(input: AgentMailInput, publication: AgentMailPublication): AgentTeamMailAdmission {
    return this.#session.admitAgentMail(input, publication)
  }

  async interrupt(reason: "requested" | "turn_timeout" | "shutdown"): Promise<void> {
    this.#interruption = reason
    await this.#session.abort()
  }

  async dispose(): Promise<void> {
    this.#session.dispose()
    await this.#session.waitForIdle()
  }
}

function turnMessages(session: AgentSession, inputEntryId: string): readonly AgentMessage[] {
  const messages: AgentMessage[] = []
  let afterInput = false
  for (const entry of session.sessionManager.entries()) {
    if (!afterInput) {
      afterInput = entry.id === inputEntryId
      continue
    }
    if (entry.type === "message") messages.push(entry.message)
  }
  return messages
}

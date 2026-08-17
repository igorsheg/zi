import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentSessionEvent } from "../src/agent-session.js"
import {
  AgentTeam,
  type AgentTranscriptEvent,
  type AgentTeamChange,
  type AgentTeamRoot,
  type AgentTeamSessionOwner,
  type AgentTeamSessionTranscript
} from "../src/agent-team/agent-team.js"
import { agentMailDeliveryId, agentMailMessage, isAgentMailEntry, type AgentMailInput } from "../src/agent-team/mail.js"
import { parseAgentPath, rootAgentPath } from "../src/agent-team/path.js"
import type { AgentTurnResult } from "../src/agent-team/result.js"
import { isAgentTeamToolDetails } from "../src/agent-team/tool-details.js"
import { createAgentTeamTools } from "../src/agent-team/tools.js"
import { ZiPaths } from "../src/paths.js"
import { SessionManager, type CustomMessageEntry } from "../src/session-manager.js"

const research = parseAgentPath("/root/research")
const fact = parseAgentPath("/root/research/fact")
const execution = { model: { provider: "test", modelId: "model" }, thinkingLevel: "medium" } as const
const spawnSpec = (forkTurns: "all" | "none" | number = "all") => ({
  agentType: "default" as const,
  forkTurns,
  execution
})

const completed = (text: string): AgentTurnResult => ({
  status: "completed",
  durationMs: 10,
  text,
  originalBytes: Buffer.byteLength(text),
  omittedBytes: 0,
  truncated: false
})

class ControlledSession implements AgentTeamSessionOwner {
  readonly sessionId: string
  readonly transcriptListeners = new Set<Parameters<AgentTeamSessionTranscript["subscribe"]>[0]>()
  readonly transcript: AgentTeamSessionTranscript = {
    streamingMessage: undefined,
    isStreaming: false,
    isAborting: false,
    retryStatus: { type: "idle" },
    compactionStatus: { type: "idle" },
    workPlan: { revision: 0, steps: [] },
    shellTasks: [],
    subscribe: listener => {
      this.transcriptListeners.add(listener)
      return () => this.transcriptListeners.delete(listener)
    }
  }
  readonly turns: Array<{
    readonly input: AgentMailInput
    readonly settlement: ReturnType<typeof deferred<AgentTurnResult>>
  }> = []
  readonly mail: AgentMailInput[] = []
  disposed = false

  constructor(readonly manager: SessionManager) {
    this.sessionId = manager.sessionId
  }

  startTurn(input: AgentMailInput, commit: (entry: CustomMessageEntry) => void) {
    const entry = this.manager.appendCriticalCustomMessage(agentMailMessage(input))
    commit(entry)
    const settlement = deferred<AgentTurnResult>()
    this.turns.push({ input, settlement })
    return { entry, settled: settlement.promise }
  }

  admitMail(input: AgentMailInput, publication: "append" | "boundary") {
    const existing = this.manager.customMessageEntries().find(entry => agentMailDeliveryId(entry) === input.deliveryId)
    if (existing) {
      if (!isAgentMailEntry(existing, input)) throw new Error("mail conflict")
      return { entry: existing, duplicate: true, publication }
    }
    const entry = this.manager.appendCriticalCustomMessage(agentMailMessage(input))
    this.mail.push(input)
    return { entry, duplicate: false, publication }
  }

  async interrupt(reason: "requested" | "turn_timeout" | "shutdown"): Promise<void> {
    const active = this.turns.at(-1)
    if (!active) return
    active.settlement.resolve({
      status: "interrupted",
      reason,
      durationMs: 0,
      text: "",
      originalBytes: 0,
      omittedBytes: 0,
      truncated: false
    })
  }

  async dispose(): Promise<void> {
    this.disposed = true
  }

  settle(result: AgentTurnResult): void {
    if (result.status === "completed") this.manager.appendMessage(assistant(result.text))
    const active = this.turns.at(-1)
    if (!active) throw new Error("No active turn")
    active.settlement.resolve(result)
  }

  emitTranscript(event: AgentSessionEvent): void {
    for (const listener of this.transcriptListeners) listener(event)
  }
}

class HangingInterruptSession extends ControlledSession {
  override interrupt(): Promise<void> {
    return new Promise(() => {})
  }
}

class RootMailbox implements AgentTeamRoot {
  readonly sessionId: string
  readonly received: AgentMailInput[] = []

  constructor(readonly manager: SessionManager) {
    this.sessionId = manager.sessionId
  }

  admitMail(input: AgentMailInput) {
    const existing = this.manager.customMessageEntries().find(entry => agentMailDeliveryId(entry) === input.deliveryId)
    if (existing) {
      if (!isAgentMailEntry(existing, input)) throw new Error("mail conflict")
      return { entry: existing, duplicate: true, publication: "append" as const }
    }
    const entry = this.manager.appendCriticalCustomMessage(agentMailMessage(input))
    this.received.push(input)
    return { entry, duplicate: false, publication: "append" as const }
  }
}

test("AgentTeam commits spawn and turn evidence before one passive completion", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const rootManager = SessionManager.inMemory(paths.cwd, "root-session")
    rootManager.appendMessage({ role: "user", content: "parent context", timestamp: 1 })
    const owners: ControlledSession[] = []
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: rootManager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        owners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    const rootMailbox = new RootMailbox(rootManager)
    await team.bindRoot(rootMailbox)

    let observedWaitTimeoutMs: number | undefined
    const tools = createAgentTeamTools(
      team,
      rootAgentPath,
      request => ({ agentType: request.agentType ?? "default", forkTurns: request.forkTurns, execution }),
      timeoutMs => {
        observedWaitTimeoutMs = timeoutMs
        return Promise.resolve("mailbox")
      },
      180_000
    )
    expect(tools.map(tool => tool.name)).toEqual([
      "spawn_agent",
      "send_message",
      "followup_task",
      "wait_agent",
      "list_agents",
      "interrupt_agent"
    ])
    const spawnTool = tools.find(tool => tool.name === "spawn_agent")
    if (!spawnTool) throw new Error("spawn_agent is missing")
    const waitTool = tools.find(tool => tool.name === "wait_agent")
    if (!waitTool) throw new Error("wait_agent is missing")
    await waitTool.execute("default-wait", {}, undefined)
    expect(observedWaitTimeoutMs).toBe(180_000)
    const waited = await waitTool.execute("wait", { timeout_ms: 1 }, undefined)
    expect(observedWaitTimeoutMs).toBe(10_000)
    expect(waited.content).toEqual([
      {
        type: "text",
        text: '{"message":"Wait completed.\\n\\nRequested timeout of 1ms was clamped to the minimum of 10000ms.","timed_out":false}'
      }
    ])
    expect(waited.details).toEqual({
      type: "agent_team",
      outcome: "success",
      operation: "wait",
      activity: "mailbox",
      timedOut: false
    })
    const properties = Reflect.get(spawnTool.parameters, "properties")
    expect(Reflect.get(Reflect.get(properties, "task_name"), "pattern")).toBe("^[a-z][a-z0-9_-]*$")
    expect(Reflect.get(Reflect.get(properties, "agent_type"), "anyOf")).toEqual([
      { const: "default", type: "string" },
      { const: "explorer", type: "string" },
      { const: "worker", type: "string" }
    ])

    const spawned = await spawnTool.execute(
      "spawn",
      { task_name: "research", message: "inspect", fork_turns: "all" },
      undefined
    )
    expect(isAgentTeamToolDetails(spawned.details)).toBeTrue()
    expect(spawned.details).toMatchObject({
      type: "agent_team",
      outcome: "success",
      operation: "spawn",
      agent: { path: research, residency: "resident", turnState: "running", turnNumber: 1 }
    })
    expect(rootManager.agentTeamEntries().map(entry => entry.type)).toEqual([
      "agent_spawn_reserved",
      "agent_spawn_committed",
      "agent_turn_reserved",
      "agent_turn_started"
    ])
    expect(owners[0]!.manager.activeMessages()).toEqual([
      { role: "user", content: "parent context", timestamp: 1 },
      expect.objectContaining({ role: "custom", customType: "zi.agent-task.v1" })
    ])

    owners[0]!.settle(completed("first result"))
    await team.waitForIdle(research)

    expect(team.snapshots()).toEqual([
      expect.objectContaining({
        path: research,
        residency: "unloaded",
        turn: "idle",
        turnNumber: 1,
        status: "completed"
      })
    ])
    expect(rootMailbox.received).toHaveLength(1)
    expect(rootMailbox.received[0]).toMatchObject({ sender: research, target: rootAgentPath, kind: "completion" })
    expect(
      rootManager
        .agentTeamEntries()
        .map(entry => entry.type)
        .slice(-2)
    ).toEqual(["agent_turn_settled", "agent_completion_delivered"])
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam transcript lease reads one durable child without residency and follows its live handoff", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-transcript-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const manager = SessionManager.create(paths, { sessionId: "root-session" })
    manager.appendMessage({ role: "user", content: "parent context", timestamp: 1 })
    const owners: ControlledSession[] = []
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: manager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        owners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    await team.bindRoot(new RootMailbox(manager))
    await team.spawn({ sender: rootAgentPath, taskName: "research", message: "first", spec: spawnSpec("none") })
    owners[0]!.settle(completed("first answer"))
    await team.waitForIdle(research)

    const beforeOpen = team.snapshots()
    const lease = await team.openTranscript(research, new AbortController().signal)
    const durableMessages = lease.snapshot().messages
    expect(team.snapshots()).toEqual(beforeOpen)
    expect(owners).toHaveLength(1)
    expect(lease.snapshot()).toMatchObject({
      agent: { path: research, residency: "unloaded", status: "completed" },
      isStreaming: false,
      isAborting: false,
      retryStatus: { type: "idle" },
      compactionStatus: { type: "idle" },
      workPlan: { revision: 0, steps: [] },
      shellTasks: []
    })
    expect(durableMessages).toContainEqual(
      expect.objectContaining({ role: "assistant", content: [{ type: "text", text: "first answer" }] })
    )

    const events: AgentTranscriptEvent[] = []
    lease.subscribe(event => events.push(event))
    expect(await team.followupTask(rootAgentPath, research, "second")).toBe("started")
    expect(owners).toHaveLength(2)
    expect(owners[1]!.manager.presentationMessages()).toBe(durableMessages)
    expect(owners[1]!.transcriptListeners.size).toBe(1)
    const staleSecondTurnListener = [...owners[1]!.transcriptListeners][0]!
    owners[1]!.emitTranscript({ type: "agent_start" })
    owners[1]!.emitTranscript({
      type: "tool_execution_start",
      toolCallId: "call-2",
      toolName: "read",
      args: { path: "second.ts" }
    })
    owners[1]!.emitTranscript({
      type: "tool_execution_update",
      toolCallId: "call-2",
      toolName: "read",
      args: { path: "second.ts" },
      partialResult: { content: [{ type: "text", text: "partial" }], details: {} }
    })
    owners[1]!.emitTranscript({
      type: "tool_execution_end",
      toolCallId: "call-2",
      toolName: "read",
      result: { content: [{ type: "text", text: "done" }], details: {} },
      isError: false
    })
    const secondGeneration = events.findLast(event => event.type === "session")?.sourceGeneration
    expect(secondGeneration).toBeGreaterThan(0)
    expect(
      events.filter(event => event.type === "session").map(event => (event.type === "session" ? event.event.type : ""))
    ).toEqual(["agent_start", "tool_execution_start", "tool_execution_update", "tool_execution_end"])

    owners[1]!.settle(completed("second answer"))
    await team.waitForIdle(research)
    expect(lease.snapshot().messages).toBe(durableMessages)
    expect(lease.snapshot().agent).toMatchObject({ residency: "unloaded", turnNumber: 2, status: "completed" })
    expect(owners[1]!.transcriptListeners.size).toBe(0)
    const eventCountAfterUnload = events.length
    staleSecondTurnListener({ type: "agent_start" })
    expect(events).toHaveLength(eventCountAfterUnload)

    expect(await team.followupTask(rootAgentPath, research, "third")).toBe("started")
    expect(owners).toHaveLength(3)
    owners[2]!.emitTranscript({ type: "shell_task_changed", taskId: "task-3" })
    const thirdTurnEvent = events.findLast(event => event.type === "session")
    expect(thirdTurnEvent).toMatchObject({ type: "session", event: { type: "shell_task_changed", taskId: "task-3" } })
    expect(thirdTurnEvent?.sourceGeneration).toBeGreaterThan(secondGeneration ?? 0)
    staleSecondTurnListener({ type: "agent_start" })
    expect(events.at(-1)).toBe(thirdTurnEvent)

    const staleThirdTurnListener = [...owners[2]!.transcriptListeners][0]!
    lease.dispose()
    expect(owners[2]!.transcriptListeners.size).toBe(0)
    staleThirdTurnListener({ type: "agent_start" })
    expect(events.at(-1)).toBe(thirdTurnEvent)
    owners[2]!.settle(completed("third answer"))
    await team.waitForIdle(research)

    const reopened = await team.openTranscript(research, new AbortController().signal)
    reopened.dispose()
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam transcript lease handles recursive interrupted memory agents and cancellation", async () => {
  const manager = SessionManager.inMemory("/work", "root-session")
  const owners: ControlledSession[] = []
  const team = await AgentTeam.create({
    paths: new ZiPaths("/work", "/agent"),
    rootSessionManager: manager,
    createSession: request => {
      const owner = new ControlledSession(request.sessionManager)
      owners.push(owner)
      return Promise.resolve(owner)
    },
    turnTimeoutMs: 10_000,
    shutdownTimeoutMs: 1_000
  })
  await team.bindRoot(new RootMailbox(manager))
  await team.spawn({ sender: rootAgentPath, taskName: "research", message: "parent", spec: spawnSpec("none") })
  await team.spawn({ sender: research, taskName: "fact", message: "nested", spec: spawnSpec("none") })
  expect(await team.interrupt(fact)).toBe("interrupted")
  await team.waitForIdle(fact)

  const cancelled = new AbortController()
  const opening = team.openTranscript(fact, cancelled.signal)
  cancelled.abort()
  expect(opening).rejects.toThrow("Agent transcript load cancelled")
  expect(team.openTranscript(parseAgentPath("/root/missing"), new AbortController().signal)).rejects.toThrow(
    "Unknown agent path"
  )

  const lease = await team.openTranscript(fact, new AbortController().signal)
  expect(lease.snapshot().agent).toMatchObject({
    path: fact,
    parentPath: research,
    residency: "unloaded",
    status: "interrupted"
  })
  lease.dispose()

  owners[0]!.settle(completed("parent done"))
  await team.waitForIdle(research)
  await team.shutdown()
})

test("AgentTeam transcript lease reports a missing durable child journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-transcript-missing-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const manager = SessionManager.create(paths, { sessionId: "root-session" })
    const owners: ControlledSession[] = []
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: manager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        owners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    await team.bindRoot(new RootMailbox(manager))
    await team.spawn({ sender: rootAgentPath, taskName: "research", message: "first", spec: spawnSpec("none") })
    owners[0]!.settle(completed("done"))
    await team.waitForIdle(research)
    await rm(owners[0]!.manager.file!)

    expect(team.openTranscript(research, new AbortController().signal)).rejects.toMatchObject({
      name: "AgentTranscriptOpenError",
      reason: "unavailable",
      message: "The durable child journal is unavailable."
    })
    expect(team.snapshots()[0]).toMatchObject({ residency: "unloaded", status: "completed" })
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam routes recursive completion to the direct parent", async () => {
  const manager = SessionManager.inMemory("/work", "root-session")
  manager.appendMessage({ role: "user", content: "parent context", timestamp: 1 })
  const owners: ControlledSession[] = []
  const team = await AgentTeam.create({
    paths: new ZiPaths("/work", "/agent"),
    rootSessionManager: manager,
    createSession: request => {
      const owner = new ControlledSession(request.sessionManager)
      owners.push(owner)
      return Promise.resolve(owner)
    },
    turnTimeoutMs: 10_000,
    shutdownTimeoutMs: 1_000
  })
  const rootMailbox = new RootMailbox(manager)
  await team.bindRoot(rootMailbox)

  await team.spawn({ sender: rootAgentPath, taskName: "research", message: "research", spec: spawnSpec() })
  await team.spawn({ sender: research, taskName: "fact", message: "find a fact", spec: spawnSpec("none") })
  expect(team.snapshots()).toEqual([
    expect.objectContaining({ path: research, parentPath: rootAgentPath, generation: 1 }),
    expect.objectContaining({ path: fact, parentPath: research, generation: 2 })
  ])

  owners[1]!.settle(completed("nested result"))
  await team.waitForIdle(fact)
  expect(owners[0]!.mail).toContainEqual(
    expect.objectContaining({ sender: fact, target: research, kind: "completion", text: "nested result" })
  )
  expect(rootMailbox.received).toHaveLength(0)

  owners[0]!.settle(completed("parent result"))
  await team.waitForIdle(research)
  expect(rootMailbox.received).toContainEqual(
    expect.objectContaining({ sender: research, target: rootAgentPath, kind: "completion" })
  )
  await team.shutdown()
})

test("AgentTeam retains recursive completion until an unloaded parent is restored", async () => {
  const manager = SessionManager.inMemory("/work", "root-session")
  const owners: ControlledSession[] = []
  const team = await AgentTeam.create({
    paths: new ZiPaths("/work", "/agent"),
    rootSessionManager: manager,
    createSession: request => {
      const owner = new ControlledSession(request.sessionManager)
      owners.push(owner)
      return Promise.resolve(owner)
    },
    turnTimeoutMs: 10_000,
    shutdownTimeoutMs: 1_000
  })
  await team.bindRoot(new RootMailbox(manager))
  await team.spawn({ sender: rootAgentPath, taskName: "research", message: "research", spec: spawnSpec() })
  await team.spawn({ sender: research, taskName: "fact", message: "find a fact", spec: spawnSpec("none") })

  owners[0]!.settle(completed("parent settled first"))
  await team.waitForIdle(research)
  owners[1]!.settle(completed("late nested result"))
  await team.waitForIdle(fact)
  expect(
    manager.agentTeamEntries().some(entry => entry.type === "agent_completion_delivered" && entry.path === fact)
  ).toBe(false)

  expect(await team.followupTask(rootAgentPath, research, "use the late result")).toBe("started")
  expect(owners[2]!.mail).toContainEqual(
    expect.objectContaining({ sender: fact, target: research, kind: "completion", text: "late nested result" })
  )
  expect(
    manager.agentTeamEntries().some(entry => entry.type === "agent_completion_delivered" && entry.path === fact)
  ).toBe(true)
  owners[2]!.settle(completed("done"))
  await team.waitForIdle(research)
  await team.shutdown()
})

test("AgentTeam restores a durable child unloaded and follows up in the same journal", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-restore-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const rootManager = SessionManager.create(paths, { sessionId: "root-session" })
    rootManager.appendMessage({ role: "user", content: "persistent parent", timestamp: 1 })
    rootManager.appendMessage(assistant("parent answer"))
    const firstOwners: ControlledSession[] = []
    const first = await AgentTeam.create({
      paths,
      rootSessionManager: rootManager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        firstOwners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    await first.bindRoot(new RootMailbox(rootManager))
    await first.spawn({ sender: rootAgentPath, taskName: "research", message: "first", spec: spawnSpec() })
    firstOwners[0]!.settle(completed("first child answer"))
    await first.waitForIdle(research)
    const childSessionId = first.snapshots()[0]!.sessionId
    await first.shutdown()

    const restoredRoot = SessionManager.open(rootManager.file!)
    const restoredOwners: ControlledSession[] = []
    const second = await AgentTeam.create({
      paths,
      rootSessionManager: restoredRoot,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        restoredOwners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    const mailbox = new RootMailbox(restoredRoot)
    await second.bindRoot(mailbox)

    expect(second.snapshots()).toEqual([
      expect.objectContaining({ path: research, sessionId: childSessionId, residency: "unloaded", status: "completed" })
    ])
    expect(restoredOwners).toHaveLength(0)

    const restoredTranscript = await second.openTranscript(research, new AbortController().signal)
    expect(restoredTranscript.snapshot().messages).toContainEqual(
      expect.objectContaining({ role: "assistant", content: [{ type: "text", text: "first child answer" }] })
    )
    expect(restoredOwners).toHaveLength(0)
    restoredTranscript.dispose()

    expect(await second.followupTask(rootAgentPath, research, "second")).toBe("started")
    expect(restoredOwners).toHaveLength(1)
    expect(restoredOwners[0]!.sessionId).toBe(childSessionId)
    expect(restoredOwners[0]!.manager.activeMessages()).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ role: "assistant", content: [{ type: "text", text: "first child answer" }] }),
        expect.objectContaining({ role: "custom", content: expect.stringContaining("second") })
      ])
    )

    restoredOwners[0]!.settle(completed("second child answer"))
    await second.waitForIdle(research)
    expect(mailbox.received).toHaveLength(1)
    expect(
      restoredRoot.customMessageEntries().filter(entry => entry.customType === "zi.agent-completion.v1")
    ).toHaveLength(2)
    await second.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam queues idle mail without starting a turn and joins a running follow-up", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-mail-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const manager = SessionManager.inMemory(paths.cwd, "root-session")
    const owners: ControlledSession[] = []
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: manager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        owners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    await team.bindRoot(new RootMailbox(manager))
    await team.spawn({ sender: rootAgentPath, taskName: "research", message: "first", spec: spawnSpec("none") })
    owners[0]!.settle(completed("done"))
    await team.waitForIdle(research)

    const changed = new Promise<AgentTeamChange>(resolve => {
      const unsubscribe = team.subscribe(change => {
        unsubscribe()
        resolve(change)
      })
    })
    await team.sendMessage(rootAgentPath, research, "idle context")
    expect(await changed).toMatchObject({ paths: [research] })
    expect(team.snapshots()[0]).toMatchObject({ residency: "unloaded", turn: "idle", turnNumber: 1 })
    expect(owners).toHaveLength(1)

    expect(await team.followupTask(rootAgentPath, research, "second")).toBe("started")
    expect(owners[1]!.mail[0]).toMatchObject({ kind: "message", text: "idle context" })
    expect(await team.followupTask(rootAgentPath, research, "joined")).toBe("joined")
    expect(owners[1]!.turns).toHaveLength(1)
    expect(owners[1]!.mail.at(-1)).toMatchObject({ kind: "task", text: "joined" })
    owners[1]!.settle(completed("second done"))
    await team.waitForIdle(research)
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam rejects a fourth active turn across recursive branches before durable spawn admission", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-global-turns-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const rootManager = SessionManager.inMemory(paths.cwd, "root-session")
    rootManager.appendMessage({ role: "user", content: "parent context", timestamp: 1 })
    const owners = new Map<string, ControlledSession>()
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: rootManager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        owners.set(request.path, owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })

    await team.spawn({ sender: rootAgentPath, taskName: "branch-a", message: "a", spec: spawnSpec() })
    await team.spawn({ sender: rootAgentPath, taskName: "branch-b", message: "b", spec: spawnSpec() })
    await team.spawn({
      sender: parseAgentPath("/root/branch-a"),
      taskName: "leaf",
      message: "leaf a",
      spec: spawnSpec()
    })

    expect(
      team.spawn({ sender: parseAgentPath("/root/branch-b"), taskName: "leaf", message: "leaf b", spec: spawnSpec() })
    ).rejects.toThrow("Agent turn capacity reached")
    expect(team.snapshots().map(snapshot => String(snapshot.path))).toEqual([
      "/root/branch-a",
      "/root/branch-a/leaf",
      "/root/branch-b"
    ])
    expect(rootManager.agentTeamEntries().filter(entry => entry.type === "agent_spawn_reserved")).toHaveLength(3)

    for (const owner of owners.values()) owner.settle(completed("done"))
    await Promise.all(team.snapshots().map(snapshot => team.waitForIdle(snapshot.path)))
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam evicts settled children before admitting later residency", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-eviction-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const manager = SessionManager.inMemory(paths.cwd, "root-session")
    const owners: ControlledSession[] = []
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: manager,
      createSession: request => {
        const owner = new ControlledSession(request.sessionManager)
        owners.push(owner)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    await team.bindRoot(new RootMailbox(manager))

    const settleChild = async (name: string): Promise<void> => {
      const path = parseAgentPath(`/root/${name}`)
      await team.spawn({ sender: rootAgentPath, taskName: name, message: name, spec: spawnSpec("none") })
      owners.at(-1)!.settle(completed(name))
      await team.waitForIdle(path)
    }
    await settleChild("one")
    await settleChild("two")
    await settleChild("three")
    await settleChild("four")

    expect(team.snapshots()).toHaveLength(4)
    expect(team.snapshots().every(agent => agent.residency === "unloaded")).toBeTrue()
    expect(owners.every(owner => owner.disposed)).toBeTrue()
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam recovers an unclosed turn as interrupted and delivers it after root binding", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-recovery-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const manager = SessionManager.inMemory(paths.cwd, "root-session")
    manager.appendAgentTeam({
      type: "agent_spawn_reserved",
      operationId: "spawn",
      path: research,
      parentPath: rootAgentPath,
      sessionId: "child-session",
      parentSessionId: "root-session",
      parentEntryId: null,
      generation: 1,
      taskName: "research",
      agentType: "default",
      forkTurns: "none",
      execution
    })
    manager.appendAgentTeam({ type: "agent_spawn_committed", operationId: "spawn" })
    manager.appendAgentTeam({
      type: "agent_turn_reserved",
      operationId: "turn",
      path: research,
      turn: 1,
      mailId: "task"
    })
    manager.appendAgentTeam({ type: "agent_turn_started", operationId: "turn", inputEntryId: "child-input" })

    const team = await AgentTeam.create({
      paths,
      rootSessionManager: manager,
      createSession: () => Promise.reject(new Error("must stay unloaded")),
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    const mailbox = new RootMailbox(manager)
    await team.bindRoot(mailbox)

    expect(team.snapshots()).toEqual([
      expect.objectContaining({ path: research, residency: "unloaded", turnNumber: 1, status: "interrupted" })
    ])
    expect(mailbox.received).toHaveLength(1)
    expect(
      manager
        .agentTeamEntries()
        .map(entry => entry.type)
        .slice(-2)
    ).toEqual(["agent_turn_settled", "agent_completion_delivered"])
    await team.shutdown()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam shutdown interrupts running turns and disposes only resident child owners", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-shutdown-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const manager = SessionManager.inMemory(paths.cwd, "root-session")
    let owner: ControlledSession | undefined
    const team = await AgentTeam.create({
      paths,
      rootSessionManager: manager,
      createSession: request => {
        owner = new ControlledSession(request.sessionManager)
        return Promise.resolve(owner)
      },
      turnTimeoutMs: 10_000,
      shutdownTimeoutMs: 1_000
    })
    await team.bindRoot(new RootMailbox(manager))
    await team.spawn({ sender: rootAgentPath, taskName: "research", message: "long", spec: spawnSpec("none") })

    await team.shutdown()
    expect(owner?.disposed).toBe(true)
    expect(manager.agentTeamEntries().some(entry => entry.type === "agent_turn_settled")).toBe(true)
    expect(team.state).toBe("closed")
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("AgentTeam bounds shutdown when interruption never settles and still disposes the owner", async () => {
  const manager = SessionManager.inMemory("/work", "root-session")
  let owner: HangingInterruptSession | undefined
  const team = await AgentTeam.create({
    paths: new ZiPaths("/work", "/agent"),
    rootSessionManager: manager,
    createSession: request => {
      owner = new HangingInterruptSession(request.sessionManager)
      return Promise.resolve(owner)
    },
    turnTimeoutMs: 10_000,
    shutdownTimeoutMs: 20
  })
  await team.bindRoot(new RootMailbox(manager))
  await team.spawn({ sender: rootAgentPath, taskName: "research", message: "long", spec: spawnSpec("none") })

  let shutdownError: unknown
  try {
    await team.shutdown()
  } catch (cause) {
    shutdownError = cause
  }
  expect(String(shutdownError)).toContain("timed out")
  expect(owner?.disposed).toBe(true)
  expect(team.state).toBe("closed")
})

function assistant(text: string) {
  return {
    role: "assistant" as const,
    content: [{ type: "text" as const, text }],
    api: "test",
    provider: "test",
    model: "model",
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    },
    stopReason: "stop" as const,
    timestamp: 2
  }
}

function deferred<Value>() {
  let resolve!: (value: Value | PromiseLike<Value>) => void
  let reject!: (cause?: unknown) => void
  const promise = new Promise<Value>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

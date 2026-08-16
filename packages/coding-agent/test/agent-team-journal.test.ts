import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  maxAgentRecords,
  replayAgentTeamJournal,
  type AgentTeamEntry,
  type AgentTeamEntryData
} from "../src/agent-team/journal.js"
import { parseAgentPath, rootAgentPath } from "../src/agent-team/path.js"
import type { AgentTurnResult } from "../src/agent-team/result.js"
import { ZiPaths } from "../src/paths.js"
import { SessionManager } from "../src/session-manager.js"

const research = parseAgentPath("/root/research")
const review = parseAgentPath("/root/review")
const execution = { model: { provider: "test", modelId: "model" }, thinkingLevel: "medium" } as const
const completed: AgentTurnResult = {
  status: "completed",
  durationMs: 12,
  text: "done",
  originalBytes: 4,
  omittedBytes: 0,
  truncated: false
}

function entries(...data: readonly AgentTeamEntryData[]): AgentTeamEntry[] {
  const result: AgentTeamEntry[] = []
  for (let index = 0; index < data.length; index++) {
    result.push({
      ...data[index]!,
      id: `entry-${index}`,
      parentId: index === 0 ? null : `entry-${index - 1}`,
      timestamp: new Date(index * 1_000).toISOString()
    })
  }
  return result
}

function completionIdentity(path: string, turn: number): string {
  return `${path}\0${turn}`
}

function spawn(
  path = research,
  operationId = "spawn-1",
  parentPath = rootAgentPath,
  parentSessionId = "root-session",
  generation = 1
): AgentTeamEntryData[] {
  return [
    {
      type: "agent_spawn_reserved",
      operationId,
      path,
      parentPath,
      sessionId: `session-${operationId}`,
      parentSessionId,
      parentEntryId: "parent-entry",
      generation,
      taskName: path.slice(path.lastIndexOf("/") + 1),
      agentType: "default",
      forkTurns: "all",
      execution
    },
    { type: "agent_spawn_committed", operationId }
  ]
}

test("agent-team journal restores committed records and incomplete reservations", () => {
  const state = replayAgentTeamJournal(
    entries(...spawn(), {
      type: "agent_spawn_reserved",
      operationId: "spawn-2",
      path: review,
      parentPath: rootAgentPath,
      sessionId: "session-spawn-2",
      parentSessionId: "root-session",
      parentEntryId: "parent-entry",
      generation: 1,
      taskName: "review",
      agentType: "explorer",
      forkTurns: 2,
      execution
    })
  )

  expect(state.records.get(research)).toEqual({
    path: research,
    parentPath: rootAgentPath,
    sessionId: "session-spawn-1",
    parentSessionId: "root-session",
    parentEntryId: "parent-entry",
    generation: 1,
    taskName: "research",
    agentType: "default",
    forkTurns: "all",
    execution,
    nextTurn: 1,
    status: "not_started"
  })
  expect(state.spawnReservations.get("spawn-2")).toMatchObject({ path: review, forkTurns: 2 })
  expect(state.records.has(review)).toBe(false)
})

test("agent-team journal restores turns, pending mail, and acknowledged completion", () => {
  const state = replayAgentTeamJournal(
    entries(
      ...spawn(),
      {
        type: "agent_mail_queued",
        mailId: "mail-1",
        sender: rootAgentPath,
        target: research,
        kind: "message",
        text: "context"
      },
      { type: "agent_mail_delivered", mailId: "mail-1", targetEntryId: "child-mail-1" },
      { type: "agent_turn_reserved", operationId: "turn-1", path: research, turn: 1, mailId: "task-1" },
      { type: "agent_turn_started", operationId: "turn-1", inputEntryId: "child-task-1" },
      { type: "agent_turn_settled", operationId: "turn-1", path: research, turn: 1, result: completed }
    )
  )

  expect(state.records.get(research)).toMatchObject({ nextTurn: 2, status: "completed" })
  expect(state.pendingMail.size).toBe(0)
  expect(state.deliveredMail.get("mail-1")).toBe("child-mail-1")
  expect(state.pendingTurns.size).toBe(0)
  expect(state.pendingCompletions.get(completionIdentity(research, 1))).toMatchObject({ result: completed })

  const delivered = replayAgentTeamJournal(
    entries(
      ...spawn(),
      { type: "agent_turn_reserved", operationId: "turn-1", path: research, turn: 1, mailId: "task-1" },
      { type: "agent_turn_settled", operationId: "turn-1", path: research, turn: 1, result: completed },
      { type: "agent_completion_delivered", path: research, turn: 1, targetEntryId: "root-completion-1" }
    )
  )
  expect(delivered.pendingCompletions.size).toBe(0)
  expect(delivered.deliveredCompletions.get(completionIdentity(research, 1))).toBe("root-completion-1")
})

test("agent-team journal keeps reserved and started turns recoverable", () => {
  const reserved = replayAgentTeamJournal(
    entries(...spawn(), {
      type: "agent_turn_reserved",
      operationId: "turn-1",
      path: research,
      turn: 1,
      mailId: "task-1"
    })
  )
  expect(reserved.pendingTurns.get("turn-1")).toMatchObject({ stage: "reserved", path: research, turn: 1 })

  const started = replayAgentTeamJournal(
    entries(
      ...spawn(),
      { type: "agent_turn_reserved", operationId: "turn-1", path: research, turn: 1, mailId: "task-1" },
      { type: "agent_turn_started", operationId: "turn-1", inputEntryId: "child-task-1" }
    )
  )
  expect(started.pendingTurns.get("turn-1")).toMatchObject({ stage: "started", inputEntryId: "child-task-1" })
})

test("agent-team journal rejects invalid graph, turn, mail, and delivery transitions", () => {
  const invalid: readonly AgentTeamEntryData[][] = [
    [{ type: "agent_spawn_committed", operationId: "missing" }],
    [
      {
        type: "agent_spawn_reserved",
        operationId: "spawn-1",
        path: research,
        parentPath: rootAgentPath,
        sessionId: "session-1",
        parentSessionId: "root-session",
        parentEntryId: "parent-entry",
        generation: 1,
        taskName: "wrong",
        agentType: "default",
        forkTurns: "all",
        execution
      }
    ],
    [...spawn(), { type: "agent_turn_started", operationId: "missing", inputEntryId: "input" }],
    [...spawn(), { type: "agent_turn_reserved", operationId: "spawn-1", path: research, turn: 1, mailId: "task-1" }],
    [...spawn(), { type: "agent_turn_reserved", operationId: "turn-1", path: research, turn: 2, mailId: "task-1" }],
    [...spawn(), { type: "agent_mail_delivered", mailId: "missing", targetEntryId: "input" }],
    [...spawn(), { type: "agent_completion_delivered", path: research, turn: 1, targetEntryId: "completion" }]
  ]

  for (const candidate of invalid) expect(() => replayAgentTeamJournal(entries(...candidate))).toThrow()
})

test("agent-team journal bounds durable records across recursive branches", () => {
  const branchA = parseAgentPath("/root/branch_a")
  const branchB = parseAgentPath("/root/branch_b")
  const data: AgentTeamEntryData[] = [...spawn(branchA, "branch-a"), ...spawn(branchB, "branch-b")]
  for (let index = 0; index < (maxAgentRecords - 2) / 2; index++) {
    data.push(
      ...spawn(parseAgentPath(`${branchA}/leaf_${index}`), `a-${index}`, branchA, "session-branch-a", 2),
      ...spawn(parseAgentPath(`${branchB}/leaf_${index}`), `b-${index}`, branchB, "session-branch-b", 2)
    )
  }
  expect(replayAgentTeamJournal(entries(...data)).records.size).toBe(maxAgentRecords)

  const overflow = parseAgentPath(`${branchB}/overflow`)
  expect(() =>
    replayAgentTeamJournal(
      entries(...data, {
        type: "agent_spawn_reserved",
        operationId: "spawn-overflow",
        path: overflow,
        parentPath: branchB,
        sessionId: "session-overflow",
        parentSessionId: "session-branch-b",
        parentEntryId: "parent-entry",
        generation: 2,
        taskName: "overflow",
        agentType: "default",
        forkTurns: "all",
        execution
      })
    )
  ).toThrow(`Agent tree cannot exceed ${maxAgentRecords} records`)
})

test("SessionManager critical-appends and restores valid agent-team evidence", async () => {
  const root = await mkdtemp(join(tmpdir(), "zi-agent-team-journal-"))
  const paths = new ZiPaths(join(root, "project"), join(root, "agent"))
  try {
    const session = SessionManager.create(paths)
    for (const entry of spawn()) session.appendAgentTeam(entry)

    const restored = SessionManager.open(session.file!)
    expect(restored.agentTeamEntries()).toHaveLength(2)
    expect(replayAgentTeamJournal(restored.agentTeamEntries()).records.get(research)).toMatchObject({
      sessionId: "session-spawn-1",
      status: "not_started"
    })

    const before = restored.entries().length
    expect(() => restored.appendAgentTeam({ type: "agent_spawn_committed", operationId: "missing" })).toThrow(
      "Unknown agent spawn operation"
    )
    expect(restored.entries()).toHaveLength(before)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

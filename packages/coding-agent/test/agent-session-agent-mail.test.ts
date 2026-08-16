import { expect, test } from "bun:test"

import { Type, type Context } from "@earendil-works/pi-ai"

import type { AgentMailInput } from "../src/agent-team/mail.js"
import { parseAgentPath, rootAgentPath } from "../src/agent-team/path.js"
import { createAgentTeamSessionOwner } from "../src/agent-team/session.js"
import {
  createModels,
  createTestAgentRuntime as createAgentRuntime,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall
} from "../src/testing.js"

const noParameters = Type.Object({})
const research = parseAgentPath("/root/research")

function mail(deliveryId: string, kind: "message" | "task" = "message"): AgentMailInput {
  return { deliveryId, sender: rootAgentPath, target: research, kind, text: `text:${deliveryId}` }
}

function completion(deliveryId: string): AgentMailInput {
  return { deliveryId, sender: research, target: rootAgentPath, kind: "completion", text: `text:${deliveryId}` }
}

test("agent turn admission commits child and root evidence before starting the provider", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const order: string[] = []
  faux.setResponses([
    () => {
      order.push("provider")
      return fauxAssistantMessage("done")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  const admission = session.startAgentTurn(mail("task-1", "task"), entry => {
    order.push("root")
    expect(entry.type).toBe("custom_message")
    expect(session.sessionManager.entries().filter(candidate => candidate.type === "custom_message")).toHaveLength(1)
    expect(faux.state.callCount).toBe(0)
  })
  expect(order).toEqual(["root"])

  await admission.settled
  expect(order).toEqual(["root", "provider"])
  expect(session.sessionManager.activeMessages()).toContainEqual(
    expect.objectContaining({
      role: "custom",
      customType: "zi.agent-task.v1",
      content: "Agent task from /root:\ntext:task-1"
    })
  )
  session.dispose()
})

test("the production AgentTeam session adapter folds one settled AgentSession result", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("adapter result")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  const owner = createAgentTeamSessionOwner(session)

  const admission = owner.startTurn(mail("adapter-task", "task"), () => {})
  const result = await admission.settled
  expect(result).toMatchObject({ status: "completed", text: "adapter result", originalBytes: 14 })
  await owner.dispose()
})

test("a failed root turn commit leaves durable child input without starting a provider effect", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  faux.setResponses([fauxAssistantMessage("must not run")])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  expect(() =>
    session.startAgentTurn(mail("task-failed", "task"), () => {
      throw new Error("root journal full")
    })
  ).toThrow("root journal full")
  expect(faux.state.callCount).toBe(0)
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)
  session.dispose()
})

test("idle agent mail appends idempotently by durable delivery identity", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })

  const first = session.admitAgentMail(mail("mail-1"), "append")
  const duplicate = session.admitAgentMail(mail("mail-1"), "append")

  expect(first.duplicate).toBe(false)
  expect(duplicate).toEqual({ entry: first.entry, duplicate: true, publication: "append" })
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)
  expect(session.sessionManager.activeMessages().filter(message => message.role === "custom")).toHaveLength(1)
  session.dispose()
})

test("running agent mail is durable before it publishes at the next provider boundary", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const boundary = deferred<void>()
  const release = deferred<void>()
  const contexts: Context[] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-agent-mail" }), { stopReason: "toolUse" }),
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("continued")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        boundary.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await boundary.promise
  const admission = session.admitAgentMail(mail("mail-running"), "boundary")
  expect(admission).toMatchObject({ duplicate: false, publication: "boundary" })
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)

  release.resolve()
  await run
  expect(contexts).toHaveLength(1)
  expect(contexts[0]!.messages).toContainEqual(
    expect.objectContaining({
      role: "user",
      content: expect.arrayContaining([expect.objectContaining({ text: expect.stringContaining("mail-running") })])
    })
  )
  expect(session.sessionManager.entries().filter(entry => entry.type === "custom_message")).toHaveLength(1)
  session.dispose()
})

test("agent activity wait returns immediately for completion mail already pending at the provider boundary", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const toolStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-before-agent-wait" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("continued")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        toolStarted.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await toolStarted.promise
  session.admitAgentMail(completion("completion-before-wait"), "boundary")
  expect(await session.waitForAgentActivity(1_000)).toBe("mailbox")

  release.resolve()
  await run
  session.dispose()
})

test("agent activity wait wakes when completion mail arrives after admission", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const toolStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-after-agent-wait" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("continued")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        toolStarted.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await toolStarted.promise
  const waiting = session.waitForAgentActivity(1_000)
  session.admitAgentMail(completion("completion-after-wait"), "boundary")
  expect(await waiting).toBe("mailbox")

  release.resolve()
  await run
  session.dispose()
})

test("agent activity wait wakes when user input is steered into the active run", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const toolStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-agent-wait-steer" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("continued")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        toolStarted.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await toolStarted.promise
  const waiting = session.waitForAgentActivity(1_000)
  session.steer("new user direction")
  expect(await waiting).toBe("steered")

  release.resolve()
  await run
  session.dispose()
})

test("agent activity wait wakes for custom input steered into the active run", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const toolStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-agent-wait-custom-steer" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("continued")
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        toolStarted.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await toolStarted.promise
  const waiting = session.waitForAgentActivity(1_000)
  session.sendCustomMessage(
    { customType: "test.steer", content: "new custom direction", display: false },
    { type: "steer" }
  )
  expect(await waiting).toBe("steered")
  expect(await session.waitForAgentActivity(1_000)).toBe("steered")

  release.resolve()
  await run
  session.dispose()
})

test("agent activity wait owns cancellation, timeout, and disposal cleanup", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const toolStarted = deferred<void>()
  const release = deferred<void>()
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-agent-wait-cleanup" }), { stopReason: "toolUse" })
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        toolStarted.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await toolStarted.promise
  const controller = new AbortController()
  const cancelled = session.waitForAgentActivity(1_000, controller.signal)
  controller.abort(new Error("cancelled agent wait"))
  expect(String(await rejectionOf(cancelled))).toContain("cancelled agent wait")
  expect(await session.waitForAgentActivity(1)).toBe("timed_out")

  const disposing = session.waitForAgentActivity(1_000)
  session.dispose()
  expect(String(await rejectionOf(disposing))).toContain("disposed during an agent activity wait")
  release.resolve()
  await run
  await session.waitForIdle()
})

test("interruption retains committed agent mail for the next admitted turn", async () => {
  const models = createModels()
  const faux = fauxProvider()
  models.setProvider(faux.provider)
  const toolStarted = deferred<void>()
  const release = deferred<void>()
  const contexts: Context[] = []
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("hold", {}, { id: "hold-agent-mail-interrupt" }), { stopReason: "toolUse" }),
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("interrupted continuation")
    },
    (context: Context) => {
      contexts.push(context)
      return fauxAssistantMessage("resumed")
    }
  ])
  const { session } = await createAgentRuntime({ cwd: "/work", models, session: { type: "new", persist: false } })
  session.setActiveTools([
    {
      name: "hold",
      label: "hold",
      description: "Wait for release",
      parameters: noParameters,
      async execute() {
        toolStarted.resolve()
        await release.promise
        return { content: [{ type: "text" as const, text: "released" }], details: undefined }
      }
    }
  ])

  const run = session.prompt("start")
  await toolStarted.promise
  const interrupted = session.abort()
  session.admitAgentMail(mail("mail-interrupted"), "boundary")
  release.resolve()
  await interrupted
  await run

  await session.startAgentTurn(mail("resume-task", "task"), () => {}).settled
  expect(contexts.some(context => JSON.stringify(context.messages).includes("mail-interrupted"))).toBe(true)
  expect(
    session.sessionManager
      .entries()
      .filter(entry => entry.type === "custom_message" && entry.customType === "zi.agent-message.v1")
  ).toHaveLength(1)
  session.dispose()
})

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise
  } catch (cause) {
    return cause
  }
  throw new Error("Expected rejection")
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

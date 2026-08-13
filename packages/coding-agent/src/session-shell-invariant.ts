import type { InvariantContext, InvariantRegistry } from "@with-zi/invariants"

import type { ShellTaskOutcome } from "./session-shell.js"
import type { BackgroundTaskOrigin, BackgroundTaskResultInput } from "./shell-result.js"

const owner = "@with-zi/coding-agent/session-shell"

type SessionShellObservation =
  | { readonly type: "task_introduced"; readonly taskId: string }
  | {
      readonly type: "background_owned"
      readonly taskId: string
      readonly origin: BackgroundTaskOrigin
      readonly startedAt: number
    }
  | {
      readonly type: "task_settled"
      readonly taskId: string
      readonly outcome: ShellTaskOutcome
      readonly completedAt: number
      readonly outputBytes: number
    }
  | { readonly type: "background_result"; readonly result: BackgroundTaskResultInput }
  | { readonly type: "disposed" }

type TaskState =
  | { readonly type: "foreground" }
  | { readonly type: "background"; readonly origin: BackgroundTaskOrigin; readonly startedAt: number }
  | { readonly type: "settled_foreground" }
  | { readonly type: "awaiting_result"; readonly expected: BackgroundTaskResultInput }
  | { readonly type: "result_recorded" }

export class SessionShellInvariant {
  readonly #dispose: () => void
  #observe: (observation: SessionShellObservation) => void = () => {}

  constructor(registry: InvariantRegistry) {
    this.#dispose = registry.register(owner, context => {
      const trace = new SessionShellTrace(context)
      this.#observe = observation => trace.observe(observation)
      return () => {
        this.#observe = () => {}
      }
    })
  }

  taskIntroduced(taskId: string): void {
    this.#observe({ type: "task_introduced", taskId })
  }

  backgroundOwned(taskId: string, origin: BackgroundTaskOrigin, startedAt: number): void {
    this.#observe({ type: "background_owned", taskId, origin, startedAt })
  }

  taskSettled(taskId: string, outcome: ShellTaskOutcome, completedAt: number, outputBytes: number): void {
    this.#observe({ type: "task_settled", taskId, outcome, completedAt, outputBytes })
  }

  backgroundResult(result: BackgroundTaskResultInput): void {
    this.#observe({ type: "background_result", result })
  }

  disposed(): void {
    this.#observe({ type: "disposed" })
  }

  dispose(): void {
    this.#dispose()
  }
}

class SessionShellTrace {
  readonly #context: InvariantContext
  readonly #tasks = new Map<string, TaskState>()
  #disposed = false

  constructor(context: InvariantContext) {
    this.#context = context
  }

  observe(observation: SessionShellObservation): void {
    this.#context.assert(!this.#disposed, `${observation.type} after shell disposal`)
    switch (observation.type) {
      case "task_introduced":
        this.#context.assert(!this.#tasks.has(observation.taskId), `task ${observation.taskId} was introduced twice`)
        this.#tasks.set(observation.taskId, { type: "foreground" })
        return
      case "background_owned": {
        const task = this.#tasks.get(observation.taskId)
        this.#context.assert(task !== undefined, `background ownership for unknown task ${observation.taskId}`)
        this.#context.assert(
          task.type === "foreground",
          `task ${observation.taskId} acquired ${observation.origin} background ownership from ${task.type}`
        )
        this.#tasks.set(observation.taskId, {
          type: "background",
          origin: observation.origin,
          startedAt: observation.startedAt
        })
        return
      }
      case "task_settled": {
        const task = this.#tasks.get(observation.taskId)
        this.#context.assert(task !== undefined, `terminal settlement for unknown task ${observation.taskId}`)
        this.#context.assert(
          task.type === "foreground" || task.type === "background",
          `task ${observation.taskId} settled from ${task.type}`
        )
        if (task.type === "foreground") {
          this.#tasks.set(observation.taskId, { type: "settled_foreground" })
          return
        }
        const expected = expectedResult(task, observation, this.#context)
        this.#tasks.set(observation.taskId, { type: "awaiting_result", expected })
        return
      }
      case "background_result": {
        const task = this.#tasks.get(observation.result.taskId)
        this.#context.assert(task !== undefined, `result for unknown task ${observation.result.taskId}`)
        this.#context.assert(
          task.type === "awaiting_result",
          `task ${observation.result.taskId} produced a background result from ${task.type}`
        )
        this.#context.assert(
          sameResult(task.expected, observation.result),
          `task ${observation.result.taskId} result does not correspond to its terminal settlement`,
          { expected: task.expected, actual: observation.result }
        )
        this.#tasks.set(observation.result.taskId, { type: "result_recorded" })
        return
      }
      case "disposed": {
        const active = taskIds(this.#tasks, "background")
        const awaiting = taskIds(this.#tasks, "awaiting_result")
        this.#context.assert(active.length === 0, "disposed shell retains active background tasks", { taskIds: active })
        this.#context.assert(awaiting.length === 0, "disposed shell has unpersisted background results", {
          taskIds: awaiting
        })
        this.#disposed = true
        return
      }
      default:
        return assertNever(observation)
    }
  }
}

function expectedResult(
  task: Extract<TaskState, { type: "background" }>,
  observation: Extract<SessionShellObservation, { type: "task_settled" }>,
  context: InvariantContext
): BackgroundTaskResultInput {
  const common = {
    taskId: observation.taskId,
    origin: task.origin,
    durationMs: Math.max(0, observation.completedAt - task.startedAt),
    outputBytes: observation.outputBytes
  } as const
  switch (observation.outcome.type) {
    case "exited":
      return observation.outcome.exitCode === 0
        ? { ...common, result: "succeeded", exitCode: 0 }
        : { ...common, result: "failed", errorCode: "exit_nonzero", exitCode: observation.outcome.exitCode }
    case "signaled":
      return { ...common, result: "failed", errorCode: "signaled", signal: observation.outcome.signal }
    case "timed_out":
      return { ...common, result: "failed", errorCode: "timed_out" }
    case "output_limit":
      return { ...common, result: "failed", errorCode: "output_limit" }
    case "failed":
      return { ...common, result: "failed", errorCode: "execution_failed" }
    case "killed":
      return { ...common, result: "cancelled", cancellationCode: "killed" }
    case "disposed":
      return { ...common, result: "cancelled", cancellationCode: "disposed" }
    case "aborted":
      return context.fail(`background task ${observation.taskId} settled as aborted`)
    default:
      return assertNever(observation.outcome)
  }
}

function sameResult(expected: BackgroundTaskResultInput, actual: BackgroundTaskResultInput): boolean {
  if (
    expected.taskId !== actual.taskId ||
    expected.origin !== actual.origin ||
    expected.result !== actual.result ||
    expected.durationMs !== actual.durationMs ||
    expected.outputBytes !== actual.outputBytes
  ) {
    return false
  }
  switch (expected.result) {
    case "succeeded":
      return actual.result === "succeeded" && actual.exitCode === expected.exitCode
    case "cancelled":
      return actual.result === "cancelled" && actual.cancellationCode === expected.cancellationCode
    case "failed":
      if (actual.result !== "failed" || actual.errorCode !== expected.errorCode) return false
      switch (expected.errorCode) {
        case "exit_nonzero":
          return actual.errorCode === "exit_nonzero" && actual.exitCode === expected.exitCode
        case "signaled":
          return actual.errorCode === "signaled" && actual.signal === expected.signal
        case "timed_out":
        case "output_limit":
        case "execution_failed":
          return true
        default:
          return assertNever(expected)
      }
    default:
      return assertNever(expected)
  }
}

function taskIds(tasks: ReadonlyMap<string, TaskState>, type: TaskState["type"]): string[] {
  const ids: string[] = []
  for (const [taskId, task] of tasks) if (task.type === type) ids.push(taskId)
  return ids
}

function assertNever(value: never): never {
  throw new Error(`Unhandled SessionShell observation: ${JSON.stringify(value)}`)
}

import type { InvariantContext, InvariantRegistry } from "@with-zi/invariants"

const owner = "@with-zi/coding-agent/subagent-supervisor"

type SubagentInvariantObservation =
  | { readonly type: "child_introduced"; readonly name: string }
  | { readonly type: "work_cycle_started"; readonly name: string; readonly workCycle: number }
  | { readonly type: "interrupt_admitted"; readonly name: string; readonly workCycle: number }
  | { readonly type: "interrupt_rejected"; readonly name: string; readonly workCycle: number }
  | { readonly type: "work_cycle_settled"; readonly name: string; readonly workCycle: number }
  | { readonly type: "durable_result"; readonly name: string; readonly workCycle: number }
  | { readonly type: "child_exited"; readonly name: string }
  | { readonly type: "shutdown_succeeded" }

type ChildLifecycle =
  | { readonly type: "idle" }
  | { readonly type: "running"; readonly workCycle: number }
  | { readonly type: "interrupting"; readonly workCycle: number }
  | { readonly type: "exited" }

interface ChildTrace {
  lifecycle: ChildLifecycle
  lastStartedCycle: number
  lastSettledCycle: number
  durableThrough: number
  readonly durableAfter: Set<number>
}

export class SubagentInvariant {
  readonly #dispose: () => void
  #accept: (observation: SubagentInvariantObservation) => void = () => {}

  constructor(registry: InvariantRegistry) {
    this.#dispose = registry.register(owner, context => {
      const trace = new SubagentTrace(context)
      this.#accept = observation => trace.accept(observation)
      return () => {
        this.#accept = () => {}
      }
    })
  }

  introduce(name: string): void {
    this.#accept({ type: "child_introduced", name })
  }

  startWork(name: string, workCycle: number): void {
    this.#accept({ type: "work_cycle_started", name, workCycle })
  }

  admitInterrupt(name: string, workCycle: number): void {
    this.#accept({ type: "interrupt_admitted", name, workCycle })
  }

  rejectInterrupt(name: string, workCycle: number): void {
    this.#accept({ type: "interrupt_rejected", name, workCycle })
  }

  settleWork(name: string, workCycle: number): void {
    this.#accept({ type: "work_cycle_settled", name, workCycle })
  }

  persistResult(name: string, workCycle: number): void {
    this.#accept({ type: "durable_result", name, workCycle })
  }

  exit(name: string): void {
    this.#accept({ type: "child_exited", name })
  }

  shutdownSucceeded(): void {
    this.#accept({ type: "shutdown_succeeded" })
  }

  dispose(): void {
    this.#dispose()
  }
}

class SubagentTrace {
  readonly #context: InvariantContext
  readonly #children = new Map<string, ChildTrace>()

  constructor(context: InvariantContext) {
    this.#context = context
  }

  accept(observation: SubagentInvariantObservation): void {
    switch (observation.type) {
      case "child_introduced":
        this.#context.assert(!this.#children.has(observation.name), `child ${observation.name} was introduced twice`)
        this.#children.set(observation.name, {
          lifecycle: { type: "idle" },
          lastStartedCycle: 0,
          lastSettledCycle: 0,
          durableThrough: 0,
          durableAfter: new Set()
        })
        return
      case "work_cycle_started": {
        const child = this.#child(observation.name, observation.type)
        this.#context.assert(child.lifecycle.type !== "exited", `work started after child ${observation.name} exited`)
        this.#context.assert(child.lifecycle.type === "idle", `child ${observation.name} already has active work`)
        this.#context.assert(
          observation.workCycle === child.lastStartedCycle + 1,
          `child ${observation.name} started cycle ${observation.workCycle}, expected ${child.lastStartedCycle + 1}`
        )
        child.lastStartedCycle = observation.workCycle
        child.lifecycle = { type: "running", workCycle: observation.workCycle }
        return
      }
      case "interrupt_admitted": {
        const child = this.#child(observation.name, observation.type)
        this.#context.assert(
          child.lifecycle.type === "running",
          `interrupt for child ${observation.name} cycle ${observation.workCycle} has no running work`
        )
        this.#context.assert(
          child.lifecycle.workCycle === observation.workCycle,
          `interrupt for child ${observation.name} cycle ${observation.workCycle} crossed active cycle ${child.lifecycle.workCycle}`
        )
        child.lifecycle = { type: "interrupting", workCycle: observation.workCycle }
        return
      }
      case "interrupt_rejected": {
        const child = this.#child(observation.name, observation.type)
        this.#context.assert(
          child.lifecycle.type === "interrupting",
          `rejected interrupt for child ${observation.name} cycle ${observation.workCycle} was not admitted`
        )
        this.#context.assert(
          child.lifecycle.workCycle === observation.workCycle,
          `rejected interrupt for child ${observation.name} cycle ${observation.workCycle} crossed active cycle ${child.lifecycle.workCycle}`
        )
        child.lifecycle = { type: "running", workCycle: observation.workCycle }
        return
      }
      case "work_cycle_settled": {
        const child = this.#child(observation.name, observation.type)
        this.#context.assert(
          child.lifecycle.type === "running" || child.lifecycle.type === "interrupting",
          `settlement for child ${observation.name} cycle ${observation.workCycle} has no active work`
        )
        this.#context.assert(
          child.lifecycle.workCycle === observation.workCycle,
          `settlement for child ${observation.name} cycle ${observation.workCycle} crossed active cycle ${child.lifecycle.workCycle}`
        )
        this.#context.assert(
          observation.workCycle === child.lastSettledCycle + 1,
          `child ${observation.name} settled cycle ${observation.workCycle}, expected ${child.lastSettledCycle + 1}`
        )
        child.lastSettledCycle = observation.workCycle
        child.lifecycle = { type: "idle" }
        return
      }
      case "durable_result": {
        const child = this.#child(observation.name, observation.type)
        this.#context.assert(
          observation.workCycle <= child.lastSettledCycle,
          `durable result for child ${observation.name} cycle ${observation.workCycle} preceded settlement`
        )
        this.#context.assert(
          observation.workCycle > child.durableThrough && !child.durableAfter.has(observation.workCycle),
          `durable result for child ${observation.name} cycle ${observation.workCycle} was observed twice`
        )
        child.durableAfter.add(observation.workCycle)
        while (child.durableAfter.delete(child.durableThrough + 1)) child.durableThrough++
        return
      }
      case "child_exited": {
        const child = this.#child(observation.name, observation.type)
        this.#context.assert(child.lifecycle.type !== "exited", `child ${observation.name} exited twice`)
        this.#context.assert(child.lifecycle.type === "idle", `child ${observation.name} exited with active work`)
        child.lifecycle = { type: "exited" }
        return
      }
      case "shutdown_succeeded":
        for (const [name, child] of this.#children) {
          this.#context.assert(child.lifecycle.type === "exited", `shutdown retained live child ${name}`)
          this.#context.assert(
            child.durableThrough === child.lastSettledCycle && child.durableAfter.size === 0,
            `shutdown left child ${name} without durable results`,
            { settledThrough: child.lastSettledCycle, durableThrough: child.durableThrough }
          )
        }
        return
      default:
        return assertNever(observation)
    }
  }

  #child(name: string, observation: SubagentInvariantObservation["type"]): ChildTrace {
    const child = this.#children.get(name)
    this.#context.assert(child !== undefined, `${observation} names unknown child ${name}`)
    return child
  }
}

function assertNever(observation: never): never {
  throw new Error(`Unhandled subagent invariant observation: ${JSON.stringify(observation)}`)
}

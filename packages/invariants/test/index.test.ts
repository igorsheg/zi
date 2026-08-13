import { expect, test } from "bun:test"

import { InvariantError, InvariantRegistry, type InvariantContext } from "../src/index.js"

test("registrations are enabled and selected by default", () => {
  const installed: string[] = []
  const registry = new InvariantRegistry()

  registry.register("@with-zi/alpha", () => {
    installed.push("alpha")
  })
  registry.register("@with-zi/beta", () => {
    installed.push("beta")
  })

  expect(installed).toEqual(["alpha", "beta"])
})

test("global, allow, and block selection is case-sensitive with block precedence", () => {
  const installed: string[] = []
  const registry = new InvariantRegistry({ allow: ["^@with-zi/", "ExactCase"], block: ["blocked$"] })

  registry.register("@with-zi/selected", () => void installed.push("selected"))
  registry.register("@with-zi/blocked", () => void installed.push("blocked"))
  registry.register("ExactCase", () => void installed.push("exact"))
  registry.register("exactcase", () => void installed.push("lowercase"))

  const disabled = new InvariantRegistry({ enabled: false })
  disabled.register("@with-zi/selected", () => void installed.push("disabled"))

  expect(installed).toEqual(["selected", "exact"])
})

test("invalid pattern sources reject registry construction", () => {
  const cases: readonly [options: ConstructorParameters<typeof InvariantRegistry>[0], message: string][] = [
    [{ allow: [""] }, "non-blank"],
    [{ allow: [" padded"] }, "surrounding whitespace"],
    [{ allow: ["same", "same"] }, "duplicate regex"],
    [{ allow: ["["] }, "invalid regex"],
    [{ block: ["blocked", "blocked"] }, "duplicate regex"]
  ]

  for (const [options, message] of cases) {
    expect(() => new InvariantRegistry(options)).toThrow(message)
  }
})

test("filtered registrations still reserve their owner", () => {
  const registry = new InvariantRegistry({ enabled: false })
  const dispose = registry.register("@with-zi/filtered", () => {
    throw new Error("filtered installer ran")
  })

  expect(() => registry.register("@with-zi/filtered", () => {})).toThrow("already registered")

  dispose()
  expect(() => registry.register("@with-zi/filtered", () => {})).not.toThrow()
})

test("context failures carry their owner and supplied details", () => {
  const registry = new InvariantRegistry()
  const details = { state: "invalid" }
  let context: InvariantContext | undefined
  registry.register("@with-zi/owner", value => {
    context = value
  })
  if (!context) throw new Error("installer did not receive its context")
  const installedContext = context

  let thrown: Error | undefined
  try {
    installedContext.fail("state mismatch", details)
  } catch (error) {
    if (error instanceof Error) thrown = error
  }

  expect(thrown).toBeInstanceOf(InvariantError)
  if (!(thrown instanceof InvariantError)) throw new Error("expected an invariant failure")
  expect(thrown.name).toBe("InvariantError")
  expect(thrown.code).toBe("INVARIANT")
  expect(thrown.owner).toBe("@with-zi/owner")
  expect(thrown.details).toBe(details)
  expect(thrown.message).toContain("state mismatch")
  expect(() => installedContext.assert(false, "assertion failed")).toThrow(InvariantError)
})

test("registration disposal runs all cleanups in reverse order once", () => {
  const events: string[] = []
  const registry = new InvariantRegistry()
  const dispose = registry.register("@with-zi/cleanup", context => {
    context.cleanup(() => events.push("first"))
    context.cleanup(() => events.push("second"))
    return () => events.push("returned")
  })

  dispose()
  dispose()

  expect(events).toEqual(["returned", "second", "first"])
})

test("failed installation rolls back cleanups and releases the owner", () => {
  const events: string[] = []
  const registry = new InvariantRegistry()

  expect(() =>
    registry.register("@with-zi/rollback", context => {
      context.cleanup(() => events.push("first"))
      context.cleanup(() => events.push("second"))
      throw new Error("install failed")
    })
  ).toThrow("install failed")

  expect(events).toEqual(["second", "first"])
  expect(() => registry.register("@with-zi/rollback", () => {})).not.toThrow()
})

test("registry disposal reverses registrations, is idempotent, and closes registration", () => {
  const events: string[] = []
  const registry = new InvariantRegistry()
  const disposeFirst = registry.register("@with-zi/first", context => {
    context.cleanup(() => events.push("first:one"))
    context.cleanup(() => events.push("first:two"))
  })
  registry.register("@with-zi/second", context => {
    context.cleanup(() => events.push("second"))
  })

  registry.dispose()
  registry.dispose()
  disposeFirst()

  expect(events).toEqual(["second", "first:two", "first:one"])
  expect(() => registry.register("@with-zi/late", () => {})).toThrow("registry is disposed")
})

import { expect, test } from "bun:test"

import {
  AgentPathError,
  childAgentPath,
  isAgentPathWithin,
  maxAgentDepth,
  parentAgentPath,
  parseAgentPath,
  resolveAgentPath,
  rootAgentPath
} from "../src/agent-team/path.js"

test("agent paths build and resolve canonical descendants", () => {
  const research = childAgentPath(rootAgentPath, "research")
  const indexes = childAgentPath(research, "indexes_2")
  const codeReview = childAgentPath(rootAgentPath, "code-review")

  expect(String(research)).toBe("/root/research")
  expect(String(indexes)).toBe("/root/research/indexes_2")
  expect(String(codeReview)).toBe("/root/code-review")
  expect(resolveAgentPath(rootAgentPath, "research/indexes_2")).toBe(indexes)
  expect(resolveAgentPath(research, "indexes_2")).toBe(indexes)
  expect(String(resolveAgentPath(indexes, "/root/review"))).toBe("/root/review")
  expect(resolveAgentPath(indexes, "/root")).toBe(rootAgentPath)
})

test("agent paths expose parent and segment-aware containment", () => {
  const research = parseAgentPath("/root/research")
  const indexes = parseAgentPath("/root/research/indexes")

  expect(parentAgentPath(rootAgentPath)).toBeUndefined()
  expect(parentAgentPath(research)).toBe(rootAgentPath)
  expect(parentAgentPath(indexes)).toBe(research)
  expect(isAgentPathWithin(indexes, research)).toBe(true)
  expect(isAgentPathWithin(research, research)).toBe(true)
  expect(isAgentPathWithin(parseAgentPath("/root/researcher"), research)).toBe(false)
})

test("agent paths reject invalid names and references with bounded errors", () => {
  for (const name of ["", "root", ".", "..", "UPPER", "2fast", "has/slash", "é"]) {
    expect(() => childAgentPath(rootAgentPath, name)).toThrow(AgentPathError)
  }

  for (const path of ["root/research", "/other/research", "/root/", "/root//research", "/root/../research"]) {
    expect(() => parseAgentPath(path)).toThrow(AgentPathError)
  }

  expect(() => resolveAgentPath(rootAgentPath, "")).toThrow("Agent reference must not be empty")
  expect(() => resolveAgentPath(rootAgentPath, "research/")).toThrow(AgentPathError)
  expect(() => childAgentPath(rootAgentPath, "a".repeat(65))).toThrow("Agent task name exceeds 64 bytes")
})

test("agent paths enforce the durable tree depth bound", () => {
  let path = rootAgentPath
  for (let depth = 1; depth < maxAgentDepth; depth++) path = childAgentPath(path, `level_${depth}`)

  expect(path.split("/")).toHaveLength(maxAgentDepth + 1)
  expect(() => childAgentPath(path, "too_deep")).toThrow(`Agent path exceeds depth ${maxAgentDepth}`)
})

import { expect, test } from "bun:test"

import {
  expandPromptTemplate,
  parseCommandArgs,
  substitutePromptArguments,
  type PromptTemplate
} from "../src/prompt-templates.js"

test("prompt arguments preserve Pi quoting, defaults, and slicing", () => {
  const argumentsList = parseCommandArgs(`Button "click handler" 'disabled support'`)
  expect(argumentsList).toEqual(["Button", "click handler", "disabled support"])
  expect(substitutePromptArguments("$1 | $2 | $@ | ${1:-fallback} | ${4:-fallback} | ${@:2:2}", argumentsList)).toBe(
    "Button | click handler | Button click handler disabled support | Button | fallback | click handler disabled support"
  )
})

test("prompt template expansion is single-pass and leaves unknown commands unchanged", () => {
  const template: PromptTemplate = {
    name: "review",
    description: "Review code",
    content: "Review $1 with $@",
    filePath: "/prompts/review.md",
    scope: "project"
  }

  expect(expandPromptTemplate('/review src/index.ts "extra care"', [template])).toBe(
    "Review src/index.ts with src/index.ts extra care"
  )
  expect(expandPromptTemplate("/unknown value", [template])).toBe("/unknown value")
  expect(substitutePromptArguments("Use $1", ["$ARGUMENTS"])).toBe("Use $ARGUMENTS")
})

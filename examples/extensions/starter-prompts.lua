return function(zi)
  local starters = {
    {
      label = "Plan",
      value = "Create a concise implementation plan for: ",
      description = "Ask Zi to plan before editing",
    },
    {
      label = "Explain",
      value = "Explain the relevant code paths and tradeoffs for: ",
      description = "Ask for codebase explanation",
    },
    {
      label = "Test",
      value = "Add meaningful behavior tests for: ",
      description = "Ask for test coverage",
    },
    {
      label = "Review",
      value = "Review this change for correctness, edge cases, and maintainability: ",
      description = "Ask for a focused review",
    },
  }

  zi.command({
    name = "starter-prompts",
    description = "Pick a starter prompt and append it to the editor.",
    handler = function(args, ctx)
      if not ctx.ui then return end

      local result = ctx.ui.pick({
        title = "Starter prompts",
        placeholder = "Choose a prompt starter...",
        items = starters,
      })

      if result and result.status == "submitted" and result.value then
        ctx.ui.paste_to_editor(result.value)
      end
    end,
  })
end

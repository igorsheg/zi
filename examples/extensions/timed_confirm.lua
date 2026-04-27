-- Timed confirmation example: timeout as part of semantic prompts.

zi.register_command({
  name = "timed",
  description = "Show a confirmation prompt that auto-cancels after 5 seconds.",
  handler = function(_, ctx)
    local result = ctx.ui.prompt({
      kind = "confirm",
      title = "Timed confirmation",
      message = "This prompt will time out in 5 seconds. Confirm?",
      timeout_ms = 5000,
    })

    if result.status == "submitted" and result.value then
      ctx.ui.notify("Confirmed by user", "info")
    elseif result.status == "timeout" then
      ctx.ui.notify("Confirmation timed out", "warning")
    else
      ctx.ui.notify("Confirmation cancelled", "info")
    end
  end,
})

zi.register_command({
  name = "timed-select",
  description = "Show a select prompt that auto-cancels after 10 seconds.",
  handler = function(_, ctx)
    local result = ctx.ui.prompt({
      kind = "select",
      title = "Pick an option",
      options = { "Option A", "Option B", "Option C" },
      timeout_ms = 10000,
    })

    if result.status == "submitted" then
      ctx.ui.notify("Selected: " .. result.value, "info")
    elseif result.status == "timeout" then
      ctx.ui.notify("Selection timed out", "warning")
    else
      ctx.ui.notify("Selection cancelled", "info")
    end
  end,
})

return function(zi)
  zi.define.command({
    name = "session-name",
    description = "Show or rename the current session.",
    input = {
      type = "object",
      properties = {
        name = { type = "string", description = "New session name. Omit to show current name." },
      },
    },
    run = function(ctx, input)
      if input and input.name and input.name ~= "" then ctx.session.rename(input.name) end
      local name = ctx.session.name() or "(unnamed)"
      if ctx.ui and ctx.ui.notify then ctx.ui.notify.show({ id = "example-session-name", message = "Session: " .. name }) end
    end,
  })
end

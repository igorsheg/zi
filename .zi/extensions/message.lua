-- Host-owned notification live-test extension.
-- Publishes a notification when the agent finishes and is ready for input.

zi.on("agent_end", function(_, ctx)
  if ctx.ui and ctx.ui.message then
    ctx.ui.message("Ready for input", { kind = "info" })
  end
end)

-- Host-owned notification live-test extension.
-- Publishes a notification when the agent finishes and is ready for input.

zi.on("agent_end", function(_, ctx)
  if ctx.ui and ctx.ui.notify then
    ctx.ui.notify("Ready for input", "info")
  end
end)

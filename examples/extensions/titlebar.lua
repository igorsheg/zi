-- Terminal title example.
-- Narrow product-equivalent slice of pi-mono titlebar-spinner.ts: extensions
-- publish host-owned title surface intents; the TUI owns terminal OSC title
-- materialization.

local idle_title = "Zi"

zi.on("session_start", function(_, ctx)
  if ctx.ui and ctx.ui.set_title then
    ctx.ui.set_title(idle_title)
  end
end)

zi.on("agent_start", function(_, ctx)
  if ctx.ui and ctx.ui.set_title then
    ctx.ui.set_title("⠋ Zi working")
  end
end)

zi.on("agent_end", function(_, ctx)
  if ctx.ui and ctx.ui.set_title then
    ctx.ui.set_title(idle_title)
  end
end)

zi.on("session_shutdown", function(_, ctx)
  if ctx.ui and ctx.ui.set_title then
    ctx.ui.set_title(idle_title)
  end
end)

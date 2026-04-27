-- Host-owned notification example.
-- Product-equivalent to pi-mono notify.ts: publish a notification when the
-- agent finishes and is ready for the next input. Zi keeps the notification as
-- a semantic UI intent; the host/TUI owns materialization.

zi.on("agent_end", function(_, ctx)
  if ctx.ui and ctx.ui.notify then
    ctx.ui.notify("Ready for input", "info")
  end
end)

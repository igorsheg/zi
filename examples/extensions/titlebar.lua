-- Status example replacing titlebar mutation.
-- Extensions publish compact semantic status; the host owns where it appears.

zi.on("session_start", function(_, ctx)
  if ctx.ui and ctx.ui.status then
    ctx.ui.status({ id = "session", text = "Zi" })
  end
end)

zi.on("agent_start", function(_, ctx)
  if ctx.ui and ctx.ui.status then
    ctx.ui.status({ id = "session", text = "⠋ Zi working" })
  end
end)

zi.on("agent_end", function(_, ctx)
  if ctx.ui and ctx.ui.status then
    ctx.ui.status({ id = "session", text = "Zi" })
  end
end)

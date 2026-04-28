return function(zi)
  zi.on("session_start", function(_, ctx)
    if not ctx.has_ui or not ctx.ui.status then return end
    ctx.ui.status({ id = "widget-demo", text = "Extension UI ready" })
  end)
end

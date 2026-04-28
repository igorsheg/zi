return function(zi)
  zi.on("session_start", function(_, ctx)
    if not ctx.has_ui or not ctx.ui.report then return end
    ctx.ui.report({
      id = "welcome",
      title = "zi coding agent",
      body = "Welcome. Extension UI is semantic and host-owned.",
      transient = true,
    })
  end)
end

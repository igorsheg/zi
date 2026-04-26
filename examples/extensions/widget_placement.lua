return function(zi)
  zi.on("session_start", function(_, ctx)
    if not ctx.has_ui then return end

    ctx.ui.set_widget("widget-above", {
      { { text = "Above editor widget", fg = "accent" } },
    }, { placement = "aboveEditor" })

    ctx.ui.set_widget("widget-below", {
      { { text = "Below editor widget", fg = "muted" } },
    }, { placement = "belowEditor" })
  end)
end

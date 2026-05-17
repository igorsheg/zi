return function(zi)
  zi.define.command({
    name = "notify-demo",
    description = "Show v4 notifications.",
    run = function(ctx, _input)
      if not (ctx.ui and ctx.ui.notify) then return end
      ctx.ui.notify.show({ id = "example-notify-info", group = "examples", level = "info", message = "Information notification" })
      ctx.ui.notify.show({ id = "example-notify-warn", group = "examples", level = "warn", message = "Warning notification" })
      ctx.ui.notify.show({ id = "example-notify-success", group = "examples", level = "success", message = "Completed notification", done = true })
    end,
  })

  zi.define.command({
    name = "notify-clear-demo",
    description = "Clear notifications from the examples group.",
    run = function(ctx, _input)
      if ctx.ui and ctx.ui.notify then ctx.ui.notify.clear_group("examples") end
    end,
  })
end

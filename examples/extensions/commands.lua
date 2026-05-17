return function(zi)
  zi.define.command({
    name = "hello",
    description = "Show a greeting from an extension command.",
    input = {
      type = "object",
      properties = {
        name = { type = "string", description = "Name to greet. Defaults to zi." },
      },
    },
    run = function(ctx, input)
      local name = input and input.name or "zi"
      if ctx.ui and ctx.ui.view then
        ctx.ui.view.set({
          id = "example-command-hello",
          slot = { kind = "overlay", width = "50%", max_height = "50%", anchor = "center", backdrop = "dim" },
          keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
          root = {
            type = "view",
            style = { chrome = { kind = "frame", title = "Hello", border = "rounded", tone = "muted" }, padding = 1 },
            children = { { type = "text", text = "Hello, " .. tostring(name) .. "." } },
          },
        })
      end
    end,
  })

  zi.define.event("ui", function(ctx, event)
    if event.view == "example-command-hello" and event.action == "close" and ctx.ui and ctx.ui.view then
      ctx.ui.view.set({ id = "example-command-hello", remove = true })
    end
  end)
end

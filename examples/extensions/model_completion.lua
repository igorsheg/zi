return function(zi)
  zi.define.command({
    name = "complete-demo",
    description = "Run a sessionless model completion and show the result.",
    input = {
      type = "object",
      properties = {
        prompt = { type = "string", description = "Prompt to complete." },
      },
    },
    run = function(ctx, input)
      local prompt = input and input.prompt or "Say hello in one short sentence."
      local result = ctx.ai.complete({ prompt = prompt, max_tokens = 200 })
      local text = result and (result.text or result.error or result.status) or "no result"
      if ctx.ui and ctx.ui.view then
        ctx.ui.view.set({
          id = "example-complete-result",
          slot = { kind = "overlay", width = "70%", max_height = "70%", anchor = "center", backdrop = "dim" },
          keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
          root = { type = "view", style = { chrome = { kind = "frame", title = "Completion", border = "rounded" }, padding = 1 }, children = { { type = "text", text = text } } },
        })
      end
    end,
  })

  zi.define.event("ui", function(ctx, event)
    if event.view == "example-complete-result" and event.action == "close" and ctx.ui and ctx.ui.view then
      ctx.ui.view.set({ id = "example-complete-result", remove = true })
    end
  end)
end

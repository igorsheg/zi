local function overlay(ctx, id, title, lines)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  local children = { { type = "text", text = title } }
  for _, line in ipairs(lines or {}) do children[#children + 1] = { type = "text", text = tostring(line) } end
  ctx.ui.render({ id = id, title = title, target = { kind = "overlay", width = "70%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "box", style = { border = true, padding = 1 }, children = children } })
end

zi.on("ui", function(event, ctx)
  if event.action == "close" and ctx and ctx.ui and ctx.ui.render then ctx.ui.render({ id = event.view, remove = true }) end
end)

zi.command({
  name = "starter-prompts",
  description = "Show starter prompts in a v3 overlay",
  handler = function(_, ctx)
    overlay(ctx, "starter-prompts", "Starter prompts", {
      "• Explain this codebase",
      "• Find a small bug and fix it",
      "• Write tests for the current change",
      "Copy one into the editor; input/select node events are deferred.",
    })
  end,
})

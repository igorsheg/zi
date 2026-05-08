local function overlay(ctx, id, title, lines)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  local children = {}
  for _, line in ipairs(lines or {}) do children[#children + 1] = { type = "text", text = tostring(line) } end
  ctx.ui.render({ id = id, target = { kind = "overlay", width = "70%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = children } })
end

zi.on("ui", function(event, ctx)
  if event.action == "close" and ctx and ctx.ui and ctx.ui.render then ctx.ui.render({ id = event.view, remove = true }) end
end)

zi.command({ name = "timed-confirm", description = "Show a v3 confirmation overlay", handler = function(_, ctx) overlay(ctx, "timed-confirm", "Confirm", { "Confirmation prompts are deferred in API v3.", "Use q/Esc to close this overlay." }) end })
zi.command({ name = "timed-select", description = "Show a v3 select overlay", handler = function(_, ctx) overlay(ctx, "timed-select", "Select", { "Selection node events are deferred in API v3.", "Option A", "Option B" }) end })

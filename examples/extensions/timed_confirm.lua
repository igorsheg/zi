local function overlay(ctx, id, title, lines)
  if not (ctx and ctx.ui and ctx.ui.view.set) then return end
  local children = {}
  for _, line in ipairs(lines or {}) do children[#children + 1] = { type = "text", text = tostring(line) } end
  ctx.ui.view.set({ id = id, slot = { kind = "overlay", width = "70%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = children } })
end

zi.define.event("ui", function(ctx, event)
  if event.action == "close" and ctx and ctx.ui and ctx.ui.view.set then ctx.ui.view.set({ id = event.view, remove = true }) end
end)

zi.define.command({ name = "timed-confirm", description = "Show a v3 confirmation overlay", run = function(ctx, _) overlay(ctx, "timed-confirm", "Confirm", { "Confirmation prompts are deferred in API v4.", "Use q/Esc to close this overlay." }) end })
zi.define.command({ name = "timed-select", description = "Show a v3 select overlay", run = function(ctx, _) overlay(ctx, "timed-select", "Select", { "Selection node events are deferred in API v4.", "Option A", "Option B" }) end })

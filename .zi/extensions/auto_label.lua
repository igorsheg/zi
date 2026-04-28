-- Semantic message auto-label example.
--
-- Labels are lightweight durable markers on session entries. This example
-- marks user messages that look like decisions or TODOs.

zi.on("message", function(event, ctx)
  local message = event.message or {}
  if message.role ~= "user" or not message.text or not message.entry_id then
    return
  end

  local label = nil
  if string.match(string.lower(message.text), "%f[%w]decision%f[%W]") then
    label = "decision"
  elseif string.match(string.lower(message.text), "%f[%w]todo%f[%W]") then
    label = "todo"
  end

  if not label then
    return
  end

  if ctx.session.label(message.entry_id, label) then
    ctx.ui.set_footer("Labeled " .. message.entry_id .. " as " .. label)
  end
end)

zi.command("labels", function(ctx, args)
  local target = tostring(args or "")
  local opts = { limit = 20 }
  if target ~= "" then
    opts.target_entry_id = target
  end

  local labels = ctx.session.labels(opts)
  if #labels == 0 then
    ctx.ui.show_panel({ title = "Labels", body = "No labels found." })
    return
  end

  local lines = {}
  for _, item in ipairs(labels) do
    table.insert(lines, string.format("%s -> %s: %s", item.entry_id, item.target_entry_id, item.label or "<cleared>"))
  end
  ctx.ui.show_panel({ title = "Labels", body = table.concat(lines, "\n") })
end)

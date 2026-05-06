local function ui_toast(ctx, text, tone)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({ id = "notice", target = { kind = "toast", anchor = "top_right", lifetime = "until_input" }, root = { type = "text", text = tostring(text or ""), style = { tone = tone or "info" } } })
end

local function ui_status(ctx, id, text, tone)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({ id = id, target = "status", root = { type = "text", text = tostring(text or ""), style = { tone = tone or "info" } } })
end

local function ui_status_spec(ctx, spec)
  if spec == nil then return end
  ui_status(ctx, spec.id or "status", spec.text or spec.title or "", spec.tone or "info")
end

local function ui_progress_spec(ctx, spec)
  if not (ctx and ctx.ui and ctx.ui.render and spec) then return end
  ctx.ui.render({ id = spec.id or "progress", target = "status", root = { type = "progress", value = spec.current and spec.total and (spec.current / spec.total) or nil, label = spec.text or spec.title or spec.status or "working" } })
end

local function ui_report(ctx, id, title, body)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({ id = id or "report", title = title, target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "box", style = { border = true, padding = 1 }, children = { { type = "text", text = tostring(title or "") }, { type = "text", text = tostring(body or "") } } } })
end

local function ui_report_spec(ctx, spec)
  ui_report(ctx, spec and spec.id or "report", spec and spec.title or "Report", spec and spec.body or "")
end

local function ui_toast(ctx, text, tone)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({
    id = "notice",
    target = { kind = "toast", anchor = "top_right", lifetime = "until_input" },
    root = { type = "text", text = tostring(text or ""), style = { tone = tone or "info" } },
  })
end

local function ui_status(ctx, id, text, tone)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({
    id = id,
    target = "status",
    root = { type = "text", text = tostring(text or ""), style = { tone = tone or "info" } },
  })
end

local function ui_report(ctx, id, title, body)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({
    id = id or "report",
    title = title,
    target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" },
    keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
    root = { type = "box", style = { border = true, padding = 1 }, children = {
      { type = "text", text = tostring(title or "") },
      { type = "text", text = tostring(body or "") },
    } },
  })
end
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
    ui_toast(ctx, "Labeled " .. message.entry_id .. " as " .. label)
  end
end)

local function preview_entry(entry)
  if not entry then
    return "<missing>"
  end
  local preview = entry.text or entry.entry_id or "<entry>"
  preview = string.gsub(preview, "\n", " ")
  if #preview > 72 then
    preview = string.sub(preview, 1, 69) .. "..."
  end
  return preview
end

zi.command({
  name = "labels",
  description = "List durable session labels.",
  handler = function(args, ctx)
    local target = tostring(args or "")
    local opts = { limit = 20 }
    if target ~= "" then
      opts.target_entry_id = target
    end

    local labels = ctx.session.labels(opts)
    if #labels == 0 then
      ui_report_spec(ctx, { title = "Labels", body = "No labels found." })
      return
    end

    local lines = {}
    for _, item in ipairs(labels) do
      table.insert(lines, string.format("%s: %s", item.label or "<cleared>", preview_entry(ctx.session.entry(item.target_entry_id))))
    end
    ui_report_spec(ctx, { title = "Labels", body = table.concat(lines, "\n") })
  end,
})

zi.command({
  name = "decisions",
  description = "List entries labelled as decisions.",
  handler = function(_, ctx)
    local entries = ctx.session.entries({ label = "decision", limit = 20 })
    if #entries == 0 then
      ui_report_spec(ctx, { title = "Decisions", body = "No decisions found." })
      return
    end

    local lines = {}
    for _, entry in ipairs(entries) do
      table.insert(lines, "- " .. preview_entry(entry))
    end
    ui_report_spec(ctx, { title = "Decisions", body = table.concat(lines, "\n") })
  end,
})

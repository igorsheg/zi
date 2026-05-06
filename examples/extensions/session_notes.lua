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
-- Semantic session notes example.
--
-- /note remember to update docs
-- /note @entry-id remember to update docs
-- /notes
--
-- Notes are stored as host-owned session custom entries with customType
-- "extension_note". They are durable session artifacts, but not raw transcript
-- mutation and not injected into the LLM context.

zi.command({
  name = "note",
  description = "Append a durable session note.",
  handler = function(args, ctx)
    local body = tostring(args or "")
    local source_entry_id = nil
    local maybe_source, rest = string.match(body, "^@([%w%-_]+)%s+(.+)$")
    if maybe_source then
      source_entry_id = maybe_source
      body = rest
    end
    if body == "" then
      ui_toast(ctx, "Usage: /note [@entry-id] <text>")
      return
    end

    local ok = ctx.session.append_note({
      kind = "manual",
      title = "Manual note",
      body = body,
      source_entry_id = source_entry_id,
    })

    if ok then
      ui_toast(ctx, "Saved session note")
    else
      ui_toast(ctx, "Failed to save session note")
    end
  end,
})

zi.command({
  name = "notes",
  description = "List durable session notes.",
  handler = function(_, ctx)
    local notes = ctx.session.notes({ kind = "manual", limit = 10 })
    if #notes == 0 then
      ui_toast(ctx, "No manual session notes")
      return
    end

    local lines = {}
    for i, note in ipairs(notes) do
      local title = note.title or note.kind or "note"
      lines[#lines + 1] = tostring(i) .. ". " .. title
      lines[#lines + 1] = note.body or ""
      lines[#lines + 1] = ""
    end

    ui_report_spec(ctx, {
      id = "session-notes",
      title = "Session notes",
      body = table.concat(lines, "\n"),
    })
  end,
})

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
-- Host-owned notification example.
-- Product-equivalent to pi-mono notify.ts: publish a notification when the
-- agent finishes and is ready for the next input. Zi keeps the notification as
-- a semantic UI intent; the host/TUI owns materialization.

zi.on("agent_end", function(_, ctx)
  if ctx.ui and ctx.ui.render then
    ui_toast(ctx, "Ready for input", { kind = "info" })
  end
end)

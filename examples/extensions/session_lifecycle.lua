local function ui_toast(ctx, text, tone)
  if not (ctx and ctx.ui and ctx.ui.notify) then return end
  local opts = { id = "notice", level = "info" }
  if type(tone) == "string" then opts.level = tone end
  if type(tone) == "table" then
    opts.level = tone.level or tone.kind or tone.tone or opts.level
    opts.id = tone.id or opts.id
    opts.group = tone.group
    opts.title = tone.title
    opts.annote = tone.annote
    opts.progress = tone.progress
    opts.done = tone.done
  end
  if opts.level == "warning" then opts.level = "warn" end
  if opts.level == "danger" then opts.level = "error" end
  ctx.ui.notify(tostring(text or ""), opts)
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
  ctx.ui.render({ id = id or "report", target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = { { type = "text", text = tostring(body or "") } } } })
end

local function ui_report_spec(ctx, spec)
  ui_report(ctx, spec and spec.id or "report", spec and spec.title or "Report", spec and spec.body or "")
end

local function ui_toast(ctx, text, tone)
  if not (ctx and ctx.ui and ctx.ui.notify) then return end
  local opts = { id = "notice", level = "info" }
  if type(tone) == "string" then opts.level = tone end
  if type(tone) == "table" then
    opts.level = tone.level or tone.kind or tone.tone or opts.level
    opts.id = tone.id or opts.id
    opts.group = tone.group
    opts.title = tone.title
    opts.annote = tone.annote
    opts.progress = tone.progress
    opts.done = tone.done
  end
  if opts.level == "warning" then opts.level = "warn" end
  if opts.level == "danger" then opts.level = "error" end
  ctx.ui.notify(tostring(text or ""), opts)
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
    target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" },
    keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
    root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = {
      { type = "text", text = tostring(body or "") },
    } },
  })
end
-- Session lifecycle hooks example.
--
-- Shows the host-owned lifecycle events that extensions can observe or block.
-- Try:
--   /new
--   /resume <path>
--   /fork <entry-id>
--
-- Events are deliberately semantic: extensions see session/binding metadata,
-- not raw TUI internals.

local function label_binding(binding)
  if type(binding) ~= "table" then
    return "unknown session"
  end
  local id = binding.session_id or "unknown"
  return string.sub(id, 1, 8)
end

local function footer(ctx, text)
  if ctx and ctx.ui and ctx.ui.render then
    ui_toast(ctx, text)
  end
end

zi.on("session_start", function(event, ctx)
  footer(ctx, "Session started (" .. tostring(event.reason or "unknown") .. "): " .. label_binding(event.binding))
end)

zi.on("session_shutdown", function(event, ctx)
  footer(ctx, "Session stopped (" .. tostring(event.reason or "unknown") .. "): " .. label_binding(event.binding))
end)

zi.on("session_before_switch", function(event, ctx)
  footer(ctx, "Switching session (" .. tostring(event.reason or "unknown") .. ")…")
  -- Return { block = true, message = "..." } to cancel the switch.
  return { block = false }
end)

zi.on("session_before_fork", function(event, ctx)
  footer(ctx, "Forking session from entry " .. tostring(event.entry_id or "unknown") .. "…")
  -- Return { block = true, message = "..." } to cancel the fork.
  return { block = false }
end)

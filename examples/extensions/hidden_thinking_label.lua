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
  ctx.ui.render({ id = id or "report", target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = { { type = "text", text = tostring(body or "") } } } })
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
    target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" },
    keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
    root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = {
      { type = "text", text = tostring(body or "") },
    } },
  })
end
-- Status label example.
-- Hidden-thinking chrome is host-owned; extensions can publish semantic status
-- instead of mutating that implementation-specific label.

local DEFAULT_LABEL = "Pondering..."
local label = DEFAULT_LABEL

local function apply_label(ctx)
  if ctx.ui and ctx.ui.render then
    ui_status_spec(ctx, { id = "thinking", text = label })
  end
end

zi.on("session_start", function(_, ctx)
  apply_label(ctx)
end)

zi.command({
  name = "thinking-label",
  description = "Set the thinking status label. Use without args to reset.",
  handler = function(args, ctx)
    local next_label = (args or ""):match("^%s*(.-)%s*$")
    if next_label == "" then
      label = DEFAULT_LABEL
      apply_label(ctx)
      if ctx.ui and ctx.ui.render then
        ui_toast(ctx, "Thinking status reset to: " .. DEFAULT_LABEL, { kind = "info" })
      end
      return
    end

    label = next_label
    apply_label(ctx)
    if ctx.ui and ctx.ui.render then
      ui_toast(ctx, "Thinking status set to: " .. label, { kind = "info" })
    end
  end,
})

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
  ctx.ui.render({ id = id, slot = "status", root = { type = "text", text = tostring(text or ""), style = { tone = tone or "info" } } })
end

local function ui_status_spec(ctx, spec)
  if spec == nil then return end
  ui_status(ctx, spec.id or "status", spec.text or spec.title or "", spec.tone or "info")
end

local function ui_progress_spec(ctx, spec)
  if not (ctx and ctx.ui and ctx.ui.render and spec) then return end
  ctx.ui.render({ id = spec.id or "progress", slot = "status", root = { type = "progress", value = spec.current and spec.total and (spec.current / spec.total) or nil, label = spec.text or spec.title or spec.status or "working" } })
end

local function ui_report(ctx, id, title, body)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({ id = id or "report", slot = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = { { type = "text", text = tostring(body or "") } } } })
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
    slot = "status",
    root = { type = "text", text = tostring(text or ""), style = { tone = tone or "info" } },
  })
end

local function ui_report(ctx, id, title, body)
  if not (ctx and ctx.ui and ctx.ui.render) then return end
  ctx.ui.render({
    id = id or "report",
    slot = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" },
    keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
    root = { type = "view", style = { chrome = { kind = "frame", title = title, border = "rounded", tone = "muted" }, padding = 1 }, children = {
      { type = "text", text = tostring(body or "") },
    } },
  })
end
-- Rich model API + ctx.ai.complete model override example.
--
-- /models       show visible model catalog
-- /ask-model <model-ref> :: <prompt>
--
-- model-ref can be a model id, provider/model id, or a model table returned by
-- ctx.models.list(). ctx.ai.complete stays sessionless: it does not mutate the
-- transcript or run tools.

zi.command({
  name = "models",
  description = "Show visible model catalog.",
  handler = function(_, ctx)
    local models = ctx.models and ctx.models.list and ctx.models.list() or {}
    if #models == 0 then
      ui_toast(ctx, "No model catalog available")
      return
    end

    local lines = {}
    local current = ctx.models.current()
    local lookup = ctx.models.get(current)
    lines[#lines + 1] = "Current: " .. current.provider .. "/" .. current.id
    if lookup then
      lines[#lines + 1] = "Lookup: " .. lookup.provider .. "/" .. lookup.id
    end
    lines[#lines + 1] = ""
    for i, model in ipairs(models) do
      if i > 20 then
        lines[#lines + 1] = "…"
        break
      end
      local marker = model.id == current.id and model.provider == current.provider and "*" or " "
      lines[#lines + 1] = string.format(
        "%s %s/%s  ctx=%s max=%s reasoning=%s",
        marker,
        model.provider or "?",
        model.id or "?",
        tostring(model.context_window or "?"),
        tostring(model.max_tokens or "?"),
        tostring(model.reasoning or false)
      )
    end

    ui_report_spec(ctx, {
      id = "models",
      title = "Model catalog",
      body = table.concat(lines, "\n"),
    })
  end,
})

zi.command({
  name = "ask-model",
  description = "Run a sessionless completion with a selected model.",
  handler = function(args, ctx)
    local raw = tostring(args or "")
    local sep = string.find(raw, "::", 1, true)
    if not sep then
      ui_toast(ctx, "Usage: /ask-model <model> :: <prompt>")
      return
    end
    local model_ref = string.gsub(string.sub(raw, 1, sep - 1), "^%s*(.-)%s*$", "%1")
    local prompt = string.gsub(string.sub(raw, sep + 2), "^%s*(.-)%s*$", "%1")
    if model_ref == "" or prompt == "" then
      ui_toast(ctx, "Usage: /ask-model <model> :: <prompt>")
      return
    end

    ui_toast(ctx, "Completing with " .. model_ref .. "…")
    local result = ctx.ai.complete({
      model = model_ref,
      prompt = prompt,
      max_tokens = 800,
      reasoning = "low",
    })

    if result.status == "completed" then
      ui_report_spec(ctx, { id = "ask-model", title = "AI completion: " .. model_ref, body = result.text })
    else
      ui_toast(ctx, "AI completion failed: " .. tostring(result.error or result.status))
    end
  end,
})

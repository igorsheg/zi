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
-- Summarize example: use session messages + ctx.ai.complete to produce a panel.
--
-- Usage:
--   /summarize       summarize last 50 non-tool messages
--   /summarize 100   summarize last 100 non-tool messages

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function parse_limit(args)
  local n = tonumber(trim(args))
  if not n or n < 1 then return 50 end
  if n > 200 then return 200 end
  return math.floor(n)
end

local function serialize_messages(messages)
  local lines = {}
  for _, msg in ipairs(messages) do
    local role = msg.role or "message"
    local text = tostring(msg.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then
      lines[#lines + 1] = role .. ": " .. text
    end
  end
  return table.concat(lines, "\n\n")
end


zi.command({
  name = "summarize",
  description = "Summarize recent session messages",
  handler = function(args, ctx)
    local limit = parse_limit(args)
    local messages = ctx.session.messages({ limit = limit, include_tools = false })
    if #messages == 0 then
      ui_toast(ctx, "No messages to summarize", {})
      return
    end

    ui_toast(ctx, "Generating summary…", {})
    local result = ctx.ai.complete({
      system_prompt = "You summarize coding-agent sessions. Be concise, concrete, and preserve decisions, files, and next steps.",
      prompt = "Summarize this conversation for handoff. Include: key decisions, files/areas discussed, current state, and next steps.\n\n" .. serialize_messages(messages),
      max_tokens = 1800,
    })

    if result.status ~= "completed" then
      ui_toast(ctx, "Summary failed: " .. tostring(result.error or result.status), {})
      return
    end

    ui_report_spec(ctx, {
      id = "summary",
      title = "Session summary",
      body = result.text ~= "" and result.text or "No summary",
      transient = true,
    })
  end,
})

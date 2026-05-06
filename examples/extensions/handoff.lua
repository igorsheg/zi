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
-- Handoff example: summarize recent visible session messages into a panel.
--
-- Usage:
--   /handoff          show last 30 messages
--   /handoff 10       show last 10 messages

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function parse_limit(args)
  local n = tonumber(trim(args))
  if not n or n < 1 then return 30 end
  if n > 100 then return 100 end
  return math.floor(n)
end

local function shorten(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

local function line_for(msg)
  local role = msg.role or "message"
  if role == "tool_call" then
    return "tool call " .. tostring(msg.tool_name or "?") .. " #" .. tostring(msg.tool_call_id or "")
  end
  if role == "tool_result" then
    local text = ""
    if type(msg.content) == "table" and msg.content[1] then text = msg.content[1].text or "" end
    return "tool result " .. tostring(msg.tool_name or "?") .. ": " .. shorten(text, 120)
  end
  return role .. ": " .. shorten(msg.text or "", 140)
end

zi.command({
  name = "handoff",
  description = "Show a compact handoff of recent session messages",
  handler = function(args, ctx)
    local limit = parse_limit(args)
    local info = ctx.session.info()
    local messages = ctx.session.messages({ limit = limit, include_tools = true })
    local lines = {
      "Session" .. (info.name and (": " .. info.name) or ""),
      "cwd: " .. tostring(info.cwd or "?"),
      "recent messages: " .. tostring(#messages),
      "",
    }

    if #messages == 0 then
      lines[#lines + 1] = "No messages yet"
    else
      for _, msg in ipairs(messages) do
        lines[#lines + 1] = line_for(msg)
      end
    end

    ui_report_spec(ctx, {
      id = "handoff",
      title = "Session handoff",
      body = table.concat(lines, "\n"),
      transient = true,
    })
  end,
})

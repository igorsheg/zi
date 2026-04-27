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
    return {
      { text = "tool call ", fg = "muted" },
      { text = msg.tool_name or "?", fg = "accent" },
      { text = " #" .. tostring(msg.tool_call_id or ""), fg = "muted" },
    }
  end
  if role == "tool_result" then
    local text = ""
    if type(msg.content) == "table" and msg.content[1] then text = msg.content[1].text or "" end
    return {
      { text = "tool result ", fg = msg.is_error and "error" or "success" },
      { text = msg.tool_name or "?", fg = "accent" },
      { text = ": " .. shorten(text, 120), fg = "text" },
    }
  end
  return {
    { text = role .. ": ", fg = role == "user" and "accent" or "success" },
    { text = shorten(msg.text or "", 140), fg = "text" },
  }
end

zi.register_command({
  name = "handoff",
  description = "Show a compact handoff of recent session messages",
  handler = function(args, ctx)
    local limit = parse_limit(args)
    local info = ctx.session.info()
    local messages = ctx.session.messages({ limit = limit, include_tools = true })
    local lines = {
      {
        { text = "Session", fg = "accent" },
        { text = info.name and (": " .. info.name) or "", fg = "text" },
      },
      { { text = "cwd: " .. tostring(info.cwd or "?"), fg = "muted" } },
      { { text = "recent messages: " .. tostring(#messages), fg = "muted" } },
      { { text = "", fg = "muted" } },
    }

    if #messages == 0 then
      lines[#lines + 1] = { { text = "No messages yet", fg = "muted", dim = true } }
    else
      for _, msg in ipairs(messages) do
        lines[#lines + 1] = line_for(msg)
      end
    end

    ctx.ui.show_panel({
      id = "handoff",
      title = "Session handoff",
      lines = lines,
      transient = true,
    })
  end,
})

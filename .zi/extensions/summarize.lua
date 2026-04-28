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


zi.register_command({
  name = "summarize",
  description = "Summarize recent session messages",
  handler = function(args, ctx)
    local limit = parse_limit(args)
    local messages = ctx.session.messages({ limit = limit, include_tools = false })
    if #messages == 0 then
      ctx.ui.set_footer("No messages to summarize", { lifetime = "until_input" })
      return
    end

    ctx.ui.set_footer("Generating summary…", { lifetime = "until_input" })
    local result = ctx.ai.complete({
      system_prompt = "You summarize coding-agent sessions. Be concise, concrete, and preserve decisions, files, and next steps.",
      prompt = "Summarize this conversation for handoff. Include: key decisions, files/areas discussed, current state, and next steps.\n\n" .. serialize_messages(messages),
      max_tokens = 1800,
    })

    if result.status ~= "completed" then
      ctx.ui.set_footer("Summary failed: " .. tostring(result.error or result.status), { lifetime = "until_input" })
      return
    end

    ctx.ui.show_panel({
      id = "summary",
      title = "Session summary",
      body = result.text ~= "" and result.text or "No summary",
      transient = true,
    })
  end,
})

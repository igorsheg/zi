-- BTW side chat: a small extension-owned side-channel conversation.
--
-- /btw           open the side chat overlay
-- /btw <text>    ask immediately
-- /btw reset     clear the side thread
-- /btw inject    summarize and send the side thread into the main chat

local VIEW_ID = "btw"
local INPUT_ID = "btw-question"
local TURN_KIND = "btw.turn"
local RESET_KIND = "btw.reset"

local SYSTEM_PROMPT = table.concat({
  "You are BTW, a side-channel assistant embedded in the user's coding agent.",
  "You have access to the main conversation context when it is provided.",
  "Help with focused questions, planning, and quick explorations.",
  "Be direct and practical.",
}, " ")

local SUMMARY_PROMPT = "Summarize this side conversation for handoff into the main conversation. Keep key decisions, findings, risks, and next actions. Output only the summary."

local thread = {}
local draft = ""
local status = "Ready"
local pending_question = nil
local pending_answer = ""
local pending_error = nil
local pending_tools = {}
local busy = false
local side = nil

local function has_ui(ctx)
  return ctx and ctx.ui and ctx.ui.render
end

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function first_line(s)
  s = tostring(s or "")
  return (s:match("([^\n]*)") or s)
end

local function load_thread(ctx)
  thread = {}
  if not (ctx and ctx.session and ctx.session.artifacts) then return end
  local artifacts = ctx.session.artifacts({ limit = 500 }) or {}
  local start = 1
  for i, item in ipairs(artifacts) do
    if item.kind == RESET_KIND then start = i + 1 end
  end
  for i = start, #artifacts do
    local item = artifacts[i]
    if item.kind == TURN_KIND and item.data and item.data.question and item.data.answer then
      table.insert(thread, item.data)
    end
  end
end

local function transcript_text()
  local out = {}
  if #thread == 0 and not pending_question then
    table.insert(out, "_No BTW messages yet. Type a question below._")
  end
  local first = math.max(1, #thread - 5)
  for i = first, #thread do
    local item = thread[i]
    table.insert(out, "**You:** " .. first_line(item.question))
    table.insert(out, "")
    table.insert(out, item.answer or "")
    table.insert(out, "")
    table.insert(out, "---")
  end
  if pending_question then
    table.insert(out, "**You:** " .. first_line(pending_question))
    table.insert(out, "")
    if pending_error then
      table.insert(out, "❌ " .. pending_error)
    else
      for _, tool in ipairs(pending_tools) do
        local icon = tool.status == "done" and "✓" or (tool.status == "error" and "✗" or "⚙")
        local suffix = tool.args and tool.args ~= "" and (" " .. tool.args) or ""
        table.insert(out, icon .. " `" .. tostring(tool.name or "tool") .. "`" .. suffix)
      end
      if pending_answer ~= "" then
        table.insert(out, pending_answer)
      elseif #pending_tools == 0 then
        table.insert(out, "…")
      end
    end
  end
  return table.concat(out, "\n")
end

local function format_tool_args(name, input)
  if type(input) ~= "table" then return "" end
  if name == "bash" and type(input.command) == "string" then return input.command:gsub("\n.*", "") end
  if (name == "read" or name == "write" or name == "edit") and type(input.path) == "string" then return input.path end
  for _, value in pairs(input) do
    if type(value) == "string" then return value:gsub("\n.*", "") end
  end
  return ""
end

local function find_tool(id)
  for _, tool in ipairs(pending_tools) do
    if tool.id == id then return tool end
  end
  return nil
end

local function render(ctx)
  if not has_ui(ctx) then return end
  ctx.ui.render({
    id = VIEW_ID,
    target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "top_center", backdrop = "dim" },
    focus = true,
    keys = {
      { key = "escape", action = "close" },
      { key = "ctrl+c", action = "close" },
    },
    root = {
      type = "view",
      style = { chrome = { kind = "frame", title = "BTW side chat", border = "rounded", tone = "muted" }, padding = 1, gap = 1 },
      children = {
        { type = "text", text = "Separate side conversation. Enter submits · Esc closes · /btw inject summarizes into main.", style = { tone = "muted", dim = true } },
        { type = "text", text = transcript_text(), format = "markdown", style = { height = "fill" } },
        { type = "separator" },
        { type = "text", text = status, style = { tone = busy and "warning" or "muted" } },
        { type = "input", id = INPUT_ID, value = draft, placeholder = "Ask BTW…", on_submit = "submit", on_change = "change", style = { tone = "accent" } },
      },
    },
  })
end

local function close_overlay(ctx)
  if has_ui(ctx) then ctx.ui.render({ id = VIEW_ID, remove = true }) end
end

local function ensure_side(ctx)
  if side then return side end
  local context = nil
  if ctx.session and ctx.session.context then
    context = ctx.session.context({ include_tools = true, max_messages = 120 })
  end
  side = ctx.ai.session({
    system_prompt = SYSTEM_PROMPT,
    reasoning = "low",
    context = context,
    tools = { "read", "bash", "edit", "write" },
  })
  return side
end

local function persist_turn(ctx, question, answer)
  local item = { question = question, answer = answer, timestamp = os.time() }
  table.insert(thread, item)
  if ctx.session and ctx.session.append_artifact then
    ctx.session.append_artifact({ kind = TURN_KIND, title = first_line(question), data = item })
  end
end

local function ask(ctx, question)
  question = trim(question)
  if question == "" then
    status = "Enter a question first."
    render(ctx)
    return
  end
  if busy then
    status = "BTW is still processing the previous question."
    render(ctx)
    return
  end

  busy = true
  pending_question = question
  pending_answer = ""
  pending_error = nil
  pending_tools = {}
  draft = ""
  status = "Streaming side response…"
  render(ctx)

  local ok, result = pcall(function()
    return ensure_side(ctx):prompt({
      prompt = question,
      on = {
        message_delta = function(event)
          pending_answer = pending_answer .. tostring(event.text or "")
          render(ctx)
        end,
        message_end = function(event)
          if event.text and event.text ~= "" then pending_answer = event.text end
          status = "Finalizing side response…"
          render(ctx)
        end,
        tool_execution_start = function(event)
          local tool = { id = event.toolCallId or event.tool_call_id, name = event.toolName or event.tool_name, args = format_tool_args(event.toolName or event.tool_name, event.input or event.args), status = "running" }
          table.insert(pending_tools, tool)
          status = "Running tool: " .. tostring(tool.name or "tool") .. "…"
          render(ctx)
        end,
        tool_execution_end = function(event)
          local tool = find_tool(event.toolCallId or event.tool_call_id)
          if tool then tool.status = (event.isError or event.is_error) and "error" or "done" end
          status = "Streaming side response…"
          render(ctx)
        end,
        error = function(event)
          pending_error = tostring(event.error or "side response failed")
          render(ctx)
        end,
      },
    })
  end)

  busy = false
  if not ok then
    pending_error = tostring(result)
    status = "BTW request failed."
    render(ctx)
    return
  end
  if result.status ~= "completed" then
    pending_error = result.error or result.status or "BTW request failed"
    status = "BTW request failed."
    render(ctx)
    return
  end

  local answer = result.text or pending_answer or ""
  persist_turn(ctx, question, answer)
  pending_question = nil
  pending_answer = ""
  pending_error = nil
  pending_tools = {}
  status = "Ready for the next side question."
  render(ctx)
end

local function reset(ctx)
  thread = {}
  draft = ""
  status = "Ready"
  pending_question = nil
  pending_answer = ""
  pending_error = nil
  pending_tools = {}
  busy = false
  if side then side:dispose(); side = nil end
  if ctx.session and ctx.session.append_artifact then
    ctx.session.append_artifact({ kind = RESET_KIND, title = "BTW reset", data = { timestamp = os.time() } })
  end
  render(ctx)
end

local function format_thread()
  local out = {}
  for _, item in ipairs(thread) do
    table.insert(out, "User: " .. tostring(item.question or ""))
    table.insert(out, "Assistant: " .. tostring(item.answer or ""))
    table.insert(out, "---")
  end
  return table.concat(out, "\n")
end

local function inject_summary(ctx)
  if #thread == 0 then
    status = "No BTW thread to summarize."
    render(ctx)
    return
  end
  status = "Summarizing BTW thread…"
  render(ctx)
  local result = ctx.ai.complete({
    prompt = format_thread(),
    system_prompt = SUMMARY_PROMPT,
    reasoning = "off",
    max_tokens = 800,
  })
  if result.status ~= "completed" then
    status = result.error or "Summary failed."
    render(ctx)
    return
  end
  local msg = "Summary of my BTW side conversation:\n\n" .. tostring(result.text or "")
  if ctx.send_user_message then
    local target = (ctx.is_idle and ctx.is_idle()) and "prompt" or "follow_up"
    ctx.send_user_message(msg, { target = target })
    reset(ctx)
    close_overlay(ctx)
  elseif ctx.editor and ctx.editor.set_text then
    ctx.editor.set_text(msg)
    status = "Summary placed in editor."
    render(ctx)
  else
    status = "No way to inject summary in this host."
    render(ctx)
  end
end

zi.command({
  name = "btw",
  description = "Open a BTW side-chat overlay. `/btw <text>` asks immediately; `/btw inject` summarizes into main chat.",
  handler = function(args, ctx)
    load_thread(ctx)
    local arg = trim(args or "")
    if arg == "reset" then
      reset(ctx)
      return
    elseif arg == "inject" then
      render(ctx)
      inject_summary(ctx)
      return
    elseif arg ~= "" then
      render(ctx)
      ask(ctx, arg)
      return
    end
    status = "Ready"
    render(ctx)
  end,
})

zi.on("ui", function(event, ctx)
  if event.view ~= VIEW_ID then return nil end
  if event.action == "close" then
    draft = tostring(event.value or draft or "")
    close_overlay(ctx)
    return nil
  end
  if event.node == INPUT_ID and event.type == "change" then
    draft = tostring(event.value or "")
    return nil
  end
  if event.node == INPUT_ID and event.type == "submit" then
    ask(ctx, tostring(event.value or draft or ""))
    return nil
  end
end)

zi.on("session_start", function(_, ctx)
  load_thread(ctx)
  if side then side:dispose(); side = nil end
end)

zi.on("session_tree", function(_, ctx)
  load_thread(ctx)
  if side then side:dispose(); side = nil end
  render(ctx)
end)

zi.on("session_shutdown", function()
  if side then side:dispose(); side = nil end
end)

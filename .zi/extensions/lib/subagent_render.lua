-- Sub-agent tree renderer.
--
-- Used by tools that spawn child zi processes (Task, Oracle,
-- HyperTask) to render a tree view of the child's tool calls and
-- final output. Ported from pi-mono's sub-agent-render.ts.
--
-- Input shape (passed via tool result .details):
--   {
--     description   = string,
--     model         = string,
--     usage         = { input, output, cache_read, cache_write, cost, turns, ... },
--     stop_reason   = string,
--     error_message = string|nil,
--     tool_calls    = { { name, args, is_error }, ... },
--     final_text    = string,
--   }
--
-- Captured during tool execution by walking the `zi.spawn({ on = {...} })`
-- event stream — see task.lua for the usage pattern.
--
-- Returns render spans ({ lines = { { {text=, fg=, ...}, ... }, ... } })
-- for the zi transcript to paint.

local M = {}

local box_mid = "├── "
local box_end = "╰── "
local box_cont = "│   "

local COLLAPSED_COUNT = 10

-- Tool argument summarizers. Mirrors pi-mono's toolArgSummary.
-- Case-insensitive: LLMs emit capitalized tool names ("Bash")
-- but our match table is lowercase, so we normalize both sides.
local function tool_arg_summary(name, args)
  if type(args) ~= "table" then return "" end
  local n = (name or ""):lower()

  if n == "bash" then
    local cmd = args.cmd or args.command or ""
    local first_line = cmd:match("[^\n]*") or ""
    return first_line
  elseif n == "read" then
    local p = args.file_path or args.path or ""
    if args.read_range and type(args.read_range) == "table" then
      return p .. ":" .. tostring(args.read_range[1]) .. "-" .. tostring(args.read_range[2])
    end
    return p
  elseif n == "write" or n == "create_file" then
    local p = args.file_path or args.path or ""
    local content = args.content or ""
    local lines = 1
    for _ in content:gmatch("\n") do lines = lines + 1 end
    if lines > 1 then
      return p .. " (" .. lines .. " lines)"
    end
    return p
  elseif n == "edit" or n == "edit_file" then
    return args.file_path or args.path or ""
  elseif n == "grep" then
    return "/" .. (args.pattern or "") .. "/ in " .. (args.path or ".")
  elseif n == "find" or n == "glob" then
    return (args.filePattern or args.pattern or "*") .. " in " .. (args.path or ".")
  elseif n == "ls" then
    return args.path or "."
  elseif n == "task" then
    return args.description or ""
  end

  -- Unknown tool: best-effort JSON preview.
  -- Just pick the first string-valued field as a hint.
  for k, v in pairs(args) do
    if type(v) == "string" and v ~= "" then
      return k .. "=" .. v
    end
  end
  return ""
end

local function format_tokens(n)
  if not n or n == 0 then return nil end
  if n < 1000 then return tostring(n) end
  if n < 10000 then return string.format("%.1fk", n / 1000) end
  if n < 1000000 then return string.format("%dk", math.floor(n / 1000)) end
  return string.format("%.1fM", n / 1000000)
end

local function format_usage(u, model)
  if type(u) ~= "table" then return nil end
  local parts = {}
  if u.turns and u.turns > 0 then
    table.insert(parts, tostring(u.turns) .. (u.turns > 1 and " turns" or " turn"))
  end
  local inp = format_tokens(u.input); if inp then table.insert(parts, "\xe2\x86\x91" .. inp) end
  local out = format_tokens(u.output); if out then table.insert(parts, "\xe2\x86\x93" .. out) end
  local cr = format_tokens(u.cache_read); if cr then table.insert(parts, "R" .. cr) end
  local cw = format_tokens(u.cache_write); if cw then table.insert(parts, "W" .. cw) end
  if u.cost and u.cost > 0 then
    table.insert(parts, string.format("$%.4f", u.cost))
  end
  if model and model ~= "" then table.insert(parts, model) end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

local function capitalize(s)
  if not s or s == "" then return "" end
  return s:sub(1, 1):upper() .. s:sub(2)
end

-- Build the full span tree for one sub-agent result.
--
-- `result` is the tool's return value shape (.content, .is_error, .details).
-- `ctx`    is the renderer ctx (.width, .expanded, .is_error).
-- `opts`   = { label = "Task" | "Oracle" | ... }
function M.render_agent_tree(result, ctx, opts)
  opts = opts or {}
  local details = result.details or {}
  local lines = {}

  local is_error = result.is_error
    or details.stop_reason == "error"
    or details.stop_reason == "aborted"

  -- Line 0: TITLE row (painted by transcript.renderCall).
  -- "Task demo task" — label bold, description dim.
  -- This is the slot the zig transcript reserves above the
  -- result body; we fill it with the tool's short descriptor.
  local title = {
    { text = opts.label or "Task", fg = "tool_title", bold = true },
  }
  if details.description and details.description ~= "" then
    table.insert(title, { text = " " })
    table.insert(title, { text = details.description, fg = "dim" })
  end
  table.insert(lines, title)

  -- Line 1: STATUS row (first line of transcript.renderResult).
  -- Just the icon, matching pi-mono's `header: "statusOnly"`.
  local icon_text = is_error and "\xe2\x9c\x95" or "\xe2\x9c\x93" -- ✕ / ✓
  local icon_fg = is_error and "error" or "success"
  local status = { { text = icon_text, fg = icon_fg } }
  if is_error and details.stop_reason then
    table.insert(status, { text = " [" .. details.stop_reason .. "]", fg = "error" })
  end
  table.insert(lines, status)

  -- Error line (if any)
  if is_error and details.error_message and details.error_message ~= "" then
    table.insert(lines, {
      { text = box_mid, fg = "muted" },
      { text = "Error: " .. details.error_message, fg = "error" },
    })
  end

  -- Gather children: tool calls + optional summary.
  local tool_calls = details.tool_calls or {}
  local final_text = details.final_text or ""

  local visible_tools = {}
  local skipped = 0
  if ctx.expanded then
    for _, tc in ipairs(tool_calls) do
      table.insert(visible_tools, tc)
    end
  else
    local start = math.max(1, #tool_calls - COLLAPSED_COUNT + 1)
    for i = start, #tool_calls do
      table.insert(visible_tools, tool_calls[i])
    end
    skipped = #tool_calls - #visible_tools
  end

  local children = {}
  if skipped > 0 then
    table.insert(children, { kind = "text", content = "... " .. skipped .. " earlier calls" })
  end
  for _, tc in ipairs(visible_tools) do
    table.insert(children, { kind = "tool", item = tc })
  end
  if final_text ~= "" then
    table.insert(children, { kind = "summary", content = final_text })
  end

  for i, child in ipairs(children) do
    local is_last = (i == #children)
    local connector = is_last and box_end or box_mid

    if child.kind == "text" then
      table.insert(lines, {
        { text = connector, fg = "muted" },
        { text = child.content, fg = "dim" },
      })
    elseif child.kind == "tool" then
      local icon_span
      if child.item.is_error == true then
        icon_span = { text = "\xe2\x9c\x95 ", fg = "error" }
      elseif child.item.is_error == false then
        icon_span = { text = "\xe2\x9c\x93 ", fg = "success" }
      else
        icon_span = { text = "\xe2\x8b\xaf ", fg = "muted" } -- ⋯
      end
      table.insert(lines, {
        { text = connector, fg = "muted" },
        icon_span,
        { text = capitalize(child.item.name), fg = "accent" },
        { text = " " },
        { text = tool_arg_summary(child.item.name, child.item.args), fg = "dim" },
      })
    elseif child.kind == "summary" then
      table.insert(lines, {
        { text = connector, fg = "muted" },
        { text = "Summary:", fg = "muted" },
      })
      local prefix = is_last and "    " or box_cont
      for line in (child.content .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
          table.insert(lines, {
            { text = prefix, fg = "muted" },
            { text = line, fg = "text" },
          })
        end
      end
    end
  end

  -- Usage footer (last line, no tree connector)
  local usage_str = format_usage(details.usage, details.model)
  if usage_str then
    table.insert(lines, {
      { text = usage_str, fg = "dim" },
    })
  end

  return { lines = lines }
end

return M

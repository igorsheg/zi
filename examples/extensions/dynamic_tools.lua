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
return function(zi)
  local registered = {}

  local function normalize_tool_name(input)
    local trimmed = tostring(input or ""):match("^%s*(.-)%s*$"):lower()
    if trimmed == "" then return nil end
    if not trimmed:match("^[a-z0-9_]+$") then return nil end
    return trimmed
  end

  local function register_echo_tool(name, label, prefix)
    if registered[name] then return false end
    local ok = zi.tool({
      name = name,
      label = label,
      description = "Echo a message with prefix: " .. prefix,
      prompt_snippet = "Echo back user-provided text with the " .. prefix .. " prefix",
      prompt_guidelines = { "Use dynamically registered echo tools when the user asks for exact echo output." },
      parameters = {
        type = "object",
        properties = {
          message = { type = "string", description = "Message to echo" },
        },
        required = { "message" },
      },
      execute = function(params, ctx)
        local message = params.message or ""
        return {
          content = { { type = "text", text = prefix .. message } },
          details = { tool = name, prefix = prefix },
        }
      end,
      render_call = function(args, ctx)
        return { lines = { { { text = name, fg = "accent" }, { text = " echo", fg = "muted" } } } }
      end,
      render_result = function(result, ctx)
        local text = result.content and result.content[1] and result.content[1].text or ""
        return { lines = { { { text = "↩ ", fg = "muted" }, { text = text, fg = "text" } } } }
      end,
    })
    if ok then registered[name] = true end
    return ok
  end

  zi.on("session_start", function(_, ctx)
    register_echo_tool("echo_session", "Echo Session", "[session] ")
  end)

  zi.command({
    name = "add-echo-tool",
    description = "Register a new echo tool dynamically: /add-echo-tool <tool_name>",
    handler = function(args, ctx)
      local tool_name = normalize_tool_name(args)
      if not tool_name then
        if ctx and ctx.ui and ctx.ui.render then
          ui_report_spec(ctx, {
            id = "dynamic-tools-usage",
            title = "Dynamic tools",
            body = "Usage: /add-echo-tool <lowercase_name>",
            transient = true,
          })
        end
        return false
      end

      local created = register_echo_tool(tool_name, "Echo " .. tool_name, "[" .. tool_name .. "] ")
      if ctx and ctx.ui and ctx.ui.render then
        ui_report_spec(ctx, {
          id = "dynamic-tools-result",
          title = "Dynamic tools",
          body = (created and "Registered tool: " or "Tool already registered: ") .. tool_name,
          transient = true,
        })
      end
      return created
    end,
  })
end

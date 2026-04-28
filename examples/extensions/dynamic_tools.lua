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
    local ok = zi.register_tool({
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

  zi.register_command({
    name = "add-echo-tool",
    description = "Register a new echo tool dynamically: /add-echo-tool <tool_name>",
    handler = function(args, ctx)
      local tool_name = normalize_tool_name(args)
      if not tool_name then
        if ctx and ctx.ui and ctx.ui.report then
          ctx.ui.report({
            id = "dynamic-tools-usage",
            title = "Dynamic tools",
            body = "Usage: /add-echo-tool <lowercase_name>",
            transient = true,
          })
        end
        return false
      end

      local created = register_echo_tool(tool_name, "Echo " .. tool_name, "[" .. tool_name .. "] ")
      if ctx and ctx.ui and ctx.ui.report then
        ctx.ui.report({
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

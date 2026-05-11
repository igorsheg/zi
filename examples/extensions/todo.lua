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
return function(zi)
  local todos = {}
  local next_id = 1

  local function clone_todos()
    local out = {}
    for i, todo in ipairs(todos) do
      out[i] = { id = todo.id, text = todo.text, done = todo.done }
    end
    return out
  end

  local function hydrate(ctx)
    todos = {}
    next_id = 1
    if not ctx or not ctx.session then return end

    for _, result in ipairs(ctx.session.tool_results("todo")) do
      local d = result.details
      if type(d) == "table" then
        todos = d.todos or {}
        next_id = d.nextId or 1
      end
    end
  end

  local function list_text()
    if #todos == 0 then return "No todos" end
    local lines = {}
    for i, todo in ipairs(todos) do
      lines[i] = string.format("[%s] #%d: %s", todo.done and "x" or " ", todo.id, todo.text)
    end
    return table.concat(lines, "\n")
  end


  local function details(action, err)
    return { action = action, todos = clone_todos(), nextId = next_id, error = err }
  end

  local function find_todo(id)
    for _, todo in ipairs(todos) do
      if todo.id == id then return todo end
    end
    return nil
  end

  zi.tool({
    name = "todo",
    label = "Todo",
    description = "Manage a todo list. Actions: list, add (text), toggle (id), clear",
    parameters = {
      type = "object",
      properties = {
        action = { type = "string", enum = { "list", "add", "toggle", "clear" } },
        text = { type = "string", description = "Todo text for add" },
        id = { type = "number", description = "Todo id for toggle" },
      },
      required = { "action" },
    },
    execute = function(params, ctx)
      hydrate(ctx)
      local action = params.action
      if action == "list" then
        return { content = { { type = "text", text = list_text() } }, details = details("list") }
      end

      if action == "add" then
        if not params.text or params.text == "" then
          return {
            content = { { type = "text", text = "Error: text required for add" } },
            is_error = true,
            details = details("add", "text required"),
          }
        end
        local todo = { id = next_id, text = params.text, done = false }
        next_id = next_id + 1
        todos[#todos + 1] = todo
        return { content = { { type = "text", text = string.format("Added todo #%d: %s", todo.id, todo.text) } }, details = details("add") }
      end

      if action == "toggle" then
        if params.id == nil then
          return {
            content = { { type = "text", text = "Error: id required for toggle" } },
            is_error = true,
            details = details("toggle", "id required"),
          }
        end
        local todo = find_todo(params.id)
        if not todo then
          return {
            content = { { type = "text", text = string.format("Todo #%d not found", params.id) } },
            is_error = true,
            details = details("toggle", string.format("#%d not found", params.id)),
          }
        end
        todo.done = not todo.done
        return {
          content = { { type = "text", text = string.format("Todo #%d %s", todo.id, todo.done and "completed" or "uncompleted") } },
          details = details("toggle"),
        }
      end

      if action == "clear" then
        local count = #todos
        todos = {}
        next_id = 1
        return { content = { { type = "text", text = string.format("Cleared %d todos", count) } }, details = details("clear") }
      end

      return {
        content = { { type = "text", text = "Unknown action: " .. tostring(action) } },
        is_error = true,
        details = details("list", "unknown action: " .. tostring(action)),
      }
    end,
    render_result = function(result, ctx)
      local d = result.details
      if not d then return result.content and result.content[1] and result.content[1].text or "" end
      if d.error then return { lines = { { { text = "Error: " .. d.error, fg = "error" } } } } end

      if d.action == "list" then
        if #d.todos == 0 then return { lines = { { { text = "No todos", fg = "muted", dim = true } } } } end
        local lines = { { { text = tostring(#d.todos) .. " todo(s):", fg = "muted" } } }
        local limit = ctx.expanded and #d.todos or math.min(#d.todos, 5)
        for i = 1, limit do
          local todo = d.todos[i]
          lines[#lines + 1] = {
            { text = todo.done and "✓ " or "○ ", fg = todo.done and "success" or "muted" },
            { text = "#" .. tostring(todo.id) .. " ", fg = "accent" },
            { text = todo.text, fg = todo.done and "muted" or "text", dim = todo.done },
          }
        end
        if not ctx.expanded and #d.todos > 5 then
          lines[#lines + 1] = { { text = "... " .. tostring(#d.todos - 5) .. " more", fg = "muted", dim = true } }
        end
        return { lines = lines }
      end

      if d.action == "add" then
        local added = d.todos[#d.todos]
        if added then
          return { lines = { { { text = "✓ Added ", fg = "success" }, { text = "#" .. tostring(added.id) .. " ", fg = "accent" }, { text = added.text, fg = "muted" } } } }
        end
      end

      local text = result.content and result.content[1] and result.content[1].text or ""
      return { lines = { { { text = "✓ ", fg = "success" }, { text = text, fg = "muted" } } } }
    end,
  })

  zi.on("session_start", function(_, ctx)
    hydrate(ctx)
  end)

  zi.on("session_tree", function(_, ctx)
    hydrate(ctx)
  end)

  zi.command({
    name = "todos",
    description = "Show all todos on the current session branch",
    handler = function(_, ctx)
      hydrate(ctx)
      if ctx and ctx.ui and ctx.ui.render then
        ui_report_spec(ctx, {
          id = "todos",
          title = "Todos",
          body = list_text(),
          transient = true,
        })
        return
      end
      return list_text()
    end,
  })
end

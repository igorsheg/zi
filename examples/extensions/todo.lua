return function(zi)
  local todos = {}
  local next_id = 1

  local function snapshot()
    local items = {}
    for i, item in ipairs(todos) do items[i] = { id = item.id, text = item.text, done = item.done } end
    return { next_id = next_id, items = items }
  end

  local function restore(ctx)
    if not (ctx.session and ctx.session.artifacts) then return end
    local artifacts = nil
    if ctx.session.artifacts.list then
      artifacts = ctx.session.artifacts.list({ kind = "todo_state", key = "main", limit = 1 })
    elseif type(ctx.session.artifacts) == "function" then
      artifacts = ctx.session.artifacts({ kind = "todo_state", key = "main", limit = 1 })
    end
    local latest = artifacts and artifacts[1]
    if latest and latest.data then
      todos = latest.data.items or {}
      next_id = latest.data.next_id or 1
    end
  end

  local function persist(ctx)
    if not ctx.session then return end
    local state = snapshot()
    if ctx.session.artifacts and ctx.session.artifacts.append then
      ctx.session.artifacts.append({ kind = "todo_state", key = "main", title = "Todo state", data = state })
    elseif ctx.session.append_artifact then
      ctx.session.append_artifact({ kind = "todo_state", key = "main", title = "Todo state", data = state })
    end
  end

  local function list_text()
    if #todos == 0 then return "No todos" end
    local lines = {}
    for i, item in ipairs(todos) do lines[i] = string.format("[%s] #%d %s", item.done and "x" or " ", item.id, item.text) end
    return table.concat(lines, "\n")
  end

  local function find(id)
    for _, item in ipairs(todos) do if item.id == id then return item end end
    return nil
  end

  zi.define.tool({
    name = "todo",
    label = "Todo",
    description = "Manage a session-local todo list. Actions: list, add, toggle, clear.",
    input = {
      type = "object",
      properties = {
        action = { type = "string", enum = { "list", "add", "toggle", "clear" } },
        text = { type = "string", description = "Todo text for add." },
        id = { type = "number", description = "Todo id for toggle." },
      },
      required = { "action" },
    },
    display = { call = "action" },
    run = function(ctx, input)
      restore(ctx)
      local action = input.action
      if action == "list" then
        return { content = { { type = "text", text = list_text() } }, metadata = snapshot() }
      elseif action == "add" then
        if not input.text or input.text == "" then return { content = { { type = "text", text = "text is required" } }, is_error = true } end
        todos[#todos + 1] = { id = next_id, text = input.text, done = false }
        next_id = next_id + 1
        persist(ctx)
        return { content = { { type = "text", text = list_text() } }, metadata = snapshot() }
      elseif action == "toggle" then
        local item = find(input.id)
        if not item then return { content = { { type = "text", text = "todo not found" } }, is_error = true, metadata = snapshot() } end
        item.done = not item.done
        persist(ctx)
        return { content = { { type = "text", text = list_text() } }, metadata = snapshot() }
      elseif action == "clear" then
        todos = {}; next_id = 1; persist(ctx)
        return { content = { { type = "text", text = "Cleared todos" } }, metadata = snapshot() }
      end
      return { content = { { type = "text", text = "unknown action" } }, is_error = true }
    end,
  })

  zi.define.command({
    name = "todos",
    description = "Show todos in an overlay.",
    run = function(ctx, _input)
      restore(ctx)
      if ctx.ui and ctx.ui.view then
        ctx.ui.view.set({
          id = "example-todos",
          slot = { kind = "overlay", width = "60%", max_height = "70%", anchor = "center", backdrop = "dim" },
          keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
          root = { type = "view", style = { chrome = { kind = "frame", title = "Todos", border = "rounded" }, padding = 1 }, children = { { type = "text", text = list_text() } } },
        })
      end
    end,
  })

  zi.define.event("ui", function(ctx, event)
    if event.view == "example-todos" and event.action == "close" and ctx.ui and ctx.ui.view then ctx.ui.view.set({ id = "example-todos", remove = true }) end
  end)
end

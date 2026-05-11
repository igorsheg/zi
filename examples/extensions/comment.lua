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
-- Comment example: quote the last assistant message, edit it in $VISUAL/$EDITOR,
-- and load the edited text into zi's prompt editor.
--
-- Usage:
--   /comment

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function last_assistant_text(ctx)
  local messages = ctx.session.messages({ limit = 100, include_tools = false })
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role == "assistant" then
      local text = trim(msg.text or "")
      if text ~= "" then return text end
    end
  end
  return nil
end

local function quote_text(text)
  local lines = {}
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then return "> " end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = "> " .. line
  end
  return table.concat(lines, "\n")
end

local function split_words(s)
  local out = {}
  for word in tostring(s or ""):gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then error(err or ("failed to open " .. path)) end
  local data = f:read("*a") or ""
  f:close()
  return data
end

local function write_file(path, data)
  local f, err = io.open(path, "w")
  if not f then error(err or ("failed to write " .. path)) end
  f:write(data)
  f:close()
end

local function edit_with_editor(initial_text, ctx)
  local editor = os.getenv("VISUAL") or os.getenv("EDITOR")
  if not editor or editor == "" then
    error("No editor configured. Set $VISUAL or $EDITOR.")
  end

  local tmp = os.tmpname() .. ".md"
  write_file(tmp, initial_text)

  local argv = split_words(editor)
  if #argv == 0 then error("No editor configured. Set $VISUAL or $EDITOR.") end
  argv[#argv + 1] = tmp

  local result = zi.system(argv, {
    cwd = ctx.cwd,
    stdio = "terminal",
  })

  if result.status ~= "completed" or result.code ~= 0 then
    os.remove(tmp)
    error("Editor exited with status " .. tostring(result.code or result.status))
  end

  local edited = read_file(tmp):gsub("\n$", "")
  os.remove(tmp)
  return edited
end

zi.command({
  name = "comment",
  description = "Open the last assistant message in $EDITOR and load the result into the editor",
  handler = function(_, ctx)
    if not ctx.has_ui then
      if ctx.ui then ui_toast(ctx, "comment requires interactive mode", { kind = "error" }) end
      return
    end

    local text = last_assistant_text(ctx)
    if not text then
      ui_toast(ctx, "No assistant message found on the current branch", { kind = "error" })
      return
    end

    local ok, edited_or_err = pcall(edit_with_editor, quote_text(text), ctx)
    if not ok then
      ui_toast(ctx, tostring(edited_or_err), { kind = "error" })
      return
    end

    ctx.editor.set_text(edited_or_err)
    ui_toast(ctx, "Loaded edited quoted assistant text into the editor", { kind = "info" })
  end,
})

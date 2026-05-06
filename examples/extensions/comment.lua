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
      if ctx.ui then ctx.ui.message("comment requires interactive mode", { kind = "error" }) end
      return
    end

    local text = last_assistant_text(ctx)
    if not text then
      ctx.ui.message("No assistant message found on the current branch", { kind = "error", lifetime = "until_input" })
      return
    end

    local ok, edited_or_err = pcall(edit_with_editor, quote_text(text), ctx)
    if not ok then
      ctx.ui.message(tostring(edited_or_err), { kind = "error", lifetime = "until_input" })
      return
    end

    ctx.editor.set_text(edited_or_err)
    ctx.ui.message("Loaded edited quoted assistant text into the editor", { kind = "info", lifetime = "until_input" })
  end,
})

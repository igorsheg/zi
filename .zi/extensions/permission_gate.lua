-- Live-test permission gate: confirm dangerous bash tool calls.

local dangerous_patterns = {
  "rm%s+%-r",
  "rm%s+%-f",
  "rm%s+%-%-recursive",
  "%f[%w]sudo%f[%W]",
  "chmod%s+.-777",
  "chown%s+.-777",
}

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function is_bash_tool(name)
  name = lower(name)
  return name == "bash"
end

local function is_dangerous(command)
  local c = lower(command)
  for _, pattern in ipairs(dangerous_patterns) do
    if string.find(c, pattern) then return true end
  end
  return false
end

zi.on("tool_call", function(event, ctx)
  if not is_bash_tool(event.tool_name) then return nil end

  local args = event.args or {}
  local command = tostring(args.command or args.cmd or "")
  if not is_dangerous(command) then return nil end

  if not (ctx and ctx.has_ui and ctx.ui and ctx.ui.prompt) then
    return {
      block = true,
      reason = "Dangerous bash command blocked: no interactive UI available for confirmation",
    }
  end

  local result = ctx.ui.prompt({
    kind = "confirm",
    title = "Dangerous bash command",
    message = "Allow this command?\n\n" .. command,
    timeout_ms = 30000,
  })

  if result.status == "submitted" and result.value == true then
    ctx.ui.message("Dangerous command allowed", { kind = "warning" })
    return nil
  end

  if result.status == "timeout" then
    return { block = true, reason = "Dangerous bash command timed out waiting for confirmation" }
  end

  return { block = true, reason = "Dangerous bash command blocked by user" }
end)

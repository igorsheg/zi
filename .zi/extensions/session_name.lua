-- Live-test session name extension.
-- /session-name, /session-name My Project, /session-name --clear

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

zi.register_command({
  name = "session-name",
  description = "Set or show session name",
  handler = function(args, ctx)
    local name = trim(args)
    if name == "--clear" then
      ctx.session.rename("")
      ctx.ui.message("Session name cleared", { lifetime = "until_input" })
      return
    end
    if name ~= "" then
      ctx.session.rename(name)
      ctx.ui.message("Session named: " .. name, { lifetime = "until_input" })
      return
    end
    local current = ctx.session.name()
    ctx.ui.message(current and ("Session: " .. current) or "No session name set", { lifetime = "until_input" })
  end,
})

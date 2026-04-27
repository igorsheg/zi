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
      ctx.ui.set_footer("Session name cleared", { lifetime = "until_input" })
      return
    end
    if name ~= "" then
      ctx.session.rename(name)
      ctx.ui.set_footer("Session named: " .. name, { lifetime = "until_input" })
      return
    end
    local current = ctx.session.name()
    ctx.ui.set_footer(current and ("Session: " .. current) or "No session name set", { lifetime = "until_input" })
  end,
})

-- Session name example: semantic session metadata mutation.
--
-- Usage:
--   /session-name              show current name
--   /session-name My Project   set current branch/session name
--   /session-name --clear      clear current name

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

zi.register_command({
  name = "session-name",
  description = "Set or show session name (usage: /session-name [new name])",
  handler = function(args, ctx)
    local name = trim(args)

    if name == "--clear" then
      if ctx.session.rename("") then
        ctx.ui.message("Session name cleared", { lifetime = "until_input" })
      else
        ctx.ui.message("Failed to clear session name", { lifetime = "until_input" })
      end
      return
    end

    if name ~= "" then
      if ctx.session.rename(name) then
        ctx.ui.message("Session named: " .. name, { lifetime = "until_input" })
      else
        ctx.ui.message("Failed to name session", { lifetime = "until_input" })
      end
      return
    end

    local current = ctx.session.name()
    if current then
      ctx.ui.message("Session: " .. current, { lifetime = "until_input" })
    else
      ctx.ui.message("No session name set", { lifetime = "until_input" })
    end
  end,
})

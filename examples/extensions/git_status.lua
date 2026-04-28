-- Run git status through the yieldable zi.system API.
--
-- /git-status

zi.register_command({
  name = "git-status",
  description = "Show git status for the current working directory.",
  handler = function(_, ctx)
    local result = zi.system({ "git", "status", "--short" }, {
      cwd = ctx.cwd,
      timeout_ms = 5000,
    })

    if result.status ~= "completed" then
      ctx.ui.show_panel({
        title = "git status",
        body = result.error or result.status,
      })
      return
    end

    local body = result.stdout
    if body == "" then
      body = "clean"
    end
    if result.stderr ~= "" then
      body = body .. "\n\nstderr:\n" .. result.stderr
    end

    ctx.ui.show_panel({
      title = "git status",
      body = body,
    })
  end,
})

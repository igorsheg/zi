-- Demonstrates zi's fidget-style extension notifications.
-- Try:
--   /notify-demo
--   /notify-progress
--   /notify-clear

local function normalize_level(level)
  level = tostring(level or "info")
  if level == "warning" then return "warn" end
  if level == "danger" then return "error" end
  return level
end

local function notify(ctx, message, opts)
  if not (ctx and ctx.ui and ctx.ui.notify) then return end
  opts = opts or {}
  if opts.level then opts.level = normalize_level(opts.level) end
  ctx.ui.notify.show(tostring(message or ""), opts)
end

local function sleep(zi, seconds)
  -- ctx.process.run is yieldable, so the TUI can paint each intermediate update.
  ctx.process.run({ "/bin/sleep", tostring(seconds or 0.25) }, { timeout_ms = 2000, max_stdout_bytes = 1, max_stderr_bytes = 256 })
end

return function(zi)
  zi.define.command({
    name = "notify-demo",
    description = "Show a burst of fidget-style notifications: groups, levels, annotations, and replacement by id.",
    run = function(ctx, _)
      notify(ctx, "debug detail, dimmed", {
        id = "notify-demo-debug",
        group = "demo",
        level = "debug",
        annote = "debug",
      })
      notify(ctx, "ambient info", {
        id = "notify-demo-info",
        group = "demo",
        level = "info",
        annote = "info",
      })
      notify(ctx, "heads up", {
        id = "notify-demo-warn",
        group = "lint",
        level = "warn",
        annote = "warn",
      })
      notify(ctx, "something failed", {
        id = "notify-demo-error",
        group = "build",
        level = "error",
        annote = "error",
      })
      notify(ctx, "operation complete", {
        id = "notify-demo-success",
        group = "agent",
        level = "success",
        annote = "success",
        done = true,
      })

      -- Same id replaces in place. You should only see the latest value for this row.
      notify(ctx, "replace me: first", { id = "notify-demo-replace", group = "keyed", level = "info" })
      notify(ctx, "replace me: second", { id = "notify-demo-replace", group = "keyed", level = "warn" })
      notify(ctx, "replacement settled", { id = "notify-demo-replace", group = "keyed", level = "success", done = true, annote = "same id" })
    end,
  })

  zi.define.command({
    name = "notify-progress",
    description = "Animate a keyed progress notification through progress and done states.",
    run = function(ctx, _)
      notify(ctx, "preparing workspace", {
        id = "notify-demo-progress",
        group = "workspace",
        level = "info",
        progress = true,
        annote = "1/4",
      })
      sleep(zi, 0.35)

      notify(ctx, "indexing files", {
        id = "notify-demo-progress",
        group = "workspace",
        level = "info",
        progress = true,
        annote = "2/4",
      })
      sleep(zi, 0.35)

      notify(ctx, "checking symbols", {
        id = "notify-demo-progress",
        group = "workspace",
        level = "info",
        progress = true,
        annote = "3/4",
      })
      sleep(zi, 0.35)

      notify(ctx, "workspace ready", {
        id = "notify-demo-progress",
        group = "workspace",
        level = "success",
        done = true,
        annote = "4/4",
      })
    end,
  })

  zi.define.command({
    name = "notify-clear",
    description = "Clear notifications created by /notify-demo and /notify-progress.",
    run = function(ctx, _)
      local ids = {
        "notify-demo-debug",
        "notify-demo-info",
        "notify-demo-warn",
        "notify-demo-error",
        "notify-demo-success",
        "notify-demo-replace",
        "notify-demo-progress",
      }
      for _, id in ipairs(ids) do
        notify(ctx, "", { id = id, clear = true })
      end
    end,
  })
end

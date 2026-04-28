-- Session lifecycle hooks example.
--
-- Shows the host-owned lifecycle events that extensions can observe or block.
-- Try:
--   /new
--   /resume <path>
--   /fork <entry-id>
--
-- Events are deliberately semantic: extensions see session/binding metadata,
-- not raw TUI internals.

local function label_binding(binding)
  if type(binding) ~= "table" then
    return "unknown session"
  end
  local id = binding.session_id or "unknown"
  return string.sub(id, 1, 8)
end

local function footer(ctx, text)
  if ctx and ctx.ui and ctx.ui.message then
    ctx.ui.message(text)
  end
end

zi.on("session_start", function(event, ctx)
  footer(ctx, "Session started (" .. tostring(event.reason or "unknown") .. "): " .. label_binding(event.binding))
end)

zi.on("session_shutdown", function(event, ctx)
  footer(ctx, "Session stopped (" .. tostring(event.reason or "unknown") .. "): " .. label_binding(event.binding))
end)

zi.on("session_before_switch", function(event, ctx)
  footer(ctx, "Switching session (" .. tostring(event.reason or "unknown") .. ")…")
  -- Return { block = true, message = "..." } to cancel the switch.
  return { block = false }
end)

zi.on("session_before_fork", function(event, ctx)
  footer(ctx, "Forking session from entry " .. tostring(event.entry_id or "unknown") .. "…")
  -- Return { block = true, message = "..." } to cancel the fork.
  return { block = false }
end)

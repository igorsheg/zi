return function(zi)
  local turn_count = 0

  zi.on("session_start", function(_, ctx)
    if not ctx.has_ui then return end
    ctx.ui.set_status("status-demo", "Ready")
  end)

  zi.on("turn_start", function(_, ctx)
    turn_count = turn_count + 1
    ctx.ui.set_status("status-demo", "● Turn " .. tostring(turn_count) .. "...")
  end)

  zi.on("turn_end", function(_, ctx)
    ctx.ui.set_status("status-demo", "✓ Turn " .. tostring(turn_count) .. " complete")
  end)
end

-- Live-test input transform extension.
-- Try: ?quick What is Zig? / ping / time

zi.on("input", function(event, ctx)
  if string.sub(event.text, 1, 7) == "?quick " then
    local query = string.gsub(string.sub(event.text, 8), "^%s+", "")
    if query == "" then
      ctx.ui.notify("Usage: ?quick <question>", "warning")
      return { action = "handled" }
    end
    return { action = "transform", text = "Respond briefly in 1-2 sentences: " .. query }
  end

  if string.lower(event.text) == "ping" then
    ctx.ui.set_footer("pong", { lifetime = "until_input" })
    return { action = "handled" }
  end

  if string.lower(event.text) == "time" then
    ctx.ui.set_footer(os.date("%Y-%m-%d %H:%M:%S"), { lifetime = "until_input" })
    return { action = "handled" }
  end

  return { action = "continue" }
end)

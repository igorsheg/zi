-- Input transform example: intercept user input before it reaches the model.
--
-- Try:
--   ?quick What is Zig?
--   ping
--   time

zi.on("input", function(event, ctx)
  if event.source == "extension" then
    return { action = "continue" }
  end

  if string.sub(event.text, 1, 7) == "?quick " then
    local query = string.gsub(string.sub(event.text, 8), "^%s+", "")
    if query == "" then
      ctx.ui.message("Usage: ?quick <question>", { kind = "warning" })
      return { action = "handled" }
    end

    return {
      action = "transform",
      text = "Respond briefly in 1-2 sentences: " .. query,
    }
  end

  if string.lower(event.text) == "ping" then
    ctx.ui.message("pong", { lifetime = "until_input" })
    return { action = "handled" }
  end

  if string.lower(event.text) == "time" then
    ctx.ui.message(os.date("%Y-%m-%d %H:%M:%S"), { lifetime = "until_input" })
    return { action = "handled" }
  end

  return { action = "continue" }
end)

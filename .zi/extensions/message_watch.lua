-- Semantic message event example.
--
-- Updates the footer when transcript-visible semantic messages complete.
-- This uses the same role-oriented shape as ctx.session.messages(), without
-- exposing raw provider/renderer internals.

zi.on("message", function(event, ctx)
  local message = event.message or {}
  if message.role == "user" and message.text then
    ctx.ui.message("Last user message: " .. string.sub(message.text, 1, 80))
  elseif message.role == "assistant" and message.text then
    ctx.ui.message("Assistant replied: " .. string.sub(message.text, 1, 80))
  elseif message.role == "tool_call" then
    ctx.ui.message("Tool requested: " .. tostring(message.tool_name or "unknown"))
  elseif message.role == "tool_result" then
    ctx.ui.message("Tool finished: " .. tostring(message.tool_name or "unknown"))
  end
end)

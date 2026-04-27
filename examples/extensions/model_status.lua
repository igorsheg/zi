-- Model status example.
-- Product-equivalent to pi-mono model-status.ts: observe model_select,
-- notify on explicit model changes, and keep a keyed status item current.

zi.on("model_select", function(event, ctx)
  local model = event.model or {}
  local provider = model.provider or "unknown"
  local id = model.id or "unknown"
  local next_model = provider .. "/" .. id

  if ctx.ui then
    if event.source ~= "restore" and ctx.ui.notify then
      ctx.ui.notify("Model: " .. next_model, "info")
    end
    if ctx.ui.set_status then
      ctx.ui.set_status("model", "🤖 " .. id)
    end
  end
end)

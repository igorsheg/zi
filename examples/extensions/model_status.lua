-- Model status example.
-- Product-equivalent to pi-mono model-status.ts: observe model_select,
-- message on explicit model changes, and keep a keyed status item current.

zi.on("model_select", function(event, ctx)
  local model = event.model or {}
  local provider = model.provider or "unknown"
  local id = model.id or "unknown"
  local next_model = provider .. "/" .. id

  if ctx.ui then
    if event.source ~= "restore" and ctx.ui.message then
      ctx.ui.message("Model: " .. next_model, { kind = "info" })
    end
    if ctx.ui.status then
      ctx.ui.status({ id = "model", text = "🤖 " .. id })
    end
  end
end)

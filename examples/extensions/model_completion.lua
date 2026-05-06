-- Rich model API + ctx.ai.complete model override example.
--
-- /models       show visible model catalog
-- /ask-model <model-ref> :: <prompt>
--
-- model-ref can be a model id, provider/model id, or a model table returned by
-- ctx.models.list(). ctx.ai.complete stays sessionless: it does not mutate the
-- transcript or run tools.

zi.command({
  name = "models",
  description = "Show visible model catalog.",
  handler = function(_, ctx)
    local models = ctx.models and ctx.models.list and ctx.models.list() or {}
    if #models == 0 then
      ctx.ui.message("No model catalog available")
      return
    end

    local lines = {}
    local current = ctx.models.current()
    local lookup = ctx.models.get(current)
    lines[#lines + 1] = "Current: " .. current.provider .. "/" .. current.id
    if lookup then
      lines[#lines + 1] = "Lookup: " .. lookup.provider .. "/" .. lookup.id
    end
    lines[#lines + 1] = ""
    for i, model in ipairs(models) do
      if i > 20 then
        lines[#lines + 1] = "…"
        break
      end
      local marker = model.id == current.id and model.provider == current.provider and "*" or " "
      lines[#lines + 1] = string.format(
        "%s %s/%s  ctx=%s max=%s reasoning=%s",
        marker,
        model.provider or "?",
        model.id or "?",
        tostring(model.context_window or "?"),
        tostring(model.max_tokens or "?"),
        tostring(model.reasoning or false)
      )
    end

    ctx.ui.report({
      id = "models",
      title = "Model catalog",
      body = table.concat(lines, "\n"),
    })
  end,
})

zi.command({
  name = "ask-model",
  description = "Run a sessionless completion with a selected model.",
  handler = function(args, ctx)
    local raw = tostring(args or "")
    local sep = string.find(raw, "::", 1, true)
    if not sep then
      ctx.ui.message("Usage: /ask-model <model> :: <prompt>")
      return
    end
    local model_ref = string.gsub(string.sub(raw, 1, sep - 1), "^%s*(.-)%s*$", "%1")
    local prompt = string.gsub(string.sub(raw, sep + 2), "^%s*(.-)%s*$", "%1")
    if model_ref == "" or prompt == "" then
      ctx.ui.message("Usage: /ask-model <model> :: <prompt>")
      return
    end

    ctx.ui.message("Completing with " .. model_ref .. "…")
    local result = ctx.ai.complete({
      model = model_ref,
      prompt = prompt,
      max_tokens = 800,
      reasoning = "low",
    })

    if result.status == "completed" then
      ctx.ui.report({ id = "ask-model", title = "AI completion: " .. model_ref, body = result.text })
    else
      ctx.ui.message("AI completion failed: " .. tostring(result.error or result.status))
    end
  end,
})

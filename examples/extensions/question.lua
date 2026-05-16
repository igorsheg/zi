zi.define.tool({
  name = "question",
  label = "Question",
  description = "Deferred: asks a multiple-choice question once v3 input/select nodes exist.",
  input = { type = "object", properties = { question = { type = "string" }, options = { type = "array", items = { type = "string" } } }, required = { "question", "options" } },
  run = function(params, _)
    return { content = { { type = "text", text = "Cannot ask interactively yet: " .. tostring(params.question or "") } }, is_error = true }
  end,
})

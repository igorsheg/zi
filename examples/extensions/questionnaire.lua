zi.define.tool({
  name = "questionnaire",
  label = "Questionnaire",
  description = "Deferred: multi-step input/select nodes are not active in API v4.",
  input = { type = "object", properties = {} },
  run = function(_, _)
    return { content = { { type = "text", text = "Questionnaire prompt flow deferred until v3 input/select nodes exist." } } }
  end,
})

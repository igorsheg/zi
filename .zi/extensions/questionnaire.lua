-- Live-test questionnaire extension for ctx.ui.prompt.

zi.register_tool({
  name = "questionnaire",
  label = "Questionnaire",
  description = "Ask a small multi-step questionnaire using host-owned prompts.",
  parameters = { type = "object", properties = {} },
  execute = function(_, ctx)
    local project = ctx.ui.prompt({
      kind = "input",
      title = "Project name",
      placeholder = "my-app",
      default = "zi-extension",
    })
    if project.status ~= "submitted" then
      return { content = { { type = "text", text = "Questionnaire cancelled" } } }
    end

    local language = ctx.ui.prompt({
      kind = "select",
      title = "Language",
      options = {
        { label = "Zig", value = "zig" },
        { label = "Lua", value = "lua" },
        { label = "TypeScript", value = "typescript" },
      },
    })
    if language.status ~= "submitted" then
      return { content = { { type = "text", text = "Questionnaire cancelled" } } }
    end

    return {
      content = { { type = "text", text = "Project: " .. project.value .. "\nLanguage: " .. language.value } },
      details = { project = project.value, language = language.value },
    }
  end,
})

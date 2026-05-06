-- Questionnaire example: compose host-owned prompt primitives.
-- This intentionally avoids raw/custom TUI access. The extension describes
-- semantic prompts; zi owns rendering, input handling, and lifecycle.

zi.tool({
  name = "questionnaire",
  label = "Questionnaire",
  description = "Ask a small multi-step questionnaire using ctx.ui.prompt.",
  parameters = {
    type = "object",
    properties = {},
  },
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

    local text = "Project: " .. project.value .. "\nLanguage: " .. language.value
    return {
      content = { { type = "text", text = text } },
      details = {
        project = project.value,
        language = language.value,
      },
    }
  end,
})

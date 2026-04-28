-- Question tool live-test extension.
-- Asks the host to present a select prompt and returns the semantic answer.

zi.register_tool({
  name = "question",
  label = "Question",
  description = "Ask the user a question and let them pick from options.",
  parameters = {
    type = "object",
    properties = {
      question = { type = "string", description = "The question to ask the user" },
      options = {
        type = "array",
        description = "Options for the user to choose from",
        items = {
          type = "object",
          properties = {
            label = { type = "string" },
            description = { type = "string" },
          },
          required = { "label" },
        },
      },
    },
    required = { "question", "options" },
  },

  execute = function(args, ctx)
    local question = args.question or "Question"
    local raw_options = args.options or {}
    local options = {}
    for _, option in ipairs(raw_options) do
      if type(option) == "table" and option.label then
        table.insert(options, option.label)
      elseif type(option) == "string" then
        table.insert(options, option)
      end
    end

    if #options == 0 then
      return {
        content = { { type = "text", text = "Error: No options provided" } },
        details = { question = question, options = options, answer = nil },
        is_error = true,
      }
    end

    if not ctx.has_ui or not ctx.ui or not ctx.ui.pick then
      return {
        content = { { type = "text", text = "Error: UI not available" } },
        details = { question = question, options = options, answer = nil },
        is_error = true,
      }
    end

    local result = ctx.ui.pick({ title = question, options = options })
    local answer = result.status == "submitted" and result.value or nil
    if answer == nil then
      return {
        content = { { type = "text", text = "User cancelled the selection" } },
        details = { question = question, options = options, answer = nil },
      }
    end

    local index = nil
    for i, option in ipairs(options) do
      if option == answer then
        index = i
        break
      end
    end

    local prefix = index and (tostring(index) .. ". ") or ""
    return {
      content = { { type = "text", text = "User selected: " .. prefix .. answer } },
      details = { question = question, options = options, answer = answer, index = index },
    }
  end,

  render_call = function(args)
    local lines = {
      { { text = "question ", fg = "accent" }, { text = args.question or "", fg = "text" } },
    }
    local raw_options = args.options or {}
    local labels = {}
    for i, option in ipairs(raw_options) do
      local label = type(option) == "table" and option.label or tostring(option)
      labels[i] = tostring(i) .. ". " .. label
    end
    if #labels > 0 then
      table.insert(lines, { { text = "  Options: " .. table.concat(labels, ", "), fg = "muted", dim = true } })
    end
    return lines
  end,

  render_result = function(result)
    local details = result.details or {}
    if details.answer == nil then
      return { { { text = "Cancelled", fg = "warning" } } }
    end
    local display = details.index and (tostring(details.index) .. ". " .. details.answer) or details.answer
    return { { { text = "✓ ", fg = "success" }, { text = display, fg = "accent" } } }
  end,
})

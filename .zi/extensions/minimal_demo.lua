return function(zi)
  zi.register_tool({
    name = "minimal_demo",
    label = "Minimal demo",
    description = "Demo tool for zi's tool result presentation slot. Collapsed output renders zero rows; expanded output renders a small line/span document.",
    parameters = {
      type = "object",
      properties = {
        message = { type = "string", description = "Message to show when expanded" },
      },
    },
    execute = function(params)
      local message = params.message or "hello from the minimal presentation demo"
      return {
        content = { { type = "text", text = message } },
        details = {
          message = message,
          hint = "collapsed render_result returns an empty string, so the result consumes zero rows until expanded",
        },
      }
    end,
    render_result = function(result, ctx)
      if not ctx.expanded then
        -- New API behavior: empty string means an intentional zero-row
        -- presentation document, not a blank line.
        return ""
      end

      local message = result.details and result.details.message or ""
      local hint = result.details and result.details.hint or ""
      return {
        lines = {
          {
            { text = "minimal_demo", fg = "accent", bold = true },
            { text = " expanded", fg = "muted" },
          },
          { { text = message, fg = "toolOutput" } },
          { { text = hint, fg = "dim", dim = true } },
        },
      }
    end,
  })
end

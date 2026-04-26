return function(zi)
  local function header_lines()
    return {
      { { text = "     █▌  █▌", fg = "text" } },
      { { text = "  ██████████████", fg = "accent", bold = true } },
      { { text = "     ██    ██", fg = "accent", bold = true } },
      { { text = "     ██    ██", fg = "accent", bold = true } },
      { { text = "     ██    ██", fg = "accent", bold = true } },
      { { text = "   zi coding agent", fg = "muted" } },
    }
  end

  zi.on("session_start", function(_, ctx)
    if not ctx.has_ui then return end
    ctx.ui.set_header(header_lines(), { lifetime = "until_input" })
  end)

  zi.register_command({
    name = "builtin-header",
    description = "Restore the built-in header.",
    handler = function(_, ctx)
      ctx.ui.set_header({})
    end,
  })
end

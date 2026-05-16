return function(zi)
  zi.define.tool({
    name = "read",
    label = "read (minimal)",
    description = "Read a text file with minimal collapsed presentation and fuller expanded presentation.",
    input = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to read" },
        offset = { type = "number", description = "1-indexed first line" },
        limit = { type = "number", description = "Maximum lines to return" },
      },
      required = { "path" },
    },
    run = function(ctx, params)
      local path = params.path or ""
      local cwd = (ctx and ctx.env.cwd) or "."
      local absolute = path
      if not string.match(path, "^/") then
        absolute = cwd .. "/" .. path
      end

      local file, err = io.open(absolute, "r")
      if not file then
        return {
          content = { { type = "text", text = "Error reading file: " .. tostring(err) } },
          is_error = true,
          details = { error = true, path = path },
        }
      end

      local lines = {}
      for line in file:lines() do
        lines[#lines + 1] = line
      end
      file:close()

      local start_line = math.max(1, params.offset or 1)
      local stop_line = #lines
      if params.limit then stop_line = math.min(#lines, start_line + params.limit - 1) end

      local selected = {}
      for i = start_line, stop_line do
        selected[#selected + 1] = lines[i]
      end

      return {
        content = { { type = "text", text = table.concat(selected, "\n") } },
        details = { path = path, lines = #lines, offset = start_line, limit = params.limit },
        presentation = {
          schema = "zi.doc.v1",
          blocks = {
            { type = "line", spans = { { text = "read ", style = { role = "muted" } }, { text = path, style = { role = "accent", bold = true } } } },
            { type = "text", text = table.concat(selected, "\n"), collapsed_lines = 0 },
          },
        },
      }
    end,
  })
end

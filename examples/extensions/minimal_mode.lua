return function(zi)
  zi.register_tool({
    name = "read",
    label = "read (minimal)",
    description = "Read a text file with minimal collapsed presentation and fuller expanded presentation.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to read" },
        offset = { type = "number", description = "1-indexed first line" },
        limit = { type = "number", description = "Maximum lines to return" },
      },
      required = { "path" },
    },
    render_call = function(args)
      local path = args.path or "..."
      return {
        lines = {
          {
            { text = "read ", fg = "toolTitle", bold = true },
            { text = path, fg = "accent" },
          },
        },
      }
    end,
    execute = function(params, ctx)
      local path = params.path or ""
      local cwd = (ctx and ctx.cwd) or "."
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
      }
    end,
    render_result = function(result, ctx)
      if not ctx.expanded then
        -- Minimal mode: collapsed output intentionally consumes no result rows.
        return ""
      end

      local text = result.content and result.content[1] and result.content[1].text or ""
      local lines = {
        { { text = "read ", fg = "muted" }, { text = tostring(result.details and result.details.path or ""), fg = "accent", bold = true } },
      }
      for line in string.gmatch(text, "([^\n]*)\n?") do
        if line == "" and #lines > 1 then break end
        if #lines >= 21 then
          lines[#lines + 1] = { { text = "... more", fg = "muted", dim = true } }
          break
        end
        lines[#lines + 1] = { { text = line, fg = "toolOutput" } }
      end
      return { lines = lines }
    end,
  })
end

return function(zi)
  zi.define.tool({
    name = "read",
    label = "read (minimal)",
    description = "Read a text file with a minimal implementation. This intentionally overrides the builtin read tool.",
    input = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to read." },
        offset = { type = "number", description = "1-indexed first line." },
        limit = { type = "number", description = "Maximum lines to return." },
      },
      required = { "path" },
    },
    display = { call = "path" },
    run = function(ctx, input)
      local path = input.path or ""
      local cwd = ctx.env and ctx.env.cwd or "."
      local absolute = path:match("^/") and path or (cwd .. "/" .. path)
      local file, err = io.open(absolute, "r")
      if not file then
        return { content = { { type = "text", text = "Error reading file: " .. tostring(err) } }, is_error = true, metadata = { path = path } }
      end
      local lines = {}
      for line in file:lines() do lines[#lines + 1] = line end
      file:close()
      local first = math.max(1, tonumber(input.offset) or 1)
      local last = #lines
      if input.limit then last = math.min(last, first + tonumber(input.limit) - 1) end
      local out = {}
      for i = first, last do out[#out + 1] = lines[i] end
      return { content = { { type = "text", text = table.concat(out, "\n") } }, metadata = { path = path, offset = first, limit = input.limit, lines = #lines } }
    end,
  })
end

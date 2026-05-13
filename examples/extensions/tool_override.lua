return function(zi)
  local blocked = {
    "%.env$",
    "%.env%.",
    "secret",
    "credential",
  }

  local function is_blocked(path)
    for _, pattern in ipairs(blocked) do
      if string.find(path, pattern) then return true end
    end
    return false
  end

  zi.tool({
    name = "read",
    label = "read (audited)",
    description = "Read a file with a small sensitive-path gate. This intentionally overrides the builtin read tool while preserving the builtin read renderer by same-name inheritance.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to read" },
        offset = { type = "number", description = "1-indexed first line" },
        limit = { type = "number", description = "Maximum lines to return" },
      },
      required = { "path" },
    },
    execute = function(params, ctx)
      local path = params.path or ""
      if is_blocked(path) then
        return {
          content = { { type = "text", text = "Access denied: " .. path } },
          is_error = true,
          details = { blocked = true, path = path },
        }
      end

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

    -- No presentation on purpose: same-name builtin renderer fallback remains native.
  })
end

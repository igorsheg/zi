return function(zi)
  local MAX_BYTES = 50 * 1024

  local function truncate(text)
    text = tostring(text or "")
    if #text <= MAX_BYTES then return text, false end
    return text:sub(1, MAX_BYTES) .. "\n\n[output truncated]", true
  end

  zi.define.tool({
    name = "rg_demo",
    label = "ripgrep demo",
    description = "Search with ripgrep and bound the returned output.",
    input = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Search pattern." },
        path = { type = "string", description = "Path to search. Defaults to current directory." },
        glob = { type = "string", description = "Optional rg glob." },
      },
      required = { "pattern" },
    },
    display = { call = "pattern" },
    run = function(ctx, input)
      local argv = { "rg", "--line-number", "--color=never" }
      if input.glob and input.glob ~= "" then argv[#argv + 1] = "--glob"; argv[#argv + 1] = input.glob end
      argv[#argv + 1] = input.pattern
      argv[#argv + 1] = input.path or "."
      local result = ctx.process.run(argv, { cwd = ctx.env and ctx.env.cwd or ".", max_stdout_bytes = MAX_BYTES + 1024, max_stderr_bytes = 8192 })
      local output = tostring(result.stdout or "") .. tostring(result.stderr or "")
      if result.status ~= "completed" or (result.code ~= 0 and result.code ~= 1) then
        return { content = { { type = "text", text = output ~= "" and output or tostring(result.error or "rg failed") } }, is_error = true, metadata = { code = result.code, status = result.status } }
      end
      if output == "" then output = "No matches found" end
      local text, was_truncated = truncate(output)
      return { content = { { type = "text", text = text } }, metadata = { pattern = input.pattern, path = input.path, glob = input.glob, truncated = was_truncated } }
    end,
  })
end

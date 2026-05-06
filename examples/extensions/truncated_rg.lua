return function(zi)
  local MAX_LINES = 2000
  local MAX_BYTES = 50 * 1024

  local function shell_quote(value)
    local s = tostring(value or "")
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
  end

  local function format_size(bytes)
    if bytes >= 1024 * 1024 then return string.format("%.1f MiB", bytes / (1024 * 1024)) end
    if bytes >= 1024 then return string.format("%.1f KiB", bytes / 1024) end
    return tostring(bytes) .. " B"
  end

  local function line_count(text)
    if text == "" then return 0 end
    local count = 1
    for _ in string.gmatch(text, "\n") do count = count + 1 end
    if string.sub(text, -1) == "\n" then count = count - 1 end
    return count
  end

  local function truncate_head(text, max_lines, max_bytes)
    local total_bytes = #text
    local total_lines = line_count(text)
    local out = {}
    local out_bytes = 0
    local out_lines = 0

    for line in string.gmatch(text, "([^\n]*)\n?") do
      if line == "" and out_lines >= total_lines then break end
      local line_bytes = #line + 1
      if out_lines >= max_lines or out_bytes + line_bytes > max_bytes then break end
      out[#out + 1] = line
      out_lines = out_lines + 1
      out_bytes = out_bytes + line_bytes
    end

    local content = table.concat(out, "\n")
    local truncated = total_lines > out_lines or total_bytes > #content
    return {
      content = content,
      truncated = truncated,
      totalLines = total_lines,
      outputLines = out_lines,
      totalBytes = total_bytes,
      outputBytes = #content,
    }
  end

  local function write_full_output(output)
    local path = os.tmpname()
    local file = io.open(path, "w")
    if not file then return nil end
    file:write(output)
    file:close()
    return path
  end

  local function run_rg(params, cwd)
    local cmd = "cd " .. shell_quote(cwd or ".") .. " && rg --line-number --color=never"
    if params.glob and params.glob ~= "" then
      cmd = cmd .. " --glob " .. shell_quote(params.glob)
    end
    cmd = cmd .. " " .. shell_quote(params.pattern) .. " " .. shell_quote(params.path or ".") .. " 2>&1"

    local pipe = io.popen(cmd)
    if not pipe then return nil, "failed to start rg" end
    local output = pipe:read("*a") or ""
    local ok, reason, code = pipe:close()
    if ok or code == 1 then return output, nil end
    return output, "rg failed: " .. tostring(reason or code)
  end

  zi.tool({
    name = "rg_demo",
    label = "ripgrep demo",
    description = "Search with ripgrep. Output is bounded to 2000 lines or 50 KiB; truncated full output is saved to a temp file.",
    parameters = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Search pattern (regex)" },
        path = { type = "string", description = "Directory/file to search; defaults to ." },
        glob = { type = "string", description = "Optional rg glob, e.g. *.zig" },
      },
      required = { "pattern" },
    },
    render_call = function(args)
      local lines = {
        {
          { text = "rg ", fg = "toolTitle", bold = true },
          { text = '"' .. tostring(args.pattern or "") .. '"', fg = "accent" },
        },
      }
      if args.path then
        lines[1][#lines[1] + 1] = { text = " in " .. args.path, fg = "muted" }
      end
      if args.glob then
        lines[1][#lines[1] + 1] = { text = " --glob " .. args.glob, fg = "dim" }
      end
      return { lines = lines }
    end,
    execute = function(params, ctx)
      local output, err = run_rg(params, ctx and ctx.cwd or ".")
      if err then
        return {
          content = { { type = "text", text = err .. "\n" .. (output or "") } },
          is_error = true,
          details = { pattern = params.pattern, path = params.path, glob = params.glob, error = err },
        }
      end

      if not output or output == "" then
        return {
          content = { { type = "text", text = "No matches found" } },
          details = { pattern = params.pattern, path = params.path, glob = params.glob, matchCount = 0 },
        }
      end

      local trunc = truncate_head(output, MAX_LINES, MAX_BYTES)
      local match_count = line_count(output)
      local text = trunc.content
      local full_path = nil

      if trunc.truncated then
        full_path = write_full_output(output)
        local omitted_lines = trunc.totalLines - trunc.outputLines
        local omitted_bytes = trunc.totalBytes - trunc.outputBytes
        text = text .. string.format(
          "\n\n[Output truncated: showing %d of %d lines (%s of %s). %d lines (%s) omitted.%s]",
          trunc.outputLines,
          trunc.totalLines,
          format_size(trunc.outputBytes),
          format_size(trunc.totalBytes),
          omitted_lines,
          format_size(omitted_bytes),
          full_path and (" Full output saved to: " .. full_path) or ""
        )
      end

      return {
        content = { { type = "text", text = text } },
        details = {
          pattern = params.pattern,
          path = params.path,
          glob = params.glob,
          matchCount = match_count,
          truncation = trunc,
          fullOutputPath = full_path,
        },
      }
    end,
    render_result = function(result, ctx)
      local d = result.details or {}
      if d.error then
        return { lines = { { { text = d.error, fg = "error" } } } }
      end
      if not d.matchCount or d.matchCount == 0 then
        return { lines = { { { text = "No matches found", fg = "dim" } } } }
      end

      local first = {
        { text = tostring(d.matchCount) .. " matches", fg = "success", bold = true },
      }
      if d.truncation and d.truncation.truncated then
        first[#first + 1] = { text = " truncated", fg = "warning" }
      end

      local lines = { first }
      if ctx.expanded then
        local text = result.content and result.content[1] and result.content[1].text or ""
        local shown = 0
        for line in string.gmatch(text, "([^\n]*)\n?") do
          if line == "" and shown > 0 then break end
          if shown >= 20 then
            lines[#lines + 1] = { { text = "... more output", fg = "muted", dim = true } }
            break
          end
          lines[#lines + 1] = { { text = line, fg = "toolOutput" } }
          shown = shown + 1
        end
        if d.fullOutputPath then
          lines[#lines + 1] = { { text = "Full output: " .. d.fullOutputPath, fg = "dim", dim = true } }
        end
      end
      return { lines = lines }
    end,
  })
end

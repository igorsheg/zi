-- DOOM-ish TUI demo inspired by pi-mono's doom-overlay extension.
--
-- zi's current extension UI is host-owned: extensions publish reports/status/progress
-- rather than owning raw terminal surfaces. This demo proves the useful part of that
-- contract today by streaming a tiny pseudo-framebuffer into one retained report.
--
-- Usage: load examples/extensions as an extension root, then run /doom

local palette = {
  " ", " ", ".", ".", ":", ":", "-", "=", "+", "*", "#", "%", "@",
}

local logo = {
  "██████╗  ██████╗  ██████╗ ███╗   ███╗",
  "██╔══██╗██╔═══██╗██╔═══██╗████╗ ████║",
  "██║  ██║██║   ██║██║   ██║██╔████╔██║",
  "██║  ██║██║   ██║██║   ██║██║╚██╔╝██║",
  "██████╔╝╚██████╔╝╚██████╔╝██║ ╚═╝ ██║",
  "╚═════╝  ╚═════╝  ╚═════╝ ╚═╝     ╚═╝",
}

local function make_grid(width, height)
  local cells = {}
  for i = 1, width * height do cells[i] = 1 end
  return cells
end

local function idx(x, y, width)
  return (y - 1) * width + x
end

local function step_fire(cells, width, height, frame)
  for x = 1, width do
    local heat = #palette - ((x + frame) % 4)
    if ((x * 17 + frame * 11) % 19) == 0 then heat = math.max(5, heat - 4) end
    cells[idx(x, height, width)] = heat
  end

  for y = 1, height - 1 do
    for x = 1, width do
      local below = cells[idx(x, y + 1, width)] or 1
      local left = cells[idx(math.max(1, x - 1), y + 1, width)] or below
      local right = cells[idx(math.min(width, x + 1), y + 1, width)] or below
      local decay = ((x * 3 + y * 5 + frame) % 3)
      local value = math.floor((below + left + right) / 3) - decay
      if value < 1 then value = 1 end
      cells[idx(x, y, width)] = value
    end
  end
end

local function render(cells, width, height, frame)
  local lines = {}
  lines[#lines + 1] = "╔" .. string.rep("═", width) .. "╗"
  for y = 1, height do
    local line = {}
    for x = 1, width do
      line[#line + 1] = palette[cells[idx(x, y, width)] or 1]
    end
    lines[#lines + 1] = "║" .. table.concat(line) .. "║"
  end
  lines[#lines + 1] = "╚" .. string.rep("═", width) .. "╝"
  lines[#lines + 1] = ""
  for _, l in ipairs(logo) do lines[#lines + 1] = l end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("frame %03d  —  not Chocolate Doom yet; this is an extension-owned report framebuffer", frame)
  return table.concat(lines, "\n")
end

zi.register_command({
  name = "doom",
  description = "Run a small DOOM-style animated TUI demo.",
  handler = function(_, ctx)
    if not ctx.has_ui or not ctx.ui then
      return "The /doom demo needs the interactive TUI."
    end

    local width, height = 64, 18
    local cells = make_grid(width, height)
    ctx.ui.progress({ id = "doom-demo", status = "running", title = "DOOM demo", indeterminate = true })

    for frame = 1, 90 do
      step_fire(cells, width, height, frame)
      ctx.ui.report({
        id = "doom-demo",
        title = "DOOM in zi (extension demo)",
        body = render(cells, width, height, frame),
        transient = true,
      })
      -- Keep the agent thread yieldable while giving the TUI time to repaint.
      zi.system({ "/bin/sh", "-c", "sleep 0.033" }, { timeout_ms = 250, max_stdout_bytes = 1, max_stderr_bytes = 1 })
    end

    ctx.ui.progress({ id = "doom-demo", status = "done", title = "DOOM demo", text = "finished" })
    ctx.ui.message("DOOM demo finished. Next step: a raw canvas/input surface for real games.", { kind = "success" })
  end,
})

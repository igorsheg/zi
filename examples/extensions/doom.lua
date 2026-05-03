-- DOOM-ish helper-backed framebuffer demo.
--
-- Lua owns orchestration and input. zi owns helper stdout frame decoding and
-- host-owned surface rendering.

local surface_id = "doom-demo"
local current_job = nil

local function helper_path(ctx)
  return (ctx.cwd or ".") .. "/zig-out/bin/zi-doom-helper"
end

local function boot_frame(width, height)
  local chunks, n = {}, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r = math.floor(20 + 80 * y / height)
      local g = math.floor(20 + 60 * x / width)
      local b = 90
      if math.floor(x / 4 + y / 4) % 2 == 0 then r, g, b = 80, 220, 80 end
      n = n + 1
      chunks[n] = string.char(r, g, b, 255)
    end
  end
  return table.concat(chunks)
end

zi.on("surface_input", function(event, ctx)
  if event.id ~= surface_id then return end
  if not current_job then return end
  zi.job.write(current_job.id, "KEY " .. event.key .. "\n")
  if ctx and ctx.ui and ctx.ui.status then
    ctx.ui.status({ id = "doom-input", text = "surface input: " .. event.key, lifetime = "until_input" })
  end
end)

zi.on("job_stderr", function(event, ctx)
  if not current_job or event.id ~= current_job.id then return end
  if ctx.ui and ctx.ui.message and event.data and #event.data > 0 then
    ctx.ui.message(event.data, { kind = "warning", id = "doom-stderr" })
  end
end)

zi.on("job_exit", function(event, ctx)
  if not current_job or event.id ~= current_job.id then return end
  current_job = nil
  if ctx.ui then
    if ctx.ui.progress then ctx.ui.progress({ id = surface_id, status = "done", title = "DOOM helper", text = "stopped" }) end
    if ctx.ui.message then ctx.ui.message("DOOM helper stopped", { kind = "info" }) end
  end
end)

zi.register_command({
  name = "doom",
  description = "Run the helper-backed DOOM-style framebuffer demo.",
  handler = function(_, ctx)
    if not ctx.has_ui or not ctx.ui or not ctx.ui.surface_open then
      if ctx.ui and ctx.ui.message then
        ctx.ui.message("/doom needs a zi build with extension surfaces", { kind = "warning" })
      end
      return
    end

    if current_job then
      zi.job.stop(current_job.id)
      current_job = nil
    end

    ctx.ui.surface_open({
      id = surface_id,
      title = "DOOM in zi",
      width = 96,
      height = 54,
      format = "rgba8888",
      input = { keyboard = true },
    })
    ctx.ui.progress({ id = surface_id, status = "running", title = "DOOM helper", indeterminate = true })
    ctx.ui.surface_frame({
      id = surface_id,
      width = 96,
      height = 54,
      format = "rgba8888",
      data = boot_frame(96, 54),
    })

    local path = helper_path(ctx)
    current_job = zi.job.start({
      argv = { path },
      cwd = ctx.cwd,
      stdout = {
        mode = "surface_frame",
        protocol = "zi-rgba-frame-v1",
        surface = surface_id,
        max_frame_bytes = 96 * 54 * 4 + 64,
      },
    })
    ctx.ui.message("DOOM helper started. Use arrows/WASD, space/enter. Esc returns focus to editor.", { kind = "success" })
  end,
})

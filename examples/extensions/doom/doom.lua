-- DOOM helper-backed framebuffer demo.
--
-- Lua owns orchestration and input. zi owns helper stdout frame decoding and
-- host-owned surface rendering. The helper owns the DOOM engine and streams
-- raw rgba8888 frames using zi-rgba-frame-v1.

local surface_id = "doom-demo"
local current_job = nil
local width, height = 100, 31

local function extension_root(ctx)
  if ctx.extension and ctx.extension.root then return ctx.extension.root end
  return (ctx.cwd or ".") .. "/examples/extensions/doom"
end

local function helper_path(ctx)
  return extension_root(ctx) .. "/helper/zi-doom-helper.js"
end

local function boot_frame(w, h)
  return string.rep(string.char(8, 8, 12, 8, 8, 12), w * h)
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

zi.on("surface_input", function(event, ctx)
  if event.id ~= surface_id then return end
  if not current_job then return end
  if event.key == "q" or event.key == "Q" then
    zi.job.stop(current_job.id)
    current_job = nil
    if ctx and ctx.ui and ctx.ui.surface_close then ctx.ui.surface_close({ id = surface_id }) end
    return
  end
  -- zi routes focused surface keys directly to the surface job for low-latency
  -- game input. This observer remains useful for extension-side diagnostics or
  -- custom policies, but it intentionally does not duplicate input to stdin.
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

zi.on("session_shutdown", function(_, ctx)
  if current_job then
    zi.job.stop(current_job.id)
    current_job = nil
  end
  if ctx.ui and ctx.ui.surface_close then ctx.ui.surface_close({ id = surface_id }) end
end)

zi.command({
  name = "doom",
  description = "Play DOOM in a zi surface. Optional: /doom /path/to/doom1.wad",
  handler = function(args, ctx)
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
      width = width,
      height = height,
      format = "halfblock_rgb",
      input = { keyboard = true },
    })
    ctx.ui.progress({ id = surface_id, status = "running", title = "DOOM helper", indeterminate = true })
    ctx.ui.surface_frame({
      id = surface_id,
      width = width,
      height = height,
      format = "halfblock_rgb",
      data = boot_frame(width, height),
    })

    local path = helper_path(ctx)
    local argv = { path }
    local wad = trim(args)
    if wad ~= "" then
      argv[#argv + 1] = "--wad"
      argv[#argv + 1] = wad
    end
    current_job = zi.job.start({
      argv = argv,
      cwd = extension_root(ctx),
      stdout = {
        mode = "ui_frame",
        view = "doom-workbench",
        node = surface_id,
        protocol = "zi-rgba-frame-v1",
        max_frame_bytes = width * height * 4 + 64,
      },
    })
    ctx.ui.message("DOOM helper started. Arrows/WASD move, F fires, Space uses, Q quits, Esc returns focus.", { kind = "success" })
  end,
})

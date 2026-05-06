-- DOOM helper-backed framebuffer demo using v3 ctx.ui.render/frame.

local view_id = "doom-workbench"
local node_id = "doom-demo"
local current_job = nil
local width, height = 100, 31

local function extension_root(ctx)
  if ctx.extension and ctx.extension.root then return ctx.extension.root end
  return (ctx.cwd or ".") .. "/examples/extensions/doom"
end

local function helper_path(ctx) return extension_root(ctx) .. "/helper/zi-doom-helper.js" end
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function boot_frame(w, h) return string.rep(string.char(8, 8, 12, 8, 8, 12), w * h) end

local function toast(ctx, text, tone)
  if ctx and ctx.ui and ctx.ui.render then
    ctx.ui.render({ id = "doom-toast", target = { kind = "toast", anchor = "top_right", lifetime = "until_input" }, root = { type = "text", text = text, style = { tone = tone or "info" } } })
  end
end

local function close(ctx)
  if current_job then zi.job.stop(current_job.id); current_job = nil end
  if ctx and ctx.ui and ctx.ui.render then ctx.ui.render({ id = view_id, remove = true }) end
end

local function render_workbench(ctx)
  ctx.ui.render({
    id = view_id,
    title = "DOOM in zi",
    target = { kind = "overlay", width = "92%", max_height = "90%", anchor = "center", backdrop = "dim" },
    focus = true,
    keys = {
      { key = "escape", action = "close" }, { key = "q", action = "close" },
      { key = "left", action = "key" }, { key = "right", action = "key" }, { key = "up", action = "key" }, { key = "down", action = "key" },
      { key = "w", action = "key" }, { key = "a", action = "key" }, { key = "s", action = "key" }, { key = "d", action = "key" },
      { key = "space", action = "key" }, { key = "enter", action = "key" }, { key = "f", action = "key" },
    },
    root = { type = "box", style = { border = true, padding = 1 }, children = {
      { type = "text", text = "Arrows/WASD move, F fires, Space uses, Q/Esc closes." },
      { type = "surface", id = node_id, style = { width = width, height = height } },
    } },
  })
  ctx.ui.frame({ view = view_id, node = node_id, width = width, height = height, format = "halfblock_rgb", data = boot_frame(width, height) })
end

zi.on("ui", function(event, ctx)
  if event.view ~= view_id then return end
  if event.action == "close" or event.key == "escape" or event.key == "q" then close(ctx); return end
  if current_job and event.key then zi.job.write(current_job.id, "KEY " .. event.key .. "\n") end
end)

zi.on("job_stderr", function(event, ctx)
  if current_job and event.id == current_job.id and event.data and #event.data > 0 then toast(ctx, event.data, "warning") end
end)

zi.on("job_exit", function(event, ctx)
  if not current_job or event.id ~= current_job.id then return end
  current_job = nil
  toast(ctx, "DOOM helper stopped", "info")
end)

zi.on("session_shutdown", function(_, ctx) close(ctx) end)

zi.command({
  name = "doom",
  description = "Play DOOM in a zi v3 UI workbench. Optional: /doom /path/to/doom1.wad",
  handler = function(args, ctx)
    if not ctx.has_ui or not ctx.ui or not ctx.ui.render or not ctx.ui.frame then return end
    close(ctx)
    render_workbench(ctx)
    local argv = { helper_path(ctx) }
    local wad = trim(args)
    if wad ~= "" then argv[#argv + 1] = "--wad"; argv[#argv + 1] = wad end
    current_job = zi.job.start({ argv = argv, cwd = extension_root(ctx), stdout = { mode = "ui_frame", view = view_id, node = node_id, protocol = "zi-rgba-frame-v1", max_frame_bytes = width * height * 4 + 64 } })
    toast(ctx, "DOOM helper started", "success")
  end,
})

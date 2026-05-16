return function(zi)
-- DOOM helper-backed framebuffer demo using v3 ctx.ui.view.set/frame.

local view_id = "doom-workbench"
local node_id = "doom-demo"
local current_job = nil
local width, height = 100, 31

local function extension_root(ctx)
  if ctx.extension and ctx.extension.root then return ctx.extension.root end
  return (ctx.env.cwd or ".") .. "/examples/extensions/doom"
end

local function helper_path(ctx) return extension_root(ctx) .. "/helper/zi-doom-helper.js" end
local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function boot_frame(w, h) return string.rep(string.char(8, 8, 12, 8, 8, 12), w * h) end
local function is_dangerous_wad_path(wad) return wad == "/" or wad:match("^/+$") ~= nil end

local function toast(ctx, text, tone)
  if ctx and ctx.ui and ctx.ui.notify then
    local level = tone or "info"
    if level == "danger" then level = "error" end
    ctx.ui.notify.show(tostring(text or ""), { id = "doom-notice", group = "doom", level = level })
  end
end

local function close(ctx)
  if current_job then ctx.process.job(current_job.id); current_job = nil end
  if ctx and ctx.ui and ctx.ui.view.set then ctx.ui.view.set({ id = view_id, remove = true }) end
end

local function render_workbench(ctx)
  ctx.ui.view.set({
    id = view_id,
    slot = { kind = "overlay", width = "92%", max_height = "90%", anchor = "center", backdrop = "dim" },
    focus = true,
    keys = {
      { key = "escape", action = "close" }, { key = "q", action = "close" },
      { key = "left", action = "key" }, { key = "right", action = "key" }, { key = "up", action = "key" }, { key = "down", action = "key" },
      { key = "w", action = "key" }, { key = "a", action = "key" }, { key = "s", action = "key" }, { key = "d", action = "key" },
      { key = "space", action = "key" }, { key = "enter", action = "key" }, { key = "f", action = "key" },
    },
    root = { type = "view", style = { chrome = { kind = "frame", title = "DOOM in zi", border = "rounded", tone = "muted" }, padding = 1 }, children = {
      { type = "text", text = "Arrows/WASD move, F fires, Space uses, Q/Esc closes." },
      { type = "surface", id = node_id, style = { width = width, height = height } },
    } },
  })
  ctx.ui.surface.frame({ view = view_id, node = node_id, width = width, height = height, format = "halfblock_rgb", data = boot_frame(width, height) })
end

zi.define.event("ui", function(ctx, event)
  if event.view ~= view_id then return end
  if event.action == "close" or event.key == "escape" or event.key == "q" then close(ctx); return end
  if current_job and event.key then ctx.process.job(current_job.id, "KEY " .. event.key .. "\n") end
end)

zi.define.event("job_stderr", function(ctx, event)
  if current_job and event.id == current_job.id and event.data and #event.data > 0 then toast(ctx, event.data:sub(1, 240), "warning") end
end)

zi.define.event("job_exit", function(ctx, event)
  if not current_job or event.id ~= current_job.id then return end
  current_job = nil
  toast(ctx, "DOOM helper stopped", "info")
end)

zi.define.event("session_shutdown", function(ctx, _) close(ctx) end)

zi.define.command({
  name = "doom",
  description = "Play DOOM in a zi v4 UI workbench. Optional: /doom /path/to/doom1.wad",
  run = function(ctx, args)
    if not ctx.capabilities().ui or not ctx.ui or not ctx.ui.view.set or not ctx.ui.surface.frame then return end
    close(ctx)
    render_workbench(ctx)
    local argv = { "/usr/bin/env", "node", helper_path(ctx) }
    local wad = trim(args)
    if is_dangerous_wad_path(wad) then toast(ctx, "Refusing to use a directory as a WAD path", "error"); return end
    if wad ~= "" then argv[#argv + 1] = "--wad"; argv[#argv + 1] = wad end
    current_job = ctx.process.start({ argv = argv, cwd = extension_root(ctx), stdout = { mode = "ui_frame", view = view_id, node = node_id, state_owner_id = ctx.binding and ctx.binding.state_owner_id or nil, protocol = "zi-halfblock-rgb-v1", max_frame_bytes = width * height * 6 + 64 } })
    toast(ctx, "DOOM helper started", "success")
  end,
})
end

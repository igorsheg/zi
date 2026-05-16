return function(zi)
-- session-breadkown: Zi-native port of pi's session-breakdown dashboard.
-- Uses API v4 only: zi.define.command, zi.define.event, ctx.process.run, zi.json, ctx.ui.view.set, ctx.ui.surface.frame.

local VIEW = "session-breadkown"
local GRAPH = "session-breadkown-graph"
local ranges = { 7, 30, 90 }
local metrics = { "sessions", "messages", "tokens" }
local views = { "model", "cwd", "dow", "tod" }
local palette = {
  { 64, 196, 99 },   -- green
  { 47, 129, 247 },  -- blue
  { 163, 113, 247 }, -- purple
  { 255, 159, 10 },  -- orange
  { 244, 67, 54 },   -- red
}
local empty = { 22, 27, 34 }
local bg = { 13, 17, 23 }
local other = { 160, 160, 160 }
local dow_colors = {
  Mon = { 47, 129, 247 }, Tue = { 64, 196, 99 }, Wed = { 163, 113, 247 },
  Thu = { 47, 175, 200 }, Fri = { 100, 200, 150 }, Sat = { 255, 159, 10 }, Sun = { 244, 67, 54 },
}
local tod_colors = {
  ["after-midnight"] = { 100, 60, 180 }, morning = { 255, 200, 50 }, afternoon = { 64, 196, 99 }, evening = { 47, 129, 247 }, night = { 60, 40, 140 },
}

local state = { data = nil, range_i = 2, metric_i = 1, view_i = 1, open = false, busy = false }

local function trim(s) return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function current_range() return ranges[state.range_i] or 30 end
local function current_metric() return metrics[state.metric_i] or "sessions" end
local function current_view() return views[state.view_i] or "model" end
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi else return x end end
local function mix(a, b, t) return { math.floor(a[1] + (b[1] - a[1]) * t + 0.5), math.floor(a[2] + (b[2] - a[2]) * t + 0.5), math.floor(a[3] + (b[3] - a[3]) * t + 0.5) } end
local function count(n)
  n = tonumber(n or 0) or 0
  if n >= 1000000000 then return string.format("%.1fB", n / 1000000000) end
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.1fK", n / 1000) end
  return tostring(math.floor(n + 0.5))
end
local function usd(n)
  n = tonumber(n or 0) or 0
  if n >= 1 then return string.format("$%.2f", n) end
  if n >= 0.1 then return string.format("$%.3f", n) end
  return string.format("$%.4f", n)
end
local function per_day(n, days)
  n = tonumber(n or 0) or 0
  days = math.max(1, tonumber(days or 1) or 1)
  return n / days
end
local function hex(c) return string.format("#%02x%02x%02x", c[1], c[2], c[3]) end
local function basename_model(k)
  local s = tostring(k or "")
  local i = s:match("^.*()/")
  return i and s:sub(i + 1) or s
end
local function abbrev_path(p)
  p = tostring(p or "unknown")
  local home = os.getenv("HOME") or ""
  if home ~= "" and p:sub(1, #home) == home then p = "~" .. p:sub(#home + 1) end
  if #p <= 42 then return p end
  local parts = {}
  for part in p:gmatch("[^/]+") do parts[#parts + 1] = part end
  if #parts <= 2 then return p:sub(1, 39) .. "..." end
  return parts[1] .. "/.../" .. parts[#parts - 1] .. "/" .. parts[#parts]
end
local function pad_right(s, n) s = tostring(s or ""); if #s > n then return s:sub(1, n) end; return s .. string.rep(" ", n - #s) end
local function pad_left(s, n) s = tostring(s or ""); if #s > n then return s:sub(1, n) end; return string.rep(" ", n - #s) .. s end

local function toast(ctx, text, tone)
  if ctx and ctx.ui and ctx.ui.notify then
    local level = tone or "info"
    if level == "danger" then level = "error" end
    ctx.ui.notify.show(tostring(text or ""), { id = VIEW .. "-notice", level = level })
  end
end

local function helper_path(ctx)
  if ctx.extension and ctx.extension.root then return ctx.extension.root .. "/helper.py" end
  return (ctx.env.cwd or ".") .. "/examples/session-breadkown/helper.py"
end

local function selected_range()
  if not state.data then return nil end
  return state.data.ranges[tostring(current_range())]
end

local function metric_for_range(range, metric)
  if metric == "tokens" and (range.totals.tokens or 0) > 0 then return "tokens" end
  if (metric == "tokens" or metric == "messages") and (range.totals.messages or 0) > 0 then return "messages" end
  return "sessions"
end

local function sorted_breakdown(range, view, metric)
  local b = (range.breakdowns and range.breakdowns[view]) or {}
  local rows = {}
  for key, vals in pairs(b) do rows[#rows + 1] = { key = key, vals = vals, value = tonumber(vals[metric] or 0) or 0 } end
  table.sort(rows, function(a, b)
    if a.value == b.value then return tostring(a.key) < tostring(b.key) end
    return a.value > b.value
  end)
  return rows
end

local function popularity_metric_for(b)
  for _, metric in ipairs({ "cost", "tokens", "messages", "sessions" }) do
    for _, vals in pairs(b or {}) do
      if (tonumber((vals or {})[metric] or 0) or 0) > 0 then return metric end
    end
  end
  return "sessions"
end

local function popularity_breakdown(view)
  local source = state.data and state.data.ranges and (state.data.ranges["30"] or selected_range()) or selected_range()
  local b = (source and source.breakdowns and source.breakdowns[view]) or {}
  local metric = popularity_metric_for(b)
  local rows = {}
  for key, vals in pairs(b) do rows[#rows + 1] = { key = key, vals = vals, value = tonumber(vals[metric] or 0) or 0 } end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return tostring(a.key) < tostring(b.key)
  end)
  return rows
end

local function color_maps(range, view, metric)
  if view == "dow" then return dow_colors, {} end
  if view == "tod" then return tod_colors, {} end
  -- Match pi: model/cwd hues come from 30d popularity, independent of
  -- the currently selected range/metric. Prefer cost, then tokens, then
  -- messages, then sessions so spendful buckets keep stable colors.
  local rows = popularity_breakdown(view)
  local map, order = {}, {}
  for i = 1, math.min(4, #rows) do map[rows[i].key] = palette[i]; order[#order + 1] = rows[i].key end
  return map, order
end

local function weighted_day_color(day, view, metric, cmap)
  if view == "dow" then
    local y, m, d = day.date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local names = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    return dow_colors[names[tonumber(os.date("%w", t)) + 1]] or other
  end
  local bucket = day[view] or {}
  local total, r, g, b = 0, 0, 0, 0
  for key, vals in pairs(bucket) do
    local w = tonumber(vals[metric] or vals.sessions or 0) or 0
    if w > 0 then
      local c = cmap[key] or other
      total = total + w; r = r + c[1] * w; g = g + c[2] * w; b = b + c[3] * w
    end
  end
  if total <= 0 then return empty end
  return { math.floor(r / total + 0.5), math.floor(g / total + 0.5), math.floor(b / total + 0.5) }
end

local function weekday_row(date)
  local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local w = tonumber(os.date("%w", t)) -- Sun=0
  return (w + 6) % 7 -- Mon=0
end

local function graph_frame(range, view, metric)
  local days = range.days or {}
  local selected_days = #days
  local first_offset = (#days > 0) and weekday_row(days[1].date) or 0
  local weeks = math.max(1, math.ceil((first_offset + #days) / 7))

  -- Match the original pi session-breakdown's GitHub-contributions feel:
  -- each week is a column, each weekday is a row, with wider cells on
  -- shorter ranges and one blank column between weeks.
  local cell_width = selected_days <= 7 and 4 or (selected_days <= 30 and 3 or 2)
  local gap = 1
  local width, height = math.max(1, weeks * cell_width + math.max(0, weeks - 1) * gap), 7

  local maxv = 0
  for _, day in ipairs(days) do maxv = math.max(maxv, tonumber(day[metric] or 0) or 0) end
  local denom = math.log(1 + math.max(1, maxv))
  local cmap = color_maps(range, view, metric)
  local cells = {}
  for y = 1, height do
    cells[y] = {}
    for x = 1, width do cells[y][x] = empty end
  end
  for i, day in ipairs(days) do
    local pos = first_offset + i - 1
    local week = math.floor(pos / 7)
    local row = pos % 7
    local x0 = week * (cell_width + gap) + 1
    local value = tonumber(day[metric] or 0) or 0
    local c = empty
    if value > 0 then
      local hue = weighted_day_color(day, view, metric, cmap)
      local t = clamp(math.log(1 + value) / denom, 0, 1)
      c = mix(bg, hue, 0.2 + 0.8 * t)
    end
    for dx = 0, cell_width - 1 do
      cells[row + 1][x0 + dx] = c
    end
  end
  local chunks = {}
  for y = 1, height do
    for x = 1, width do
      local c = cells[y][x]
      chunks[#chunks + 1] = string.char(c[1], c[2], c[3], c[1], c[2], c[3])
    end
  end
  return width, height, table.concat(chunks)
end

local function date_span(range)
  local days = range.days or {}
  if #days == 0 then return "no days" end
  return tostring(days[1].date) .. " → " .. tostring(days[#days].date)
end

local function peak_day(range, metric)
  local best, bestv = nil, -1
  for _, day in ipairs(range.days or {}) do
    local v = tonumber(day[metric] or 0) or 0
    if v > bestv then best, bestv = day, v end
  end
  return best, bestv
end

local function summary_line(range, days, metric)
  local t = range.totals or {}
  if metric == "tokens" then return string.format("Last %dd: %s sessions · %s tokens · %s", days, count(t.sessions), count(t.tokens), usd(t.cost)) end
  if metric == "messages" then return string.format("Last %dd: %s sessions · %s messages · %s", days, count(t.sessions), count(t.messages), usd(t.cost)) end
  return string.format("Last %dd: %s sessions · %s", days, count(t.sessions), usd(t.cost))
end

local function kpi_text(range, days)
  local t = range.totals or {}
  local token_line
  if (tonumber(t.tokens or 0) or 0) > 0 then
    token_line = string.format("tokens/day   %9s   %s total", count(per_day(t.tokens, days)), count(t.tokens))
  else
    token_line = string.format("tokens/day   %9s   fallback: %s messages/day (token usage unavailable)", "—", count(per_day(t.messages, days)))
  end
  return table.concat({
    string.format("sessions/day %9s   %s total", count(per_day(t.sessions, days)), count(t.sessions)),
    string.format("messages/day %9s   %s total", count(per_day(t.messages, days)), count(t.messages)),
    token_line,
    string.format("cost/day     %9s   %s total", usd(per_day(t.cost, days)), usd(t.cost)),
  }, "\n")
end

local function story_text(range, days, view, metric)
  local best, bestv = peak_day(range, metric)
  local rows = sorted_breakdown(range, view, metric)
  local top = rows[1]
  local top_label = top and (view == "model" and basename_model(top.key) or (view == "cwd" and abbrev_path(top.key) or top.key)) or "no dominant bucket"
  if view == "tod" and top and state.data and state.data.tod_labels and state.data.tod_labels[top.key] then top_label = state.data.tod_labels[top.key] end
  if view == "dow" then
    return string.format("Weekday bars show the last %d days by %s, in fixed Monday→Sunday order.\nWindow: %s · peak: %s with %s %s · top weekday: %s", days, metric, date_span(range), best and best.date or "n/a", count(bestv), metric, top_label)
  end
  return string.format("The heatmap tells the last %d days as color + intensity: brighter means more %s; hue follows %s.\nWindow: %s · peak: %s with %s %s · top %s: %s", days, metric, view, date_span(range), best and best.date or "n/a", count(bestv), metric, view, top_label)
end

local function graph_summary(range, days, metric)
  local best, bestv = peak_day(range, metric)
  return string.format("%s · peak %s %s on %s · %s", date_span(range), count(bestv), metric, best and best.date or "n/a", summary_line(range, days, metric))
end

local function ordered_keys(view)
  if view == "dow" then return (state.data and state.data.dow_order) or { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" } end
  if view == "tod" then return (state.data and state.data.tod_order) or { "after-midnight", "morning", "afternoon", "evening", "night" } end
  return nil
end

local function view_label(view, key)
  if view == "model" then return basename_model(key) end
  if view == "cwd" then return abbrev_path(key) end
  if view == "tod" and state.data and state.data.tod_labels and state.data.tod_labels[key] then return state.data.tod_labels[key] end
  return tostring(key or "")
end

local function dow_bar_text(range, metric)
  local b = (range.breakdowns and range.breakdowns.dow) or {}
  local total = tonumber((range.totals or {})[metric] or 0) or 0
  local maxv = 0
  for _, key in ipairs(ordered_keys("dow")) do maxv = math.max(maxv, tonumber((b[key] or {})[metric] or 0) or 0) end
  local out = { "Weekday distribution" }
  for _, key in ipairs(ordered_keys("dow")) do
    local vals = b[key] or {}
    local value = tonumber(vals[metric] or 0) or 0
    local n = maxv > 0 and math.floor(value * 28 / maxv + 0.5) or 0
    local share = total > 0 and string.format("%3d%%", math.floor(value * 100 / total + 0.5)) or "  0%"
    local bar = string.rep("█", n) .. string.rep(" ", 28 - n)
    out[#out + 1] = string.format("%-3s %s %9s %s", key, bar, count(value), share)
  end
  return table.concat(out, "\n")
end

local function table_text(range, view, metric)
  local b = (range.breakdowns and range.breakdowns[view]) or {}
  local rows = {}
  local order = ordered_keys(view)
  if order then
    for _, key in ipairs(order) do
      local vals = b[key] or { sessions = 0, messages = 0, tokens = 0, cost = 0.0 }
      rows[#rows + 1] = { key = key, vals = vals, value = tonumber(vals[metric] or 0) or 0 }
    end
  else
    rows = sorted_breakdown(range, view, metric)
  end
  local out = {}
  local name_header = view == "cwd" and "directory" or (view == "dow" and "weekday" or (view == "tod" and "time of day" or view))
  out[#out + 1] = pad_right(name_header, 42) .. "  " .. pad_left(metric, 9) .. "  " .. pad_left("cost", 9) .. "  " .. pad_left("share", 5)
  out[#out + 1] = string.rep("-", 42) .. "  " .. string.rep("-", 9) .. "  " .. string.rep("-", 9) .. "  " .. string.rep("-", 5)
  local total = tonumber((range.totals or {})[metric] or 0) or 0
  local limit = order and #rows or math.min(8, #rows)
  for i = 1, limit do
    local row = rows[i]
    local vals = row.vals or {}
    local value = tonumber(vals[metric] or 0) or 0
    local share = total > 0 and string.format("%d%%", math.floor(value * 100 / total + 0.5)) or "0%"
    out[#out + 1] = pad_right(view_label(view, row.key), 42) .. "  " .. pad_left(count(value), 9) .. "  " .. pad_left(usd(vals.cost), 9) .. "  " .. pad_left(share, 5)
  end
  if #rows == 0 then out[#out + 1] = "(no data found)" end
  return table.concat(out, "\n")
end

local function legend_spans(range, view, metric)
  local cmap, order = color_maps(range, view, metric)
  local spans = { { text = "legend ", style = { tone = "accent", bold = true } } }
  local function item(label, color)
    spans[#spans + 1] = { text = "■ ", style = { fg = hex(color), bold = true } }
    spans[#spans + 1] = { text = label .. "  ", style = { dim = true } }
  end
  if view == "dow" then
    for _, k in ipairs({ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }) do item(k, dow_colors[k]) end
    return spans
  end
  if view == "tod" then
    for _, k in ipairs({ "after-midnight", "morning", "afternoon", "evening", "night" }) do item(k, tod_colors[k]) end
    return spans
  end
  if #(order or {}) == 0 then
    spans[#spans + 1] = { text = "no " .. view .. " data", style = { dim = true } }
    return spans
  end
  for _, key in ipairs(order or {}) do item(view == "model" and basename_model(key) or abbrev_path(key), cmap[key] or other) end
  item("other", other)
  return spans
end


local function legend_side_spans(range, view, metric)
  local cmap, order = color_maps(range, view, metric)
  local spans = { { text = "legend\n", style = { tone = "accent", bold = true } } }
  local function item(label, color)
    spans[#spans + 1] = { text = "■ ", style = { fg = hex(color), bold = true } }
    spans[#spans + 1] = { text = label .. "\n", style = { dim = true } }
  end
  if view == "tod" then
    for _, k in ipairs(ordered_keys("tod")) do item(view_label("tod", k), tod_colors[k] or other) end
  elseif view == "dow" then
    for _, k in ipairs(ordered_keys("dow")) do item(k, dow_colors[k] or other) end
  else
    for _, key in ipairs(order or {}) do item(view_label(view, key), cmap[key] or other) end
    if #(order or {}) > 0 then item("other", other) else spans[#spans + 1] = { text = "no " .. view .. " data", style = { dim = true } } end
  end
  return spans
end

local function text_node(text, tone)
  return { type = "text", text = tostring(text or ""), style = tone and { tone = tone } or nil }
end

local function tab_header_spans(days, requested_metric, metric, view)
  local spans = { { text = "Session breakdown  ", style = { tone = "accent", bold = true } } }
  local function tab(label, active, tone)
    spans[#spans + 1] = { text = " " .. label .. " ", style = active and { bg = "#30363d", tone = tone or "accent", bold = true } or { dim = true } }
    spans[#spans + 1] = { text = " " }
  end
  spans[#spans + 1] = { text = "range ", style = { dim = true } }
  for _, d in ipairs(ranges) do tab(tostring(d) .. "d", d == days, "success") end
  spans[#spans + 1] = { text = "  metric ", style = { dim = true } }
  for _, m in ipairs(metrics) do tab(m .. ((m == requested_metric and requested_metric ~= metric) and "→" .. metric or ""), m == requested_metric, "info") end
  spans[#spans + 1] = { text = "  view ", style = { dim = true } }
  for _, v in ipairs(views) do tab(v, v == view, "warning") end
  return spans
end

local function render(ctx)
  if not (ctx and ctx.ui and ctx.ui.view.set) then return end
  if not state.data then return end
  local range = selected_range(); if not range then return end
  local days = current_range()
  local requested_metric = current_metric()
  local metric = metric_for_range(range, requested_metric)
  local view = current_view()
  local help = "←/→ range · ↑/↓ view · tab metric · 1/2/3 direct range · q/esc close"
  local gw, gh, frame = nil, nil, nil
  local graph_node
  local below_legend = nil
  if view == "dow" then
    -- DOW intentionally uses pi's weekday distribution bars, not the
    -- contribution heatmap used by model/cwd/tod.
    graph_node = { type = "text", text = dow_bar_text(range, metric), wrap = "none" }
    below_legend = { type = "text", spans = legend_spans(range, view, metric), wrap = "none" }
  else
    gw, gh, frame = graph_frame(range, view, metric)
    graph_node = { type = "view", style = { flex_direction = "row", gap = 2, height = gh }, children = {
      { type = "text", text = "Mon\n\nWed\n\nFri", wrap = "none", style = { width = 4, height = gh, dim = true } },
      { type = "surface", id = GRAPH, style = { width = gw, height = gh } },
      { type = "text", spans = legend_side_spans(range, view, metric), wrap = "none", style = { flex_grow = 1 } },
    } }
  end
  local children = {
    { type = "text", spans = tab_header_spans(days, requested_metric, metric, view), wrap = "none" },
    text_node(help, "info"),
    { type = "view", style = { flex_direction = "row", gap = 2 }, children = {
      { type = "text", text = kpi_text(range, days), wrap = "none", style = { width = 46 } },
      { type = "text", text = story_text(range, days, view, metric), wrap = "word", style = { flex_grow = 1 } },
    } },
    { type = "view", style = { gap = 0 }, children = {
      { type = "text", text = graph_summary(range, days, metric) .. string.format(" · parsed %s/%s files", count(state.data.sessions_parsed), count(state.data.files_scanned)), wrap = "none", style = { dim = true } },
      graph_node,
    } },
  }
  if below_legend then children[#children + 1] = below_legend end
  children[#children + 1] = { type = "text", text = table_text(range, view, metric), wrap = "none" }
  local root = { type = "view", style = { chrome = { kind = "frame", title = "Session breakdown", border = "rounded", tone = "muted" }, padding = 1, gap = 1 }, children = children }
  ctx.ui.view.set({
    id = VIEW,
    slot = { kind = "overlay", width = "92%", max_height = "90%", anchor = "center", backdrop = "dim" },
    focus = true,
    keys = {
      { key = "escape", action = "close" }, { key = "q", action = "close" },
      { key = "left", action = "range-prev" }, { key = "right", action = "range-next" },
      { key = "up", action = "view-prev" }, { key = "down", action = "view-next" },
      { key = "tab", action = "metric-next" },
      { key = "1", action = "range-7" }, { key = "2", action = "range-30" }, { key = "3", action = "range-90" },
    },
    root = root,
  })
  if view ~= "dow" and ctx.ui.surface.frame then ctx.ui.surface.frame({ view = VIEW, node = GRAPH, width = gw, height = gh, format = "halfblock_rgb", data = frame }) end
  state.open = true
end

local function close(ctx)
  state.open = false
  if ctx and ctx.ui and ctx.ui.view.set then ctx.ui.view.set({ id = VIEW, remove = true }) end
end

local function load_data(ctx)
  state.busy = true
  if ctx.ui and ctx.ui.view.set then
    ctx.ui.view.set({ id = VIEW, slot = { kind = "overlay", width = "70%", anchor = "center", backdrop = "dim" }, root = { type = "view", style = { chrome = { kind = "frame", title = "Session breakdown", border = "rounded", tone = "muted" }, padding = 1 }, children = { { type = "progress", label = "Analyzing ~/.zi/agent/sessions…" } } } })
  end
  -- ctx.process.run keeps this example small. A streaming ctx.process loader would improve
  -- progress on very large histories, but would add more helper/Lua plumbing.
  local result = ctx.process.run({ "/usr/bin/env", "python3", helper_path(ctx) }, { timeout_ms = 60000, max_stdout_bytes = 16 * 1024 * 1024, max_stderr_bytes = 1024 * 1024 })
  state.busy = false
  if result.status ~= "completed" or result.code ~= 0 then
    toast(ctx, "session-breadkown failed: " .. tostring(result.stderr or result.error or result.status), "danger")
    close(ctx)
    return false
  end
  local ok, decoded = pcall(zi.json.decode, result.stdout or "")
  if not ok or not decoded then
    toast(ctx, "session-breadkown failed to decode helper JSON", "danger")
    close(ctx)
    return false
  end
  state.data = decoded
  return true
end

local function command_handler(_, ctx)
  if not ctx.capabilities().ui or not ctx.ui or not ctx.ui.view.set then return end
  if not load_data(ctx) then return end
  render(ctx)
end

local function register_command(name)
  zi.define.command({ name = name, description = "Interactive breakdown of Zi session usage (7/30/90d, graph + model/cwd/day/time views).", handler = command_handler })
end

register_command("session-breadkown")
register_command("session-breakdown")

zi.define.event("ui", function(ctx, event)
  if event.view ~= VIEW then return end
  local action = event.action or event.key
  if action == "close" or action == "q" or action == "escape" then close(ctx); return end
  if not state.data then return end
  if action == "range-prev" then state.range_i = ((state.range_i - 2) % #ranges) + 1
  elseif action == "range-next" then state.range_i = (state.range_i % #ranges) + 1
  elseif action == "view-prev" then state.view_i = ((state.view_i - 2) % #views) + 1
  elseif action == "view-next" then state.view_i = (state.view_i % #views) + 1
  elseif action == "metric-next" then state.metric_i = (state.metric_i % #metrics) + 1
  elseif action == "range-7" then state.range_i = 1
  elseif action == "range-30" then state.range_i = 2
  elseif action == "range-90" then state.range_i = 3
  else return end
  render(ctx)
end)

zi.define.event("session_shutdown", function(ctx, _) close(ctx) end)
end

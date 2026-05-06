-- Permission gate example: block dangerous bash tool calls and explain via v3 UI.
local dangerous_patterns = { "rm%s+%-r", "rm%s+%-f", "rm%s+%-%-recursive", "%f[%w]sudo%f[%W]", "chmod%s+.-777", "chown%s+.-777" }
local function lower(s) return string.lower(tostring(s or "")) end
local function is_bash_tool(name) name = lower(name); return name == "bash" end
local function is_dangerous(command) local c = lower(command); for _, pattern in ipairs(dangerous_patterns) do if string.find(c, pattern) then return true end end; return false end
local function notice(ctx, command) if ctx and ctx.ui and ctx.ui.render then ctx.ui.render({ id = "permission-gate", title = "Dangerous command blocked", target = { kind = "overlay", width = "70%", anchor = "center", backdrop = "dim" }, keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } }, root = { type = "box", style = { border = true, padding = 1 }, children = { { type = "text", text = "Blocked dangerous bash command." }, { type = "text", text = command } } } }) end end
zi.on("ui", function(event, ctx) if event.view == "permission-gate" and ctx and ctx.ui and ctx.ui.render then ctx.ui.render({ id = "permission-gate", remove = true }) end end)
zi.on("tool_call", function(event, ctx) if not is_bash_tool(event.tool_name) then return nil end; local args = event.args or {}; local command = tostring(args.command or args.cmd or ""); if not is_dangerous(command) then return nil end; notice(ctx, command); return { block = true, reason = "Dangerous bash command blocked by permission_gate example" } end)

-- Hidden thinking label live-test extension.
-- Customize the label shown when thinking blocks are collapsed/hidden.

local DEFAULT_LABEL = "Pondering..."
local label = DEFAULT_LABEL

local function apply_label(ctx)
  if ctx.ui and ctx.ui.set_hidden_thinking_label then
    ctx.ui.set_hidden_thinking_label(label)
  end
end

zi.on("session_start", function(_, ctx)
  apply_label(ctx)
end)

zi.register_command({
  name = "thinking-label",
  description = "Set the hidden thinking label. Use without args to reset.",
  handler = function(args, ctx)
    local next_label = (args or ""):match("^%s*(.-)%s*$")
    if next_label == "" then
      label = DEFAULT_LABEL
      apply_label(ctx)
      if ctx.ui and ctx.ui.notify then
        ctx.ui.notify("Hidden thinking label reset to: " .. DEFAULT_LABEL, "info")
      end
      return
    end

    label = next_label
    apply_label(ctx)
    if ctx.ui and ctx.ui.notify then
      ctx.ui.notify("Hidden thinking label set to: " .. label, "info")
    end
  end,
})

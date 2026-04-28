-- Status label example.
-- Hidden-thinking chrome is host-owned; extensions can publish semantic status
-- instead of mutating that implementation-specific label.

local DEFAULT_LABEL = "Pondering..."
local label = DEFAULT_LABEL

local function apply_label(ctx)
  if ctx.ui and ctx.ui.status then
    ctx.ui.status({ id = "thinking", text = label })
  end
end

zi.on("session_start", function(_, ctx)
  apply_label(ctx)
end)

zi.register_command({
  name = "thinking-label",
  description = "Set the thinking status label. Use without args to reset.",
  handler = function(args, ctx)
    local next_label = (args or ""):match("^%s*(.-)%s*$")
    if next_label == "" then
      label = DEFAULT_LABEL
      apply_label(ctx)
      if ctx.ui and ctx.ui.message then
        ctx.ui.message("Thinking status reset to: " .. DEFAULT_LABEL, { kind = "info" })
      end
      return
    end

    label = next_label
    apply_label(ctx)
    if ctx.ui and ctx.ui.message then
      ctx.ui.message("Thinking status set to: " .. label, { kind = "info" })
    end
  end,
})

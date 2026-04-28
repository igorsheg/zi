-- Semantic session notes example.
--
-- /note remember to update docs
-- /note @entry-id remember to update docs
-- /notes
--
-- Notes are stored as host-owned session custom entries with customType
-- "extension_note". They are durable session artifacts, but not raw transcript
-- mutation and not injected into the LLM context.

zi.register_command({
  name = "note",
  description = "Append a durable session note.",
  handler = function(args, ctx)
    local body = tostring(args or "")
    local source_entry_id = nil
    local maybe_source, rest = string.match(body, "^@([%w%-_]+)%s+(.+)$")
    if maybe_source then
      source_entry_id = maybe_source
      body = rest
    end
    if body == "" then
      ctx.ui.message("Usage: /note [@entry-id] <text>")
      return
    end

    local ok = ctx.session.append_note({
      kind = "manual",
      title = "Manual note",
      body = body,
      source_entry_id = source_entry_id,
    })

    if ok then
      ctx.ui.message("Saved session note")
    else
      ctx.ui.message("Failed to save session note")
    end
  end,
})

zi.register_command({
  name = "notes",
  description = "List durable session notes.",
  handler = function(_, ctx)
    local notes = ctx.session.notes({ kind = "manual", limit = 10 })
    if #notes == 0 then
      ctx.ui.message("No manual session notes")
      return
    end

    local lines = {}
    for i, note in ipairs(notes) do
      local title = note.title or note.kind or "note"
      lines[#lines + 1] = tostring(i) .. ". " .. title
      lines[#lines + 1] = note.body or ""
      lines[#lines + 1] = ""
    end

    ctx.ui.report({
      id = "session-notes",
      title = "Session notes",
      body = table.concat(lines, "\n"),
    })
  end,
})

return function(zi)
  zi.define.command({
    name = "note",
    description = "Append a note to the current session branch.",
    input = {
      type = "object",
      properties = {
        body = { type = "string", description = "Note body." },
      },
      required = { "body" },
    },
    run = function(ctx, input)
      local body = input and input.body or ""
      if ctx.session.notes and ctx.session.notes.append then
        ctx.session.notes.append(body, { kind = "example" })
      else
        ctx.session.append_note({ kind = "example", body = body })
      end
      if ctx.ui and ctx.ui.notify then ctx.ui.notify.show({ id = "example-note", message = "Note appended" }) end
    end,
  })
end

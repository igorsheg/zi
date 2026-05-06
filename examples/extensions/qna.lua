-- Partial qna seed: proves command-driven editor mutation through zi's
-- host-owned editor action seam. It is not full pi-mono qna parity yet;
-- full parity also needs branch/message reads, extension model completion,
-- notification/working UI, and async command cancellation.
return function(zi)
  zi.command({
    name = "qna",
    description = "Copy a question prompt into the editor.",
    handler = function(args, ctx)
      local question = args
      if question == nil or question == "" then
        question = "What should we do next?"
      end

      ctx.ui.set_editor_text("Question: " .. tostring(question) .. "\n\nAnswer: ")
    end,
  })
end

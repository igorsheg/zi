return function(zi)
  zi.register_command({
    name = "hello",
    description = "Show a greeting from an extension command.",
    handler = function(args, ctx)
      local target = args
      if target == nil or target == "" then target = "zi" end

      ctx.ui.report({
        id = "hello-command",
        title = "Hello command",
        body = "Hello, " .. tostring(target) .. "!",
        transient = true,
      })
    end,
  })
end

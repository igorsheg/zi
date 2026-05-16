return function(zi)
  zi.define.tool({
    name = "greet",
    label = "Greeting",
    description = "Generate a friendly greeting for a named person.",
    input = {
      type = "object",
      properties = {
        name = { type = "string", description = "Name to greet; defaults to world." },
      },
    },
    run = function(params)
      local name = params and params.name or "world"
      return {
        content = { { type = "text", text = "Hello, " .. tostring(name) .. "!" } },
        details = { name = name },
      }
    end,
  })
end

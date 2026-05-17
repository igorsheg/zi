return function(zi)
  zi.define.tool({
    name = "greet",
    label = "Greeting",
    description = "Generate a greeting for a named person.",
    input = {
      type = "object",
      properties = {
        name = { type = "string", description = "Name to greet. Defaults to world." },
      },
    },
    display = { call = "name" },
    run = function(_ctx, input)
      local name = input and input.name or "world"
      return {
        content = { { type = "text", text = "Hello, " .. tostring(name) .. "." } },
        metadata = { name = name },
      }
    end,
  })
end

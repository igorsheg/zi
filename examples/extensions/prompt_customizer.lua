-- Prompt customizer example: mutate the system prompt at agent runtime build.
-- Ask: "Is the prompt customizer extension active? Answer from your system prompt."

zi.on("before_agent_start", function(event, ctx)
  local opts = event.system_prompt_options or {}
  local tools = opts.selected_tools or {}
  local skills = opts.skills or {}

  local has_bash = false
  for _, name in ipairs(tools) do
    if name == "bash" then has_bash = true end
  end

  local extra = {
    "",
    "## Extension Prompt Customizer",
    "",
    "PROMPT_CUSTOMIZER_MARKER: The prompt_customizer extension is active.",
  }

  if has_bash then
    extra[#extra + 1] = "- Extension guidance: prefer precise, minimal shell commands."
  end

  if #skills > 0 then
    local names = {}
    for _, skill in ipairs(skills) do
      names[#names + 1] = skill.name
    end
    extra[#extra + 1] = "- Loaded skills: " .. table.concat(names, ", ")
  end

  return {
    system_prompt = event.system_prompt .. "\n" .. table.concat(extra, "\n"),
  }
end)

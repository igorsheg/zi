-- Task — delegate sub-tasks to a fresh zi sub-agent.
--
-- Drop into `.zi/extensions/` (project-local) or
-- `~/.zi/agent/extensions/` (user-global) alongside the
-- `lib/subagent_render.lua` helper.
--
-- Flow:
--   1. `execute` spawns a child zi process via `zi.spawn`.
--   2. The `on = { tool_execution_end, message_end }` observers
--      accumulate tool calls and capture the final assistant text
--      as the child runs.
--   3. The tool result's `details` field carries the accumulated
--      transcript so `render_result` can draw a tree view.
--   4. `render_result` calls the shared `subagent_render` library
--      to produce structured spans for the zi TUI.

local subagent = require("lib/subagent_render")

zi.register_tool({
  name = "Task",
  label = "Task",
  description = [[
Perform a task (a sub-task of the user's overall task) using a sub-agent.

When to use:
  - Complex multi-step tasks
  - Operations producing a lot of output not needed after completion
  - Changes across many layers, after planning

When NOT to use:
  - Single logical tasks
  - Simple reads / searches / edits — use the direct tools
]],
  parameters = {
    type = "object",
    properties = {
      prompt = {
        type = "string",
        description = "The task for the agent to perform. Include all context.",
      },
      description = {
        type = "string",
        description = "A short description of the task for the UI.",
      },
    },
    required = { "prompt", "description" },
  },
  execute = function(args, ctx)
    local tool_calls = {}
    local final_text = ""

    -- Push a partial result to the TUI so the tree updates live as
    -- the child runs. The renderer reads details.tool_calls and
    -- details.final_text and rebuilds the span tree on each call.
    local function push_update()
      if ctx and ctx.update then
        ctx.update({
          content = { { type = "text", text = final_text ~= "" and final_text or "(working...)" } },
          details = {
            kind = "subagent",
            label = "Task",
            description = args.description,
            tool_calls = tool_calls,
            final_text = final_text,
          },
        })
      end
    end

    local r = zi.spawn({
      task = args.prompt,
      tools = "bash,read,grep,find",
      on = {
        tool_execution_end = function(event)
          table.insert(tool_calls, {
            name = event.toolName,
            args = event.args,
            is_error = event.isError,
          })
          push_update()
        end,
        message_end = function(event)
          -- Grab the last assistant text block as the summary.
          local msg = event.message
          if msg and msg.role == "assistant" and msg.content then
            for _, block in ipairs(msg.content) do
              if block.type == "text" and block.text and block.text ~= "" then
                final_text = block.text
              end
            end
            push_update()
          end
        end,
      },
    })

    local is_error = r.exit_code ~= 0
      or r.stop_reason == "error"
      or r.stop_reason == "aborted"

    local text = final_text
    if text == "" then text = r.final_text or "" end
    if text == "" then text = r.error_message or "(no output)" end

    return {
      content = { { type = "text", text = text } },
      is_error = is_error,
      details = {
        kind = "subagent",
        label = "Task",
        description = args.description,
        model = r.model,
        usage = r.usage,
        stop_reason = r.stop_reason,
        error_message = r.error_message,
        tool_calls = tool_calls,
        final_text = final_text,
      },
    }
  end,
  render_result = function(result, ctx)
    return subagent.render_agent_tree(result, ctx, { label = "Task" })
  end,
})

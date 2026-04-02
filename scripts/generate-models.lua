#!/usr/bin/env luajit
--
-- Fetch model catalog from models.dev and generate models_generated.zig
-- Uses curl for HTTP, minimal JSON parser for processing.
--
-- Usage: luajit scripts/generate-models.lua > packages/ai/src/models_generated.zig
--

-- ═══════════════════════════════════════════════════════════════════
-- Minimal JSON parser (pure lua, handles the subset we need)
-- ═══════════════════════════════════════════════════════════════════

local json = {}

local function skip_ws(s, i)
  return s:match("^%s*()", i)
end

local function parse_string(s, i)
  assert(s:sub(i, i) == '"')
  local j = i + 1
  local parts = {}
  while j <= #s do
    local c = s:sub(j, j)
    if c == '"' then return table.concat(parts), j + 1 end
    if c == '\\' then
      j = j + 1
      c = s:sub(j, j)
      if c == 'n' then parts[#parts+1] = '\n'
      elseif c == 't' then parts[#parts+1] = '\t'
      elseif c == 'u' then
        parts[#parts+1] = '?' -- simplified unicode escape
        j = j + 4
      else parts[#parts+1] = c end
    else parts[#parts+1] = c end
    j = j + 1
  end
  error("unterminated string at " .. i)
end

local function parse_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return parse_string(s, i)
  elseif c == '{' then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
      i = skip_ws(s, i)
      local key
      key, i = parse_string(s, i)
      i = skip_ws(s, i)
      assert(s:sub(i, i) == ':'); i = i + 1
      local val
      val, i = parse_value(s, i)
      obj[key] = val
      i = skip_ws(s, i)
      if s:sub(i, i) == '}' then return obj, i + 1 end
      assert(s:sub(i, i) == ','); i = i + 1
    end
  elseif c == '[' then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
      local val
      val, i = parse_value(s, i)
      arr[#arr+1] = val
      i = skip_ws(s, i)
      if s:sub(i, i) == ']' then return arr, i + 1 end
      assert(s:sub(i, i) == ','); i = i + 1
    end
  elseif s:sub(i, i+3) == 'true' then return true, i + 4
  elseif s:sub(i, i+4) == 'false' then return false, i + 5
  elseif s:sub(i, i+3) == 'null' then return nil, i + 4
  else
    local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    if num then return tonumber(num), i + #num end
    error("unexpected char '" .. c .. "' at " .. i)
  end
end

function json.decode(s) return (parse_value(s, 1)) end

-- ═══════════════════════════════════════════════════════════════════
-- Fetch and process
-- ═══════════════════════════════════════════════════════════════════

local function fetch(url)
  local cmd = string.format('curl -sS "%s"', url)
  local f = io.popen(cmd)
  local body = f:read("*a")
  f:close()
  return body
end

-- provider config: models.dev key → { api, provider, base_url }
local PROVIDERS = {
  anthropic = {
    api = "anthropic_messages", provider = "anthropic",
    base_url = "https://api.anthropic.com",
  },
  openai = {
    api = "openai_responses", provider = "openai",
    base_url = "https://api.openai.com/v1",
  },
  google = {
    api = "google_generative_ai", provider = "google",
    base_url = "https://generativelanguage.googleapis.com/v1beta",
  },
  groq = {
    api = "openai_completions", provider = "groq",
    base_url = "https://api.groq.com/openai/v1",
  },
  cerebras = {
    api = "openai_completions", provider = "cerebras",
    base_url = "https://api.cerebras.ai/v1",
  },
  xai = {
    api = "openai_completions", provider = "xai",
    base_url = "https://api.x.ai/v1",
  },
  mistral = {
    api = "mistral_conversations", provider = "mistral",
    base_url = "https://api.mistral.ai",
  },
}

local function has_image(m)
  if m.modalities and m.modalities.input then
    for _, v in ipairs(m.modalities.input) do
      if v == "image" then return true end
    end
  end
  return false
end

local function zig_escape(s)
  return s:gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function collect_models(data)
  local models = {}
  for provider_key, cfg in pairs(PROVIDERS) do
    local section = data[provider_key]
    if section and section.models then
      for model_id, m in pairs(section.models) do
        if m.tool_call == true then
          -- skip known broken models
          if not model_id:match("^ai21%.jamba") and
             not model_id:match("^mistral%.mistral%-7b%-instruct%-v0") then
            models[#models+1] = {
              id = model_id,
              name = m.name or model_id,
              api = cfg.api,
              provider = cfg.provider,
              base_url = cfg.base_url,
              reasoning = m.reasoning == true,
              has_image = has_image(m),
              cost_input = (m.cost and m.cost.input) or 0,
              cost_output = (m.cost and m.cost.output) or 0,
              cost_cache_read = (m.cost and m.cost.cache_read) or 0,
              cost_cache_write = (m.cost and m.cost.cache_write) or 0,
              context_window = (m.limit and m.limit.context) or 4096,
              max_tokens = (m.limit and m.limit.output) or 4096,
            }
          end
        end
      end
    end
  end
  -- sort by provider then id for deterministic output
  table.sort(models, function(a, b)
    if a.provider ~= b.provider then return a.provider < b.provider end
    return a.id < b.id
  end)
  return models
end

-- ═══════════════════════════════════════════════════════════════════
-- Generate zig
-- ═══════════════════════════════════════════════════════════════════

local function emit_zig(models)
  local out = {}
  local function w(s) out[#out+1] = s end

  w("// Auto-generated by scripts/generate-models.lua")
  w("// Do not edit manually — run 'luajit scripts/generate-models.lua' to update")
  w("//")
  w(string.format("// Generated: %s | Models: %d", os.date("!%Y-%m-%dT%H:%M:%SZ"), #models))
  w("")
  w("const protocol = @import(\"protocol.zig\");")
  w("")
  w("pub const models = [_]protocol.Model{")

  for _, m in ipairs(models) do
    local input_types
    if m.has_image then
      input_types = "&.{ .text, .image }"
    else
      input_types = "&.{.text}"
    end

    w("    .{")
    w(string.format('        .id = "%s",', zig_escape(m.id)))
    w(string.format('        .name = "%s",', zig_escape(m.name)))
    w(string.format("        .api = .%s,", m.api))
    w(string.format("        .provider = .%s,", m.provider))
    w(string.format('        .base_url = "%s",', m.base_url))
    w(string.format("        .reasoning = %s,", tostring(m.reasoning)))
    w(string.format("        .input = %s,", input_types))
    w(string.format("        .cost = .{ .input = %s, .output = %s, .cache_read = %s, .cache_write = %s },",
      m.cost_input, m.cost_output, m.cost_cache_read, m.cost_cache_write))
    w(string.format("        .context_window = %d,", m.context_window))
    w(string.format("        .max_tokens = %d,", m.max_tokens))
    w("    },")
  end

  w("};")
  w("")
  return table.concat(out, "\n")
end

-- ═══════════════════════════════════════════════════════════════════
-- Main
-- ═══════════════════════════════════════════════════════════════════

io.stderr:write("Fetching models from models.dev...\n")
local body = fetch("https://models.dev/api.json")
io.stderr:write(string.format("Received %d bytes\n", #body))

local data = json.decode(body)
local models = collect_models(data)
io.stderr:write(string.format("Collected %d tool-capable models\n", #models))

io.write(emit_zig(models))
io.stderr:write("Done.\n")

#!/usr/bin/env luajit
--
-- Generate src/ai/models_generated.zig from upstream model catalogs.
--
-- Port of pi-mono's packages/ai/scripts/generate-models.ts, scoped to
-- zi's first-launch provider set:
--
--   * anthropic           (api key)           ← models.dev
--   * openai              (api key)           ← models.dev
--   * openai-codex        (chatgpt PKCE)      ← hand-coded block
--   * openrouter          (api key)           ← openrouter.ai/api/v1/models
--
-- The same model id intentionally appears under multiple (provider, api,
-- base_url) tuples when it has multiple auth pathways. That's how the
-- auth-method matrix is encoded in the catalog — resolveModel later picks
-- the right row by checking which providers have configured auth.
--
-- To regenerate:
--   luajit scripts/generate-models.lua > src/ai/models_generated.zig
--

-- ═══════════════════════════════════════════════════════════════════
-- Minimal JSON parser (pure lua)
-- ═══════════════════════════════════════════════════════════════════
-- Handles the subset models.dev + openrouter emit. Decodes \uXXXX
-- escapes into UTF-8 bytes so model names with non-ASCII characters
-- round-trip correctly.

local json = {}

local function skip_ws(s, i)
  return s:match("^[ \t\r\n]*()", i)
end

-- Encode a Unicode code point as UTF-8 bytes.
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + math.floor(cp / 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
end

local function parse_string(s, i)
  assert(s:sub(i, i) == '"', "expected string at " .. i)
  local j = i + 1
  local parts = {}
  while j <= #s do
    local c = s:sub(j, j)
    if c == '"' then
      return table.concat(parts), j + 1
    elseif c == '\\' then
      j = j + 1
      local esc = s:sub(j, j)
      if esc == 'n' then parts[#parts+1] = '\n'
      elseif esc == 't' then parts[#parts+1] = '\t'
      elseif esc == 'r' then parts[#parts+1] = '\r'
      elseif esc == 'b' then parts[#parts+1] = '\b'
      elseif esc == 'f' then parts[#parts+1] = '\f'
      elseif esc == '/' then parts[#parts+1] = '/'
      elseif esc == '"' then parts[#parts+1] = '"'
      elseif esc == '\\' then parts[#parts+1] = '\\'
      elseif esc == 'u' then
        local hex = s:sub(j + 1, j + 4)
        local cp = tonumber(hex, 16)
        if not cp then error("bad \\u escape at " .. j) end
        -- UTF-16 surrogate pair
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j + 5, j + 6) == '\\u' then
          local hex2 = s:sub(j + 7, j + 10)
          local cp2 = tonumber(hex2, 16)
          if cp2 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
            j = j + 6
          end
        end
        parts[#parts+1] = utf8_encode(cp)
        j = j + 4
      else
        error("bad escape \\" .. esc .. " at " .. j)
      end
      j = j + 1
    else
      parts[#parts+1] = c
      j = j + 1
    end
  end
  error("unterminated string at " .. i)
end

local parse_value

local function parse_object(s, i)
  local obj = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    i = skip_ws(s, i)
    local key
    key, i = parse_string(s, i)
    i = skip_ws(s, i)
    assert(s:sub(i, i) == ':', "expected ':' at " .. i); i = i + 1
    local val
    val, i = parse_value(s, i)
    obj[key] = val
    i = skip_ws(s, i)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    assert(s:sub(i, i) == ',', "expected ',' at " .. i); i = i + 1
  end
end

local function parse_array(s, i)
  local arr = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local val
    val, i = parse_value(s, i)
    arr[#arr+1] = val
    i = skip_ws(s, i)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    assert(s:sub(i, i) == ',', "expected ',' at " .. i); i = i + 1
  end
end

parse_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return parse_string(s, i)
  elseif c == '{' then return parse_object(s, i)
  elseif c == '[' then return parse_array(s, i)
  elseif s:sub(i, i+3) == 'true' then return true, i + 4
  elseif s:sub(i, i+4) == 'false' then return false, i + 5
  elseif s:sub(i, i+3) == 'null' then return nil, i + 4
  else
    local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    if num and num ~= "" then return tonumber(num), i + #num end
    error("unexpected char '" .. c .. "' at " .. i)
  end
end

function json.decode(s) return (parse_value(s, 1)) end

-- ═══════════════════════════════════════════════════════════════════
-- Fetch helper
-- ═══════════════════════════════════════════════════════════════════

local function fetch(url)
  local cmd = string.format('curl -sS "%s"', url)
  local f = io.popen(cmd)
  local body = f:read("*a")
  f:close()
  return body
end

-- ═══════════════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════════════

local function has_image(m)
  if m and m.modalities and m.modalities.input then
    for _, v in ipairs(m.modalities.input) do
      if v == "image" then return true end
    end
  end
  return false
end

local function contains(list, needle)
  if type(list) ~= "table" then return false end
  for _, v in ipairs(list) do
    if v == needle then return true end
  end
  return false
end

local function to_number(v)
  if type(v) == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return 0 end
    return v
  end
  if type(v) == "string" then
    local n = tonumber(v)
    return n or 0
  end
  return 0
end

-- ═══════════════════════════════════════════════════════════════════
-- Source 1: models.dev — anthropic + openai
-- ═══════════════════════════════════════════════════════════════════

local MODELS_DEV_SOURCES = {
  {
    key = "anthropic",
    api = "anthropic_messages",
    provider = "anthropic",
    base_url = "https://api.anthropic.com",
  },
  {
    key = "openai",
    api = "openai_responses",
    provider = "openai",
    base_url = "https://api.openai.com/v1",
  },
}

local function collect_models_dev(data)
  local models = {}
  for _, src in ipairs(MODELS_DEV_SOURCES) do
    local section = data[src.key]
    if section and section.models then
      for model_id, m in pairs(section.models) do
        if m.tool_call == true then
          models[#models+1] = {
            id = model_id,
            name = m.name or model_id,
            api = src.api,
            provider = src.provider,
            base_url = src.base_url,
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
  return models
end

-- ═══════════════════════════════════════════════════════════════════
-- Source 2: openrouter — openrouter.ai/api/v1/models
-- ═══════════════════════════════════════════════════════════════════

local function collect_openrouter(data)
  local models = {}
  if not (data and data.data) then return models end
  for _, m in ipairs(data.data) do
    -- Only tool-capable models.
    if contains(m.supported_parameters, "tools") then
      local input_has_image = false
      if m.architecture and m.architecture.input_modalities then
        input_has_image = contains(m.architecture.input_modalities, "image")
      elseif m.architecture and type(m.architecture.modality) == "string" then
        input_has_image = m.architecture.modality:find("image") ~= nil
      end

      -- Pricing is reported in $/token as strings; convert to $/Mtok.
      local p = m.pricing or {}
      local cost_input = to_number(p.prompt) * 1000000
      local cost_output = to_number(p.completion) * 1000000
      local cost_cache_read = to_number(p.input_cache_read) * 1000000
      local cost_cache_write = to_number(p.input_cache_write) * 1000000

      local ctx = to_number(m.context_length)
      if ctx <= 0 then ctx = 4096 end

      local max_tok = 4096
      if m.top_provider and to_number(m.top_provider.max_completion_tokens) > 0 then
        max_tok = to_number(m.top_provider.max_completion_tokens)
      end

      models[#models+1] = {
        id = m.id,
        name = m.name or m.id,
        api = "openai_completions",
        provider = "openrouter",
        base_url = "https://openrouter.ai/api/v1",
        reasoning = contains(m.supported_parameters, "reasoning"),
        has_image = input_has_image,
        cost_input = cost_input,
        cost_output = cost_output,
        cost_cache_read = cost_cache_read,
        cost_cache_write = cost_cache_write,
        context_window = ctx,
        max_tokens = max_tok,
      }
    end
  end
  return models
end

-- ═══════════════════════════════════════════════════════════════════
-- Source 3: hand-coded OpenAI Codex (ChatGPT PKCE) block
-- ═══════════════════════════════════════════════════════════════════
-- pi-mono source: generate-models.ts:941-1056
-- These are not fetched from any API — they encode the chatgpt-subscription
-- auth pathway for the same model ids served by api.openai.com. Context
-- window reflects observed server limits, not marketing numbers.

local CODEX_BASE_URL = "https://chatgpt.com/backend-api"
local CODEX_CTX = 272000
local CODEX_MAX = 128000

local CODEX_MODELS = {
  { id = "gpt-5.1",             name = "GPT-5.1",             ci = 1.25, co = 10,  cr = 0.125, cw = 0 },
  { id = "gpt-5.1-codex-max",   name = "GPT-5.1 Codex Max",   ci = 1.25, co = 10,  cr = 0.125, cw = 0 },
  { id = "gpt-5.1-codex-mini",  name = "GPT-5.1 Codex Mini",  ci = 0.25, co = 2,   cr = 0.025, cw = 0 },
  { id = "gpt-5.2",             name = "GPT-5.2",             ci = 1.75, co = 14,  cr = 0.175, cw = 0 },
  { id = "gpt-5.2-codex",       name = "GPT-5.2 Codex",       ci = 1.75, co = 14,  cr = 0.175, cw = 0 },
  { id = "gpt-5.3-codex",       name = "GPT-5.3 Codex",       ci = 1.75, co = 14,  cr = 0.175, cw = 0 },
  { id = "gpt-5.4",             name = "GPT-5.4",             ci = 2.5,  co = 15,  cr = 0.25,  cw = 0 },
  { id = "gpt-5.4-mini",        name = "GPT-5.4 Mini",        ci = 0.75, co = 4.5, cr = 0.075, cw = 0 },
  { id = "gpt-5.3-codex-spark", name = "GPT-5.3 Codex Spark", ci = 0,    co = 0,   cr = 0,     cw = 0, text_only = true, ctx = 128000 },
}

local function collect_codex()
  local models = {}
  for _, c in ipairs(CODEX_MODELS) do
    models[#models+1] = {
      id = c.id,
      name = c.name,
      api = "openai_codex_responses",
      provider = "openai_codex",
      base_url = CODEX_BASE_URL,
      reasoning = true,
      has_image = not c.text_only,
      cost_input = c.ci,
      cost_output = c.co,
      cost_cache_read = c.cr,
      cost_cache_write = c.cw,
      context_window = c.ctx or CODEX_CTX,
      max_tokens = CODEX_MAX,
    }
  end
  return models
end

-- ═══════════════════════════════════════════════════════════════════
-- Patch block
-- ═══════════════════════════════════════════════════════════════════
-- Corrections and additions that upstream catalogs lag on. Ported from
-- pi-mono's generate-models.ts patch block, scoped to phase-1 providers.

local function find_model(list, provider, id)
  for _, m in ipairs(list) do
    if m.provider == provider and m.id == id then return m end
  end
  return nil
end

local function apply_patches(all)
  -- Fix incorrect cache pricing for Claude Opus 4.5 from models.dev
  -- (upstream has 3x the correct values).
  local opus45 = find_model(all, "anthropic", "claude-opus-4-5")
  if opus45 then
    opus45.cost_cache_read = 0.5
    opus45.cost_cache_write = 6.25
  end

  -- Per-model overrides.
  for _, m in ipairs(all) do
    if m.provider == "anthropic" and (m.id == "claude-opus-4-6" or m.id == "claude-sonnet-4-6") then
      m.context_window = 1000000
    end
    if m.provider == "openai" and m.id == "gpt-5.4" then
      m.context_window = 272000
      m.max_tokens = 128000
    end
    if m.provider == "openrouter" and m.id == "moonshotai/kimi-k2.5" then
      m.cost_input = 0.41
      m.cost_output = 2.06
      m.cost_cache_read = 0.07
      m.max_tokens = 4096
    end
  end

  -- Additions: anthropic claude-opus-4-6, claude-sonnet-4-6.
  if not find_model(all, "anthropic", "claude-opus-4-6") then
    all[#all+1] = {
      id = "claude-opus-4-6",
      name = "Claude Opus 4.6",
      api = "anthropic_messages",
      provider = "anthropic",
      base_url = "https://api.anthropic.com",
      reasoning = true,
      has_image = true,
      cost_input = 5, cost_output = 25, cost_cache_read = 0.5, cost_cache_write = 6.25,
      context_window = 1000000,
      max_tokens = 128000,
    }
  end
  if not find_model(all, "anthropic", "claude-sonnet-4-6") then
    all[#all+1] = {
      id = "claude-sonnet-4-6",
      name = "Claude Sonnet 4.6",
      api = "anthropic_messages",
      provider = "anthropic",
      base_url = "https://api.anthropic.com",
      reasoning = true,
      has_image = true,
      cost_input = 3, cost_output = 15, cost_cache_read = 0.3, cost_cache_write = 3.75,
      context_window = 1000000,
      max_tokens = 64000,
    }
  end

  -- Additions: openai chat/codex models that lag on models.dev.
  local openai_base = "https://api.openai.com/v1"
  local openai_adds = {
    {
      id = "gpt-5-chat-latest", name = "GPT-5 Chat Latest",
      reasoning = false, has_image = true,
      ci = 1.25, co = 10, cr = 0.125, cw = 0,
      ctx = 128000, max_tok = 16384,
    },
    {
      id = "gpt-5.1-codex", name = "GPT-5.1 Codex",
      reasoning = true, has_image = true,
      ci = 1.25, co = 5, cr = 0.125, cw = 1.25,
      ctx = 400000, max_tok = 128000,
    },
    {
      id = "gpt-5.1-codex-max", name = "GPT-5.1 Codex Max",
      reasoning = true, has_image = true,
      ci = 1.25, co = 10, cr = 0.125, cw = 0,
      ctx = 400000, max_tok = 128000,
    },
    {
      id = "gpt-5.3-codex-spark", name = "GPT-5.3 Codex Spark",
      reasoning = true, has_image = false,
      ci = 0, co = 0, cr = 0, cw = 0,
      ctx = 128000, max_tok = 16384,
    },
    {
      id = "gpt-5.4", name = "GPT-5.4",
      reasoning = true, has_image = true,
      ci = 2.5, co = 15, cr = 0.25, cw = 0,
      ctx = 272000, max_tok = 128000,
    },
  }
  for _, a in ipairs(openai_adds) do
    if not find_model(all, "openai", a.id) then
      all[#all+1] = {
        id = a.id, name = a.name,
        api = "openai_responses", provider = "openai", base_url = openai_base,
        reasoning = a.reasoning, has_image = a.has_image,
        cost_input = a.ci, cost_output = a.co,
        cost_cache_read = a.cr, cost_cache_write = a.cw,
        context_window = a.ctx, max_tokens = a.max_tok,
      }
    end
  end

  -- Addition: openrouter "auto" meta-model.
  if not find_model(all, "openrouter", "auto") then
    all[#all+1] = {
      id = "auto", name = "Auto",
      api = "openai_completions", provider = "openrouter",
      base_url = "https://openrouter.ai/api/v1",
      reasoning = true, has_image = true,
      cost_input = 0, cost_output = 0, cost_cache_read = 0, cost_cache_write = 0,
      context_window = 2000000, max_tokens = 30000,
    }
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- Dedup + sort
-- ═══════════════════════════════════════════════════════════════════
-- Dedup key is (provider, id). Same model id under different providers
-- is preserved — that's how the auth-method matrix is encoded.

local function dedup(list)
  local seen = {}
  local out = {}
  for _, m in ipairs(list) do
    local k = m.provider .. "|" .. m.id
    if not seen[k] then
      seen[k] = true
      out[#out+1] = m
    end
  end
  return out
end

local function sort_models(list)
  table.sort(list, function(a, b)
    if a.provider ~= b.provider then return a.provider < b.provider end
    return a.id < b.id
  end)
end

-- ═══════════════════════════════════════════════════════════════════
-- Emit zig
-- ═══════════════════════════════════════════════════════════════════

local function zig_escape(s)
  return (s:gsub('\\', '\\\\'):gsub('"', '\\"'))
end

-- Format a number for zig. Avoids scientific notation so the emitted
-- file stays grep-friendly.
local function fmt_num(n)
  if type(n) ~= "number" then n = to_number(n) end
  if n == 0 then return "0" end
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  -- Use enough digits to round-trip typical pricing values.
  local s = string.format("%.10f", n)
  -- Strip trailing zeros and dangling dot.
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

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
    local input_types = m.has_image and "&.{ .text, .image }" or "&.{.text}"

    w("    .{")
    w(string.format('        .id = "%s",', zig_escape(m.id)))
    w(string.format('        .name = "%s",', zig_escape(m.name)))
    w(string.format("        .api = .%s,", m.api))
    w(string.format("        .provider = .%s,", m.provider))
    w(string.format('        .base_url = "%s",', m.base_url))
    w(string.format("        .reasoning = %s,", tostring(m.reasoning)))
    w(string.format("        .input = %s,", input_types))
    w(string.format(
      "        .cost = .{ .input = %s, .output = %s, .cache_read = %s, .cache_write = %s },",
      fmt_num(m.cost_input), fmt_num(m.cost_output),
      fmt_num(m.cost_cache_read), fmt_num(m.cost_cache_write)
    ))
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

io.stderr:write("Fetching models.dev/api.json...\n")
local body = fetch("https://models.dev/api.json")
io.stderr:write(string.format("  %d bytes\n", #body))
local dev_data = json.decode(body)
local dev_models = collect_models_dev(dev_data)
io.stderr:write(string.format("  %d tool-capable models from models.dev (anthropic+openai)\n", #dev_models))

io.stderr:write("Fetching openrouter.ai/api/v1/models...\n")
local or_body = fetch("https://openrouter.ai/api/v1/models")
io.stderr:write(string.format("  %d bytes\n", #or_body))
local or_data = json.decode(or_body)
local or_models = collect_openrouter(or_data)
io.stderr:write(string.format("  %d tool-capable models from openrouter\n", #or_models))

local codex_models = collect_codex()
io.stderr:write(string.format("Hand-coded codex block: %d models\n", #codex_models))

-- Combine: models.dev first so dedup prefers it over openrouter when
-- the same (provider, id) appears twice.
local all = {}
for _, m in ipairs(dev_models) do all[#all+1] = m end
for _, m in ipairs(or_models)  do all[#all+1] = m end
for _, m in ipairs(codex_models) do all[#all+1] = m end

apply_patches(all)
all = dedup(all)
sort_models(all)

io.stderr:write("\nFinal per-provider counts:\n")
local counts = {}
for _, m in ipairs(all) do counts[m.provider] = (counts[m.provider] or 0) + 1 end
local keys = {}
for k in pairs(counts) do keys[#keys+1] = k end
table.sort(keys)
for _, k in ipairs(keys) do
  io.stderr:write(string.format("  %-20s %d\n", k, counts[k]))
end
io.stderr:write(string.format("  %-20s %d\n", "TOTAL", #all))

io.write(emit_zig(all))
io.stderr:write("Done.\n")

local doc = {}
doc.schema = "zi.doc.v1"
doc.version = 1

function doc.fragment(blocks)
  return { schema = "zi.doc.v1", blocks = blocks or {} }
end

function doc.span(text, role, opts)
  opts = opts or {}
  return {
    text = tostring(text or ""),
    style = {
      role = role or "normal",
      bold = opts.bold or nil,
      dim = opts.dim or nil,
      italic = opts.italic or nil,
      underline = opts.underline or nil,
    },
    link = opts.link,
  }
end

function doc.line(spans, opts)
  opts = opts or {}
  return {
    type = "line",
    indent = opts.indent,
    marker = opts.marker,
    spans = spans or {},
  }
end

function doc.text(text, opts)
  opts = opts or {}
  return {
    type = "text",
    text = tostring(text or ""),
    indent = opts.indent,
    collapsed_lines = opts.collapsed_lines,
    style = opts.style,
  }
end

function doc.markdown(text, opts)
  opts = opts or {}
  return {
    type = "markdown",
    text = tostring(text or ""),
    indent = opts.indent,
    collapsed_lines = opts.collapsed_lines,
    style = opts.style,
  }
end

function doc.group(blocks, opts)
  opts = opts or {}
  return {
    type = "group",
    indent = opts.indent,
    collapsed = opts.max_blocks and { max_blocks = opts.max_blocks } or nil,
    blocks = blocks or {},
  }
end

function doc.marker(text, role, opts)
  return doc.span(text, role, opts)
end

function doc.step(status, label, summary, opts)
  opts = opts or {}
  local mark = status == "done" and "✓" or status == "success" and "✓" or status == "error" and "✕" or "⋯"
  local role = (status == "done" or status == "success") and "success" or status == "error" and "danger" or "muted"
  return doc.line({
    doc.span(label or "", "accent"),
    doc.span(summary and (" " .. summary) or "", "muted"),
  }, {
    indent = opts.indent or 1,
    marker = doc.marker(mark, role),
  })
end

function doc.is_fragment(value)
  return type(value) == "table" and value.schema == doc.schema and type(value.blocks) == "table"
end

function doc.validate(value)
  if not doc.is_fragment(value) then error("zi.doc.validate: expected zi.doc.v1 fragment") end
  return true
end

function doc.to_markdown(value)
  local fragment = value
  if type(value) == "table" and value.schema ~= doc.schema then fragment = doc.fragment({ value }) end
  doc.validate(fragment)
  local out = {}
  local function block_to_text(block)
    if type(block) ~= "table" then return "" end
    if block.type == "text" or block.type == "markdown" then return tostring(block.text or "") end
    if block.type == "line" then
      local parts = {}
      for _, span in ipairs(block.spans or {}) do parts[#parts + 1] = tostring(span.text or "") end
      return table.concat(parts)
    end
    if block.type == "group" then
      local nested = {}
      for _, child in ipairs(block.blocks or {}) do nested[#nested + 1] = block_to_text(child) end
      return table.concat(nested, "\n")
    end
    return ""
  end
  for _, block in ipairs(fragment.blocks) do out[#out + 1] = block_to_text(block) end
  return table.concat(out, "\n")
end

return doc

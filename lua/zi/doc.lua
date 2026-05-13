local doc = {}

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

return doc

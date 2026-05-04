const std = @import("std");

/// Render an OAuth success page.
/// Caller owns returned slice.
pub fn successHtml(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return renderPage(allocator, .{
        .title = "Authentication successful",
        .heading = "Authentication successful",
        .message = message,
        .details = null,
    });
}

/// Render an OAuth error page.
/// Caller owns returned slice.
pub fn errorHtml(allocator: std.mem.Allocator, message: []const u8, details: ?[]const u8) ![]u8 {
    return renderPage(allocator, .{
        .title = "Authentication failed",
        .heading = "Authentication failed",
        .message = message,
        .details = details,
    });
}

const PageOptions = struct {
    title: []const u8,
    heading: []const u8,
    message: []const u8,
    details: ?[]const u8,
};

fn renderPage(allocator: std.mem.Allocator, opts: PageOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const w = buf.writer(allocator);
    try w.writeAll(page_prefix);
    try w.writeAll(opts.title);
    try w.writeAll(page_mid1);
    try w.writeAll(opts.heading);
    try w.writeAll(page_mid2);
    try w.writeAll(opts.message);
    try w.writeAll(page_mid3);
    if (opts.details) |d| {
        try w.writeAll("<div class=\"details\">");
        try w.writeAll(d);
        try w.writeAll("</div>");
    }
    try w.writeAll(page_suffix);
    return buf.toOwnedSlice(allocator);
}

const page_prefix =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\  <title>
;

const page_mid1 =
    \\</title>
    \\  <style>
    \\    :root { --text: #fafafa; --text-dim: #a1a1aa; --page-bg: #09090b; }
    \\    * { box-sizing: border-box; }
    \\    html { color-scheme: dark; }
    \\    body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:24px; background:var(--page-bg); color:var(--text); font-family:system-ui,sans-serif; text-align:center; }
    \\    main { max-width:560px; }
    \\    h1 { margin:0 0 10px; font-size:28px; font-weight:650; }
    \\    p { margin:0; line-height:1.7; color:var(--text-dim); font-size:15px; }
    \\    .details { margin-top:16px; font-family:monospace; font-size:13px; color:var(--text-dim); white-space:pre-wrap; word-break:break-word; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>
;

const page_mid2 =
    \\</h1>
    \\    <p>
;

const page_mid3 =
    \\</p>
    \\
;

const page_suffix =
    \\  </main>
    \\</body>
    \\</html>
;

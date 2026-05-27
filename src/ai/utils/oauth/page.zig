const std = @import("std");

const logo_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800" aria-hidden="true">
    \\<path fill="#fff" d="M165 165h352v235H400v117H283v118H165z"/>
    \\<path fill="#fff" d="M283 283v117h117V283zM517 400h118v235H517z"/>
    \\</svg>
;

pub fn successHtml(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return renderPage(allocator, .{
        .title = "Authentication successful",
        .heading = "Authentication successful",
        .message = message,
    });
}

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
    details: ?[]const u8 = null,
};

fn renderPage(allocator: std.mem.Allocator, options: PageOptions) ![]u8 {
    var title = try escapeHtml(allocator, options.title);
    defer title.deinit();
    var heading = try escapeHtml(allocator, options.heading);
    defer heading.deinit();
    var message = try escapeHtml(allocator, options.message);
    defer message.deinit();
    var details = if (options.details) |value| try escapeHtml(allocator, value) else null;
    defer if (details) |*value| value.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.print(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8" />
        \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\  <title>{s}</title>
        \\  <style>
        \\    :root {{
        \\      --text: #fafafa;
        \\      --text-dim: #a1a1aa;
        \\      --page-bg: #09090b;
        \\      --font-sans: system-ui, "Segoe UI", sans-serif;
        \\      --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;
        \\    }}
        \\    * {{ box-sizing: border-box; }}
        \\    html {{ color-scheme: dark; }}
        \\    body {{ margin: 0; min-height: 100vh; display: flex; align-items: center; }}
        \\    body {{ justify-content: center; padding: 24px; background: var(--page-bg); }}
        \\    body {{ color: var(--text); font-family: var(--font-sans); text-align: center; }}
        \\    main {{ width: 100%; max-width: 560px; display: flex; flex-direction: column; }}
        \\    main {{ align-items: center; justify-content: center; }}
        \\    .logo {{ width: 72px; height: 72px; display: block; margin-bottom: 24px; }}
        \\    h1 {{ margin: 0 0 10px; font-size: 28px; line-height: 1.15; }}
        \\    h1 {{ font-weight: 650; color: var(--text); }}
        \\    p {{ margin: 0; line-height: 1.7; color: var(--text-dim); font-size: 15px; }}
        \\    .details {{ margin-top: 16px; font-family: var(--font-mono); font-size: 13px; }}
        \\    .details {{ color: var(--text-dim); white-space: pre-wrap; word-break: break-word; }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <div class="logo">{s}</div>
        \\    <h1>{s}</h1>
        \\    <p>{s}</p>
    , .{ title.written(), logo_svg, heading.written(), message.written() });
    if (details) |*value| try writer.writer.print(
        \\    <div class="details">{s}</div>
    , .{value.written()});
    try writer.writer.writeAll(
        \\  </main>
        \\</body>
        \\</html>
    );
    return writer.toOwnedSlice();
}

fn escapeHtml(allocator: std.mem.Allocator, value: []const u8) !std.Io.Writer.Allocating {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    for (value) |byte| switch (byte) {
        '&' => try writer.writer.writeAll("&amp;"),
        '<' => try writer.writer.writeAll("&lt;"),
        '>' => try writer.writer.writeAll("&gt;"),
        '"' => try writer.writer.writeAll("&quot;"),
        '\'' => try writer.writer.writeAll("&#39;"),
        else => try writer.writer.writeByte(byte),
    };
    return writer;
}

test "success html escapes message" {
    const html = try successHtml(std.testing.allocator, "ok <done> & nice");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Authentication successful") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "ok &lt;done&gt; &amp; nice") != null);
}

test "error html escapes details" {
    const html = try errorHtml(std.testing.allocator, "bad", "token \"nope\"");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Authentication failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "token &quot;nope&quot;") != null);
}

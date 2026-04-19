//! Read tool — file & directory reader with line numbers, range slicing,
//! secret-file guard, and image support.
//!
//! pi-mono parity: ports `~/workspace/dots/env/.pi/agent/extensions/tools/read.ts`.
//! Differences from pi's stock built-in:
//! - line-numbered output (`N: content`)
//! - directory listing folded in (no separate Ls round-trip needed)
//! - `.env*` secret guard with example/sample/template exceptions
//! - `~` expansion + leading `@` strip
//! - image files returned as base64 image content blocks
//! - per-line byte cap so a single absurd line can't blow the budget

const std = @import("std");
const protocol = @import("../../agent3/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const output_buffer = @import("../../lib/output_buffer.zig");
const image = @import("../../image/root.zig");

const MAX_LINES: usize = 500;
const MAX_FILE_BYTES: usize = 64 * 1024;
const MAX_LINE_BYTES: usize = 4096;
const MAX_DIR_ENTRIES: usize = 1000;

const SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The absolute path to the file or directory (MUST be absolute, not relative)."},"read_range":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2,"description":"An array of two integers specifying the start and end line numbers to view. Line numbers are 1-indexed. If not provided, defaults to [1, 500]. Examples: [500, 700], [700, 1400]"}},"required":["path"]}
;

const DESCRIPTION =
    "Read a file or list a directory from the file system. If the path is a directory, it returns a list of entries. If the file or directory doesn't exist, an error is returned.\n\n" ++
    "- The path parameter MUST be an absolute path.\n" ++
    "- By default, this tool returns the first 500 lines. To read more, call it multiple times with different read_ranges.\n" ++
    "- Use the Grep tool to find specific content in large files or files with long lines.\n" ++
    "- If you are unsure of the correct file path, use the glob tool to look up filenames by glob pattern.\n" ++
    "- The contents are returned with each line prefixed by its line number. For example, if a file has contents \"abc\\n\", you will receive \"1: abc\\n\". For directories, entries are returned one per line (without line numbers) with a trailing \"/\" for subdirectories.\n" ++
    "- This tool can read images (such as PNG, JPEG, and GIF files) and present them to the model visually.\n" ++
    "- When possible, call this tool in parallel for all files you will want to read.\n" ++
    "      - Avoid tiny repeated slices (e.g., 50‑line chunks). If you need more context from the same file, read a larger range or the full default window instead.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "read",
        .description = DESCRIPTION,
        .label = "Read",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Read file contents",
        .prompt_guidelines = &.{"Use read to examine files instead of cat or sed."},
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "read" },
    };
}

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    _: protocol.AbortSignal,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "read tool: missing context")));

    const path = util.getString(args, "path") orelse
        return util.errorResult(allocator, "read tool: missing 'path' argument");

    const resolved = util.resolvePath(allocator, path, ctx.cwd) catch
        return util.errorResult(allocator, "read tool: failed to resolve path");

    if (util.isSecretFile(resolved)) {
        return util.errorf(
            allocator,
            "refused to read {s}: file may contain secrets. ask the user to share relevant values.",
            .{std.fs.path.basename(resolved)},
        );
    }

    // Stat to disambiguate file vs directory.
    const stat = std.fs.cwd().statFile(resolved) catch |err| {
        return util.errorf(allocator, "read tool: {s}: {s}", .{ resolved, @errorName(err) });
    };

    if (stat.kind == .directory) {
        return readDirectory(allocator, resolved);
    }

    const maybe_image_mime = sniffImageMime(resolved) catch |err|
        return util.errorf(allocator, "failed to read file: {s}", .{@errorName(err)});
    if (maybe_image_mime) |mime| {
        return readImage(allocator, resolved, mime, .{ .auto_resize = ctx.image_auto_resize });
    }

    return readTextFile(allocator, resolved, util.getIntPair(args, "read_range"));
}

fn sniffImageMime(path: []const u8) !?image.Mime {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header_buf: [64]u8 = undefined;
    const header_len = try file.readAll(&header_buf);
    return image.sniffMime(header_buf[0..header_len]);
}

fn readImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    mime: image.Mime,
    policy: image.InlinePolicy,
) protocol.AgentToolResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err|
        return util.errorf(allocator, "failed to open image: {s}", .{@errorName(err)});
    defer file.close();
    // 16MB cap on raw image bytes — generous but bounded.
    const raw = file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch |err|
        return util.errorf(allocator, "failed to read image: {s}", .{@errorName(err)});
    defer allocator.free(raw);

    const mime_str = image.mimeString(mime);
    const dims = image.sniffDimensions(raw, mime);
    const decision = image.evaluateInlineImage(raw.len, dims, policy);

    const companion = switch (decision) {
        .attach_original => std.fmt.allocPrint(allocator, "Read image file [{s}]", .{mime_str}) catch
            return util.errorResult(allocator, "image companion alloc failed"),
        .needs_resize => std.fmt.allocPrint(
            allocator,
            "Read image file [{s}]\n{s}",
            .{ mime_str, image.omittedInlineNote() },
        ) catch return util.errorResult(allocator, "image companion alloc failed"),
    };
    errdefer allocator.free(companion);

    switch (decision) {
        .needs_resize => {
            const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
                return util.errorResult(allocator, "image alloc failed");
            blocks[0] = .{ .text = .{ .text = companion } };
            return .{ .content = blocks };
        },
        .attach_original => {
            const Encoder = std.base64.standard.Encoder;
            const encoded_len = Encoder.calcSize(raw.len);
            const encoded = allocator.alloc(u8, encoded_len) catch
                return util.errorResult(allocator, "image alloc failed");
            errdefer allocator.free(encoded);
            _ = Encoder.encode(encoded, raw);

            const mime_owned = allocator.dupe(u8, mime_str) catch
                return util.errorResult(allocator, "image mime alloc failed");
            errdefer allocator.free(mime_owned);

            const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 2) catch
                return util.errorResult(allocator, "image alloc failed");
            blocks[0] = .{ .text = .{ .text = companion } };
            blocks[1] = .{ .image = .{ .data = encoded, .mime_type = mime_owned } };
            return .{ .content = blocks };
        },
    }
}

fn readDirectory(allocator: std.mem.Allocator, path: []const u8) protocol.AgentToolResult {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err|
        return util.errorf(allocator, "cannot list directory: {s}", .{@errorName(err)});
    defer dir.close();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        const formatted = if (entry.kind == .directory)
            std.fmt.allocPrint(allocator, "{s}/", .{entry.name}) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;
        names.append(allocator, formatted) catch {
            allocator.free(formatted);
            continue;
        };
    }

    std.mem.sort([]const u8, names.items, {}, lessThanStrings);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    output_buffer.appendHeadTail(&aw.writer, names.items, MAX_DIR_ENTRIES, "... [{d} more entries] ...") catch
        return util.errorResult(allocator, "directory listing failed");

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "directory listing alloc failed");
    return util.textResult(allocator, out);
}

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn readTextFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    range: ?[2]i64,
) protocol.AgentToolResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err|
        return util.errorf(allocator, "failed to read file: {s}", .{@errorName(err)});
    defer file.close();
    // Cap raw read at 4MB so a runaway file doesn't OOM us. Truncation
    // happens after numbering — the per-line + per-output-byte limits
    // pare it down further.
    const raw = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch |err|
        return util.errorf(allocator, "failed to read file: {s}", .{@errorName(err)});
    defer allocator.free(raw);

    // Split into lines (preserving empty trailing line for parity with
    // String.split('\n') in pi).
    var all_lines: std.ArrayList([]const u8) = .empty;
    defer all_lines.deinit(allocator);
    var line_it = std.mem.splitScalar(u8, raw, '\n');
    while (line_it.next()) |line| all_lines.append(allocator, line) catch break;
    const total_lines = all_lines.items.len;

    const start: usize = blk: {
        const r0: i64 = if (range) |r| r[0] else 1;
        break :blk @intCast(@max(@as(i64, 1), r0));
    };
    const end: usize = blk: {
        const def_end: i64 = @intCast(@min(total_lines, start + MAX_LINES - 1));
        const r1: i64 = if (range) |r| r[1] else def_end;
        const clamped = @min(@as(i64, @intCast(total_lines)), r1);
        break :blk @intCast(@max(@as(i64, @intCast(start)), clamped));
    };

    var numbered: std.ArrayList([]const u8) = .empty;
    defer {
        for (numbered.items) |line| allocator.free(line);
        numbered.deinit(allocator);
    }

    var i: usize = if (start == 0) 0 else start - 1;
    const end_idx: usize = end;
    while (i < end_idx and i < total_lines) : (i += 1) {
        const line = all_lines.items[i];
        const truncated_line = if (line.len > MAX_LINE_BYTES) blk: {
            const head_slice = line[0..MAX_LINE_BYTES];
            break :blk std.fmt.allocPrint(allocator, "{d}: {s}... (line truncated)", .{ i + 1, head_slice }) catch continue;
        } else std.fmt.allocPrint(allocator, "{d}: {s}", .{ i + 1, line }) catch continue;
        numbered.append(allocator, truncated_line) catch {
            allocator.free(truncated_line);
            continue;
        };
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // First pass: try the un-truncated join. If it fits in the byte
    // budget, ship it. Otherwise fall back to head+tail truncation.
    var total_bytes: usize = 0;
    for (numbered.items) |line| total_bytes += line.len + 1;

    if (total_bytes <= MAX_FILE_BYTES) {
        for (numbered.items, 0..) |line, idx| {
            if (idx > 0) aw.writer.writeAll("\n") catch break;
            aw.writer.writeAll(line) catch break;
        }
    } else {
        output_buffer.appendHeadTail(
            &aw.writer,
            numbered.items,
            MAX_LINES,
            "... [{d} lines truncated, 64KB limit reached] ...",
        ) catch {};
    }

    // Trailing notice if we showed only a window of the file.
    if (end < total_lines) {
        aw.writer.print(
            "\n\n(showing lines {d}-{d} of {d}. use read_range to see more.)",
            .{ start, end, total_lines },
        ) catch {};
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "read alloc failed");
    return util.textResult(allocator, out);
}

fn usizeFromI64(v: i64) usize {
    if (v < 0) return 0;
    return @intCast(v);
}

fn pngHeader(width: u32, height: u32) [24]u8 {
    return .{
        0x89,                                    0x50,                                    0x4E,                                   0x47,                            0x0D,                                     0x0A,                                     0x1A,                                    0x0A,
        0x00,                                    0x00,                                    0x00,                                   0x0D,                            0x49,                                     0x48,                                     0x44,                                    0x52,
        @as(u8, @intCast((width >> 24) & 0xFF)), @as(u8, @intCast((width >> 16) & 0xFF)), @as(u8, @intCast((width >> 8) & 0xFF)), @as(u8, @intCast(width & 0xFF)), @as(u8, @intCast((height >> 24) & 0xFF)), @as(u8, @intCast((height >> 16) & 0xFF)), @as(u8, @intCast((height >> 8) & 0xFF)), @as(u8, @intCast(height & 0xFF)),
    };
}

test "sniffImageMime detects supported image bytes regardless of extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(16, 32);
    try tmp.dir.writeFile(.{ .sub_path = "mystery.txt", .data = &png });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const path = try std.fs.path.join(allocator, &.{ cwd, "mystery.txt" });
    defer allocator.free(path);

    try std.testing.expectEqual(image.Mime.png, (try sniffImageMime(path)).?);
}

test "readImage omits oversized inline images when auto-resize is enabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(300, 200);
    try tmp.dir.writeFile(.{ .sub_path = "large.png", .data = &png });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const path = try std.fs.path.join(allocator, &.{ cwd, "large.png" });
    defer allocator.free(path);

    const result = readImage(allocator, path, .png, .{
        .auto_resize = true,
        .max_width = 100,
        .max_height = 100,
        .max_base64_bytes = 1024,
    });
    defer result.free(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    switch (result.content[0]) {
        .text => |text| try std.testing.expectEqualStrings(
            "Read image file [image/png]\n[Image omitted: could not be resized below the inline image size limit.]",
            text.text,
        ),
        else => return error.ExpectedTextBlock,
    }
}

test "readImage attaches original when auto-resize is disabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(300, 200);
    try tmp.dir.writeFile(.{ .sub_path = "large.png", .data = &png });

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const path = try std.fs.path.join(allocator, &.{ cwd, "large.png" });
    defer allocator.free(path);

    const result = readImage(allocator, path, .png, .{
        .auto_resize = false,
        .max_width = 100,
        .max_height = 100,
        .max_base64_bytes = 8,
    });
    defer result.free(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.content.len);
    switch (result.content[0]) {
        .text => |text| try std.testing.expectEqualStrings("Read image file [image/png]", text.text),
        else => return error.ExpectedTextBlock,
    }
    switch (result.content[1]) {
        .image => |img| {
            try std.testing.expectEqualStrings("image/png", img.mime_type);
            const Encoder = std.base64.standard.Encoder;
            const expected_len = Encoder.calcSize(png.len);
            const expected = try allocator.alloc(u8, expected_len);
            defer allocator.free(expected);
            _ = Encoder.encode(expected, &png);
            try std.testing.expectEqualStrings(expected, img.data);
        },
        else => return error.ExpectedImageBlock,
    }
}

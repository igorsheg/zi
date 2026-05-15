const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const output_buffer = @import("output_buffer.zig");
const image = @import("../../image/root.zig");
const zio_fs = @import("../../zio/root.zig").file;
const anchors = @import("anchors.zig");
const observations = @import("observations.zig");

const MAX_LINES: usize = 500;
const MAX_FILE_BYTES: usize = util.Limits.text_result_bytes;
const MAX_LINE_BYTES: usize = 4096;
const MAX_DIR_ENTRIES: usize = util.Limits.listing_entries;
const MAX_DIR_SCAN_ENTRIES: usize = util.Limits.listing_scan_entries;

const SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The absolute path to the file or directory (MUST be absolute, not relative)."},"read_range":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2,"description":"An array of two integers specifying the start and end line numbers to view. Line numbers are 1-indexed. If not provided, defaults to [1, 500]. Examples: [500, 700], [700, 1400]"}},"required":["path"]}
;

const DESCRIPTION =
    "Read a file or list a directory from the file system. If the path is a directory, it returns a list of entries. If the file or directory doesn't exist, an error is returned.\n\n" ++
    "- The path parameter MUST be an absolute path.\n" ++
    "- By default, this tool returns the first 500 lines. To read more, call it multiple times with different read_ranges.\n" ++
    "- Use the Grep tool to find specific content in large files or files with long lines.\n" ++
    "- If you are unsure of the correct file path, use the glob tool to look up filenames by glob pattern.\n" ++
    "- Text file lines are returned with edit anchors in the form LINE:HASH: text. Use these anchors with the edit tool. For directories, entries are returned one per line (without line numbers) with a trailing \"/\" for subdirectories.\n" ++
    "- This tool can read images (such as PNG, JPEG, and GIF files) and present them to the model visually.\n" ++
    "- When possible, call this tool in parallel for all files you will want to read.\n" ++
    "      - Avoid tiny repeated slices (e.g., 50‑line chunks). If you need more context from the same file, read a larger range or the full default window instead.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "read",
        .description = DESCRIPTION,
        .label = "Read",
        .display_call = "path",
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
    tool_call_id: []const u8,
    args: std.json.Value,
    signal: protocol.Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolExecution {
    return .{ .ready = executeSync(raw_ctx, allocator, tool_call_id, args, signal, on_update, update_ctx) };
}

fn executeSync(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    _: protocol.Token,
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

    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, resolved, .{}) catch |err| {
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

    return readTextFile(allocator, ctx, resolved, util.getIntPair(args, "read_range"));
}

fn sniffImageMime(path: []const u8) !?image.Mime {
    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);

    var header_buf: [64]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &header_buf);
    const header = file_reader.interface.allocRemaining(std.heap.smp_allocator, .limited(64)) catch return null;
    defer std.heap.smp_allocator.free(header);
    return image.sniffMime(header);
}

fn readImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    mime: image.Mime,
    policy: image.InlinePolicy,
) protocol.AgentToolResult {
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch |err|
        return util.errorf(allocator, "failed to open image: {s}", .{@errorName(err)});
    defer file.close(std.Options.debug_io);
    var image_read_buf: [4096]u8 = undefined;
    var image_reader = file.reader(std.Options.debug_io, &image_read_buf);
    const raw = image_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |err|
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
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{ .iterate = true }) catch |err|
        return util.errorf(allocator, "cannot list directory: {s}", .{@errorName(err)});
    defer dir.close(std.Options.debug_io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    var scanned: usize = 0;
    while (it.next(std.Options.debug_io) catch null) |entry| {
        if (scanned >= MAX_DIR_SCAN_ENTRIES) break;
        scanned += 1;
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
    if (scanned >= MAX_DIR_SCAN_ENTRIES) {
        aw.writer.print("\n\n(stopped after {d} entries; narrow the path to inspect more.)", .{MAX_DIR_SCAN_ENTRIES}) catch {};
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "directory listing alloc failed");
    var details_obj: std.json.ObjectMap = .{};
    errdefer details_obj.deinit(allocator);
    util.jsonPutString(&details_obj, allocator, "kind", "directory") catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutString(&details_obj, allocator, "path", path) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutBool(&details_obj, allocator, "raw_filesystem_listing", true) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutInt(&details_obj, allocator, "entries_returned", @intCast(@min(names.items.len, MAX_DIR_ENTRIES))) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutInt(&details_obj, allocator, "entries_scanned", @intCast(scanned)) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutBool(&details_obj, allocator, "scan_stopped", scanned >= MAX_DIR_SCAN_ENTRIES) catch return util.ownedTextResult(allocator, out, false);
    var result = util.ownedTextResult(allocator, out, false);
    result.details = .{ .object = details_obj };
    return result;
}

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn readTextFile(
    allocator: std.mem.Allocator,
    _: *util.BuiltinCtx,
    path: []const u8,
    range: ?[2]i64,
) protocol.AgentToolResult {
    var input = zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path, .{ .max_bytes = 4 * 1024 * 1024 }) catch |err|
        return util.errorf(allocator, "failed to read file: {s}", .{@errorName(err)});
    defer input.deinit(allocator);
    const raw = input.bytes();
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch null;
    const observe_effect = if (stat) |s| observations.sideEffectFromBytes(allocator, path, s, raw, .read) catch null else null;

    var total_lines: usize = 1;
    for (raw) |byte| {
        if (byte == '\n') total_lines += 1;
    }

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

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var bytes_written: usize = 0;
    var line_it = std.mem.splitScalar(u8, raw, '\n');
    var line_no: usize = 1;
    var first = true;
    while (line_it.next()) |line| : (line_no += 1) {
        if (line_no < start) continue;
        if (line_no > end) break;
        if (!first) {
            aw.writer.writeAll("\n") catch break;
            bytes_written += 1;
        }
        first = false;
        const anchor_line = std.mem.trimEnd(u8, line, "\r");
        if (line.len > MAX_LINE_BYTES) {
            const kept = line[0..MAX_LINE_BYTES];
            anchors.write(&aw.writer, line_no, anchor_line) catch break;
            aw.writer.print(" {s}... (line truncated)", .{kept}) catch break;
            bytes_written += std.fmt.count("{d}:0000: ", .{line_no}) + kept.len + "... (line truncated)".len;
        } else {
            anchors.write(&aw.writer, line_no, anchor_line) catch break;
            aw.writer.print(" {s}", .{line}) catch break;
            bytes_written += std.fmt.count("{d}:0000: ", .{line_no}) + line.len;
        }
        if (bytes_written >= MAX_FILE_BYTES) {
            aw.writer.writeAll("\n... [output truncated, 64KB limit reached] ...") catch {};
            break;
        }
    }

    if (end < total_lines) {
        aw.writer.print(
            "\n\n(showing lines {d}-{d} of {d}. use read_range to see more.)",
            .{ start, end, total_lines },
        ) catch {};
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "read alloc failed");
    var details_obj: std.json.ObjectMap = .{};
    errdefer details_obj.deinit(allocator);
    util.jsonPutString(&details_obj, allocator, "kind", "file") catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutString(&details_obj, allocator, "path", path) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutInt(&details_obj, allocator, "start_line", @intCast(start)) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutInt(&details_obj, allocator, "end_line", @intCast(end)) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutInt(&details_obj, allocator, "total_lines", @intCast(total_lines)) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutBool(&details_obj, allocator, "truncated", bytes_written >= MAX_FILE_BYTES or end < total_lines) catch return util.ownedTextResult(allocator, out, false);
    util.jsonPutString(&details_obj, allocator, "line_hash_scheme", "zi-line-v1") catch return util.ownedTextResult(allocator, out, false);
    if (observe_effect) |effect| switch (effect) {
        .observe_file => |event| util.jsonPutOwnedString(&details_obj, allocator, "observation_hash", observations.hashHex(allocator, event.hash) catch return util.ownedTextResult(allocator, out, false)) catch return util.ownedTextResult(allocator, out, false),
    };
    var result = util.ownedTextResult(allocator, out, false);
    result.details = .{ .object = details_obj };
    if (observe_effect) |effect| {
        const side_effects = allocator.alloc(protocol.ToolSideEffect, 1) catch return result;
        side_effects[0] = effect;
        result.side_effects = side_effects;
    }
    return result;
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

fn tmpPath(allocator: std.mem.Allocator, tmp: anytype, sub_path: []const u8) ![]u8 {
    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, sub_path });
}

fn expectOnlyText(result: protocol.AgentToolResult) ![]const u8 {
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    return switch (result.content[0]) {
        .text => |text| text.text,
        else => error.ExpectedTextBlock,
    };
}

test "readTextFile numbers requested ranges and caps oversized lines" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const long_line = try allocator.alloc(u8, MAX_LINE_BYTES + 8);
    defer allocator.free(long_line);
    @memset(long_line, 'x');

    const data = try std.fmt.allocPrint(allocator, "first\n{s}\nthird\nfourth\n", .{long_line});
    defer allocator.free(data);
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "story.txt", .data = data });

    const path = try tmpPath(allocator, &tmp, "story.txt");
    defer allocator.free(path);

    var ctx: util.BuiltinCtx = .{ .cwd = "" };
    defer ctx.deinit(allocator);
    const result = readTextFile(allocator, &ctx, path, .{ 2, 3 });
    defer result.free(allocator);
    const text = try expectOnlyText(result);

    try std.testing.expect(std.mem.startsWith(u8, text, "2:"));
    try std.testing.expect(std.mem.indexOf(u8, text, "... (line truncated)\n3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "showing lines 2-3 of 5") != null);
}

test "sniffImageMime detects supported image bytes regardless of extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(16, 32);
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "mystery.txt", .data = &png });

    const path = try tmpPath(allocator, &tmp, "mystery.txt");
    defer allocator.free(path);

    try std.testing.expectEqual(image.Mime.png, (try sniffImageMime(path)).?);
}

test "readImage omits oversized inline images when auto-resize is enabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(300, 200);
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "large.png", .data = &png });

    const path = try tmpPath(allocator, &tmp, "large.png");
    defer allocator.free(path);

    const result = readImage(allocator, path, .png, .{
        .auto_resize = true,
        .max_width = 100,
        .max_height = 100,
        .max_base64_bytes = 1024,
    });
    defer result.free(allocator);

    try std.testing.expectEqualStrings(
        "Read image file [image/png]\n[Image omitted: could not be resized below the inline image size limit.]",
        try expectOnlyText(result),
    );
}

test "readImage attaches original when auto-resize is disabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(300, 200);
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "large.png", .data = &png });

    const path = try tmpPath(allocator, &tmp, "large.png");
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

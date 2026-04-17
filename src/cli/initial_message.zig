const std = @import("std");
const ai = @import("../ai/root.zig");
const plan = @import("plan.zig");
const result = @import("result.zig");
const tool_util = @import("../tools/util.zig");
const image_mod = @import("../image/root.zig");

const max_batch_file_bytes = 16 * 1024 * 1024;

pub const PreparedInitialMessage = struct {
    text: []const u8,
    images: []const ai.protocol.ImageContent = &.{},

    pub fn toUserContent(
        self: PreparedInitialMessage,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!ai.protocol.UserMessage.UserMessageContent {
        if (self.images.len == 0) return .{ .text = self.text };

        const blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, self.images.len + 1);
        blocks[0] = .{ .text = .{ .text = self.text } };
        for (self.images, 0..) |image, i| {
            blocks[i + 1] = .{ .image = image };
        }
        return .{ .blocks = blocks };
    }
};

pub const PrepareInitialResult = union(enum) {
    ok: ?PreparedInitialMessage,
    err: result.ExecutionDiagnostic,
};

pub const PrepareBatchResult = union(enum) {
    ok: PreparedInitialMessage,
    err: result.ExecutionDiagnostic,
};

pub const PrepareOptions = struct {
    inline_image_policy: image_mod.InlinePolicy = .{},
};

pub fn prepareInitialMessage(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    sources: plan.PromptSources,
    options: PrepareOptions,
) std.mem.Allocator.Error!PrepareInitialResult {
    var text_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer text_out.deinit();

    var images: std.ArrayList(ai.protocol.ImageContent) = .empty;
    defer images.deinit(allocator);
    errdefer freeImages(allocator, images.items);

    var wrote_text = false;

    if (sources.stdin_text) |stdin_text| {
        writeAllocating(&text_out.writer, stdin_text);
        wrote_text = true;
    }

    for (sources.file_args) |file_arg| {
        switch (try appendFileInput(allocator, cwd, file_arg, &text_out.writer, &images, options)) {
            .ok => |appended| {
                if (appended) wrote_text = true;
            },
            .err => |diag| return .{ .err = diag },
        }
    }

    if (sources.prompt_text) |prompt_text| {
        writeAllocating(&text_out.writer, prompt_text);
        wrote_text = true;
    }

    if (!wrote_text) return .{ .ok = null };

    const text = try text_out.toOwnedSlice();
    const owned_images = if (images.items.len == 0)
        &.{}
    else
        try images.toOwnedSlice(allocator);
    return .{ .ok = .{ .text = text, .images = owned_images } };
}

pub fn prepareBatchInput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    sources: plan.PromptSources,
    options: PrepareOptions,
) std.mem.Allocator.Error!PrepareBatchResult {
    return switch (try prepareInitialMessage(allocator, cwd, sources, options)) {
        .ok => |prepared| if (prepared) |input|
            .{ .ok = input }
        else
            .{ .err = .batch_prompt_sources_resolved_empty },
        .err => |diag| .{ .err = diag },
    };
}

const AppendFileResult = union(enum) {
    ok: bool,
    err: result.ExecutionDiagnostic,
};

fn appendFileInput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    file_arg: []const u8,
    writer: *std.Io.Writer,
    images: *std.ArrayList(ai.protocol.ImageContent),
    options: PrepareOptions,
) std.mem.Allocator.Error!AppendFileResult {
    const resolved_path = try tool_util.resolvePath(allocator, file_arg, cwd);
    defer allocator.free(resolved_path);

    const file = std.fs.openFileAbsolute(resolved_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return .{ .err = .{ .batch_file_not_found = try allocator.dupe(u8, resolved_path) } };
        },
        else => {
            return .{ .err = .{ .batch_file_read_failed = .{
                .path = try allocator.dupe(u8, resolved_path),
                .err_name = @errorName(err),
            } } };
        },
    };
    defer file.close();

    const file_stat = file.stat() catch |err| {
        return .{ .err = .{ .batch_file_read_failed = .{
            .path = try allocator.dupe(u8, resolved_path),
            .err_name = @errorName(err),
        } } };
    };
    if (file_stat.size == 0) return .{ .ok = false };

    const raw = file.readToEndAlloc(allocator, max_batch_file_bytes) catch |err| {
        return .{ .err = .{ .batch_file_read_failed = .{
            .path = try allocator.dupe(u8, resolved_path),
            .err_name = @errorName(err),
        } } };
    };
    defer allocator.free(raw);

    if (image_mod.sniffMime(raw)) |mime| {
        const decision = image_mod.evaluateInlineImage(
            raw.len,
            image_mod.sniffDimensions(raw, mime),
            options.inline_image_policy,
        );
        switch (decision) {
            .attach_original => {
                const encoded = try encodeBase64Owned(allocator, raw);
                errdefer allocator.free(encoded);

                const mime_owned = try allocator.dupe(u8, image_mod.mimeString(mime));
                errdefer allocator.free(mime_owned);

                try images.append(allocator, .{ .data = encoded, .mime_type = mime_owned });
                printAllocating(writer, "<file name=\"{s}\"></file>\n", .{resolved_path});
                return .{ .ok = true };
            },
            .needs_resize => {
                printAllocating(writer, "<file name=\"{s}\">{s}</file>\n", .{ resolved_path, image_mod.omittedInlineNote() });
                return .{ .ok = true };
            },
        }
    }

    printAllocating(writer, "<file name=\"{s}\">\n", .{resolved_path});
    writeAllocating(writer, raw);
    writeAllocating(writer, "\n</file>\n");
    return .{ .ok = true };
}

fn writeAllocating(writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch unreachable;
}

fn printAllocating(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch unreachable;
}

fn encodeBase64Owned(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const Encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, Encoder.calcSize(raw.len));
    _ = Encoder.encode(encoded, raw);
    return encoded;
}

fn freeImages(allocator: std.mem.Allocator, images: []const ai.protocol.ImageContent) void {
    for (images) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
}

fn pngHeader(width: u32, height: u32) [24]u8 {
    return .{
        0x89,                                    0x50,                                    0x4E,                                   0x47,                            0x0D,                                     0x0A,                                     0x1A,                                    0x0A,
        0x00,                                    0x00,                                    0x00,                                   0x0D,                            0x49,                                     0x48,                                     0x44,                                    0x52,
        @as(u8, @intCast((width >> 24) & 0xFF)), @as(u8, @intCast((width >> 16) & 0xFF)), @as(u8, @intCast((width >> 8) & 0xFF)), @as(u8, @intCast(width & 0xFF)), @as(u8, @intCast((height >> 24) & 0xFF)), @as(u8, @intCast((height >> 16) & 0xFF)), @as(u8, @intCast((height >> 8) & 0xFF)), @as(u8, @intCast(height & 0xFF)),
    };
}

test "prepareBatchInput merges stdin file text and prompt in pi order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "hello from file" });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const prepared = try prepareBatchInput(allocator, cwd, .{
        .stdin_text = "from stdin\n",
        .file_args = &.{"notes.txt"},
        .prompt_text = "and prompt",
    }, .{});
    switch (prepared) {
        .ok => |input| {
            const expected = try std.fmt.allocPrint(
                allocator,
                "from stdin\n<file name=\"{s}/notes.txt\">\nhello from file\n</file>\nand prompt",
                .{cwd},
            );
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, input.text);
            try std.testing.expectEqual(@as(usize, 0), input.images.len);
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "prepareBatchInput attaches image files and skips empty files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });
    const png = pngHeader(64, 32);
    try tmp.dir.writeFile(.{ .sub_path = "shot.bin", .data = &png });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const prepared = try prepareBatchInput(allocator, cwd, .{
        .file_args = &.{ "empty.txt", "shot.bin" },
    }, .{});
    switch (prepared) {
        .ok => |input| {
            try std.testing.expectEqual(@as(usize, 1), input.images.len);
            try std.testing.expectEqualStrings("image/png", input.images[0].mime_type);
            try std.testing.expect(std.mem.indexOf(u8, input.text, "empty.txt") == null);
            try std.testing.expect(std.mem.indexOf(u8, input.text, "shot.bin") != null);
            const content = try input.toUserContent(allocator);
            switch (content) {
                .blocks => |blocks| {
                    try std.testing.expectEqual(@as(usize, 2), blocks.len);
                    try std.testing.expect(blocks[1] == .image);
                },
                .text => return error.ExpectedBlocks,
            }
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "prepareBatchInput omits oversized images when auto-resize is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = pngHeader(640, 480);
    try tmp.dir.writeFile(.{ .sub_path = "large.bin", .data = &png });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const prepared = try prepareBatchInput(allocator, cwd, .{
        .file_args = &.{"large.bin"},
    }, .{ .inline_image_policy = .{
        .auto_resize = true,
        .max_width = 100,
        .max_height = 100,
        .max_base64_bytes = 1024,
    } });
    switch (prepared) {
        .ok => |input| {
            try std.testing.expectEqual(@as(usize, 0), input.images.len);
            try std.testing.expect(std.mem.indexOf(u8, input.text, image_mod.omittedInlineNote()) != null);
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "prepareInitialMessage treats empty interactive file inputs as no startup content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const prepared = try prepareInitialMessage(allocator, cwd, .{
        .file_args = &.{"empty.txt"},
    }, .{});
    switch (prepared) {
        .ok => |input| try std.testing.expect(input == null),
        .err => return error.UnexpectedDiagnostic,
    }
}

test "prepareBatchInput reports missing file arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const prepared = try prepareBatchInput(allocator, cwd, .{
        .file_args = &.{"missing.txt"},
    }, .{});
    switch (prepared) {
        .err => |diag| switch (diag) {
            .batch_file_not_found => |path| try std.testing.expect(std.mem.endsWith(u8, path, "/missing.txt")),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

const std = @import("std");
const ai = @import("../ai/root.zig");
const plan = @import("plan.zig");
const result = @import("result.zig");
const tool_util = @import("../tools/util.zig");

const max_batch_file_bytes = 16 * 1024 * 1024;

pub const PreparedBatchInput = struct {
    text: []const u8,
    images: []const ai.protocol.ImageContent = &.{},

    pub fn toUserContent(
        self: PreparedBatchInput,
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

pub const PrepareResult = union(enum) {
    ok: PreparedBatchInput,
    err: result.ExecutionDiagnostic,
};

pub fn prepareBatchInput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    sources: plan.BatchPromptSources,
) std.mem.Allocator.Error!PrepareResult {
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
        switch (try appendFileInput(allocator, cwd, file_arg, &text_out.writer, &images)) {
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

    if (!wrote_text) return .{ .err = .batch_prompt_sources_resolved_empty };

    const text = try text_out.toOwnedSlice();
    const owned_images = if (images.items.len == 0)
        &.{}
    else
        try images.toOwnedSlice(allocator);
    return .{ .ok = .{ .text = text, .images = owned_images } };
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

    if (imageMime(resolved_path)) |mime| {
        const raw = file.readToEndAlloc(allocator, max_batch_file_bytes) catch |err| {
            return .{ .err = .{ .batch_file_read_failed = .{
                .path = try allocator.dupe(u8, resolved_path),
                .err_name = @errorName(err),
            } } };
        };
        defer allocator.free(raw);

        const encoded = try encodeBase64Owned(allocator, raw);
        errdefer allocator.free(encoded);

        const mime_owned = try allocator.dupe(u8, mime);
        errdefer allocator.free(mime_owned);

        try images.append(allocator, .{ .data = encoded, .mime_type = mime_owned });
        printAllocating(writer, "<file name=\"{s}\"></file>\n", .{resolved_path});
        return .{ .ok = true };
    }

    const raw = file.readToEndAlloc(allocator, max_batch_file_bytes) catch |err| {
        return .{ .err = .{ .batch_file_read_failed = .{
            .path = try allocator.dupe(u8, resolved_path),
            .err_name = @errorName(err),
        } } };
    };
    defer allocator.free(raw);

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

fn imageMime(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0 or ext.len > 5) return null;
    var lower_buf: [5]u8 = undefined;
    const lower = std.ascii.lowerString(lower_buf[0..ext.len], ext);
    if (std.mem.eql(u8, lower, ".jpg") or std.mem.eql(u8, lower, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, lower, ".png")) return "image/png";
    if (std.mem.eql(u8, lower, ".gif")) return "image/gif";
    if (std.mem.eql(u8, lower, ".webp")) return "image/webp";
    return null;
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
    });
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
    try tmp.dir.writeFile(.{ .sub_path = "shot.png", .data = "PNGDATA" });
    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const prepared = try prepareBatchInput(allocator, cwd, .{
        .file_args = &.{ "empty.txt", "shot.png" },
    });
    switch (prepared) {
        .ok => |input| {
            try std.testing.expectEqual(@as(usize, 1), input.images.len);
            try std.testing.expectEqualStrings("image/png", input.images[0].mime_type);
            try std.testing.expect(std.mem.indexOf(u8, input.text, "empty.txt") == null);
            try std.testing.expect(std.mem.indexOf(u8, input.text, "shot.png") != null);
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
    });
    switch (prepared) {
        .err => |diag| switch (diag) {
            .batch_file_not_found => |path| try std.testing.expect(std.mem.endsWith(u8, path, "/missing.txt")),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

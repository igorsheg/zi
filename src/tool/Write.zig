const std = @import("std");
const ToolContract = @import("Tool.zig");
const AtomicWrite = @import("AtomicWrite.zig");
const Path = @import("Path.zig");
const OutputCap = @import("OutputCap.zig");

const maximum_content_bytes: usize = 4 * 1024 * 1024;
const maximum_json_bytes: usize = 32 * 1024 * 1024;

pub const Config = struct {
    home: ?[]const u8 = null,
};

pub const Write = struct {
    config: Config = .{},

    pub fn tool(self: *Write) ToolContract.Tool {
        return ToolContract.Tool.from(self, definition, .{
            .arg_name = "path",
            .output_style = .unified_diff,
        });
    }

    pub fn run(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Write,
        args_json: ?[]const u8,
        run_context: ToolContract.RunContext,
    ) ToolContract.RunError!ToolContract.Result {
        const input = args_json orelse "{}";
        if (input.len > maximum_json_bytes) {
            return resultCopy(allocator, "invalid arguments: input exceeds 33554432 bytes");
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return resultFormat(
                allocator,
                "invalid arguments: {s}",
                .{@errorName(err)},
            ),
        };
        defer parsed.deinit();
        if (parsed.value != .object) return resultCopy(allocator, "missing 'path' argument");
        const path_value = parsed.value.object.get("path") orelse
            return resultCopy(allocator, "missing 'path' argument");
        if (path_value != .string or path_value.string.len == 0)
            return resultCopy(allocator, "missing 'path' argument");
        const content_value = parsed.value.object.get("content") orelse
            return resultCopy(allocator, "missing 'content' argument");
        if (content_value != .string)
            return resultCopy(allocator, "missing 'content' argument");
        const content = content_value.string;
        if (content.len > maximum_content_bytes) {
            return resultFormat(
                allocator,
                "content exceeds {d} bytes: refusing to write",
                .{maximum_content_bytes},
            );
        }
        const path = try Path.expandHome(allocator, path_value.string, self.config.home);
        defer allocator.free(path);

        const atomic = try AtomicWrite.writeWithDiff(allocator, io, path, content, .{
            .maximum_file_bytes = maximum_content_bytes,
            .maximum_diff_bytes = OutputCap.maximum_capture_bytes,
        });
        return switch (atomic) {
            .diagnostic => |diagnostic| .{ .output = diagnostic },
            .written => |written| if (written.created)
                createdResult(allocator, content, path, written.diff, run_context)
            else
                .{ .output = written.diff },
        };
    }

    pub fn preprocess(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Write,
        args_json: ?[]const u8,
    ) error{OutOfMemory}!?[]u8 {
        return Path.preprocessArgs(
            allocator,
            io,
            args_json,
            self.config.home,
            maximum_json_bytes,
        );
    }
};

fn createdResult(
    allocator: std.mem.Allocator,
    content: []const u8,
    path: []const u8,
    diff: []u8,
    run_context: ToolContract.RunContext,
) ToolContract.RunError!ToolContract.Result {
    allocator.free(diff);
    const output = if (content.len == 0)
        try std.fmt.allocPrint(allocator, "created {s} (empty)", .{path})
    else blk: {
        const lines = countLines(content);
        break :blk try std.fmt.allocPrint(
            allocator,
            "created {s} ({d} line{s}, {d} byte{s})",
            .{
                path,
                lines,
                if (lines == 1) "" else "s",
                content.len,
                if (content.len == 1) "" else "s",
            },
        );
    };
    errdefer allocator.free(output);
    var summarizes_display = false;
    if (content.len > 0) {
        if (run_context.display) |display| {
            try display.emit(content);
            summarizes_display = true;
        }
    }
    return .{ .output = output, .summarizes_display = summarizes_display };
}

fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = if (content[content.len - 1] == '\n') 0 else 1;
    for (content) |byte| if (byte == '\n') {
        count += 1;
    };
    return count;
}

fn resultCopy(
    allocator: std.mem.Allocator,
    output: []const u8,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try allocator.dupe(u8, output) };
}

fn resultFormat(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try std.fmt.allocPrint(allocator, format, args) };
}

const parameters = [_]ToolContract.Parameter{
    .{
        .name = "path",
        .type = .string,
        .required = true,
        .description = "Path to the file.",
    },
    .{
        .name = "content",
        .type = .string,
        .required = true,
        .description = "Full new contents of the file.",
    },
};

pub const definition: ToolContract.Definition = .{
    .name = "write",
    .description = "Write a file, replacing it entirely (creating it if needed). " ++
        "Parent directories are created automatically.",
    .parameters = &parameters,
};

fn testPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

fn runWrite(
    allocator: std.mem.Allocator,
    write: *Write,
    args: ?[]const u8,
    context: ToolContract.RunContext,
) !ToolContract.Result {
    return write.tool().run(allocator, std.testing.io, args, context);
}

test "write validates arguments as ordinary results" {
    var write: Write = .{};
    const cases = [_]struct { args: ?[]const u8, expected: []const u8 }{
        .{ .args = "{", .expected = "invalid arguments: UnexpectedEndOfInput" },
        .{ .args = null, .expected = "missing 'path' argument" },
        .{ .args = "[]", .expected = "missing 'path' argument" },
        .{ .args = "{\"path\":3,\"content\":\"x\"}", .expected = "missing 'path' argument" },
        .{ .args = "{\"path\":\"\",\"content\":\"x\"}", .expected = "missing 'path' argument" },
        .{ .args = "{\"path\":\"x\"}", .expected = "missing 'content' argument" },
        .{ .args = "{\"path\":\"x\",\"content\":false}", .expected = "missing 'content' argument" },
    };
    for (cases) |case| {
        var result = try runWrite(std.testing.allocator, &write, case.args, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.output);
    }
}

test "write creates parents, emits preview, and returns exact summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "sub/file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"alpha\\nbeta\\n\"}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    const Sink = struct {
        const Self = @This();
        bytes: [11]u8 = undefined,
        pub fn emit(self: *Self, bytes: []const u8) error{OutOfMemory}!void {
            @memcpy(&self.bytes, bytes);
        }
    };
    var sink: Sink = .{};
    var write: Write = .{};
    var result = try runWrite(
        std.testing.allocator,
        &write,
        args,
        .{ .display = ToolContract.DisplaySink.from(&sink) },
    );
    defer result.deinit(std.testing.allocator);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "created {s} (2 lines, 11 bytes)",
        .{path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.output);
    try std.testing.expect(result.summarizes_display);
    try std.testing.expectEqualStrings("alpha\nbeta\n", &sink.bytes);
    const file = try tmp.dir.readFileAlloc(std.testing.io, "sub/file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file);
    try std.testing.expectEqualStrings("alpha\nbeta\n", file);
}

test "write returns diff for replacement and empty output when unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "file");
    defer std.testing.allocator.free(path);
    var write: Write = .{};
    const first = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"old\\n\"}}",
        .{path},
    );
    defer std.testing.allocator.free(first);
    var created = try runWrite(std.testing.allocator, &write, first, .{});
    created.deinit(std.testing.allocator);
    const second = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"new\\n\"}}",
        .{path},
    );
    defer std.testing.allocator.free(second);
    var changed = try runWrite(std.testing.allocator, &write, second, .{});
    defer changed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, changed.output, "-old\n+new\n") != null);
    try std.testing.expect(!changed.summarizes_display);
    var unchanged = try runWrite(std.testing.allocator, &write, second, .{});
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unchanged.output.len);
}

test "write accepts empty content and counts singular values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const empty_path = try testPath(std.testing.allocator, &tmp, "empty");
    defer std.testing.allocator.free(empty_path);
    var write: Write = .{};
    const empty_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"\"}}",
        .{empty_path},
    );
    defer std.testing.allocator.free(empty_args);
    var empty = try runWrite(std.testing.allocator, &write, empty_args, .{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, empty.output, "(empty)"));

    const one_path = try testPath(std.testing.allocator, &tmp, "one");
    defer std.testing.allocator.free(one_path);
    const one_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"x\"}}",
        .{one_path},
    );
    defer std.testing.allocator.free(one_args);
    var one = try runWrite(std.testing.allocator, &write, one_args, .{});
    defer one.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, one.output, "(1 line, 1 byte)"));
}

test "write exposes hax definition display and shared preprocess policy" {
    var write: Write = .{};
    const tool = write.tool();
    try std.testing.expectEqualStrings("write", tool.definition.name);
    try std.testing.expectEqualStrings("path", tool.display.arg_name.?);
    try std.testing.expectEqual(ToolContract.OutputStyle.unified_diff, tool.display.output_style);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}/file\",\"content\":\"x\"}}",
        .{cwd_buffer[0..cwd_length]},
    );
    defer std.testing.allocator.free(args);
    const rewritten = (try tool.preprocess(std.testing.allocator, std.testing.io, args)).?;
    defer std.testing.allocator.free(rewritten);
    try std.testing.expectEqualStrings("{\"path\":\"file\",\"content\":\"x\"}", rewritten);
}

fn exerciseWriteCreationAllocations(
    allocator: std.mem.Allocator,
    write: *Write,
    path: []const u8,
    args: []const u8,
) !void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var result = try runWrite(allocator, write, args, .{});
    result.deinit(allocator);
}

test "write creation releases every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "oom");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var write: Write = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseWriteCreationAllocations,
        .{ &write, path, args },
    );
}

test "write expands injected home and writes embedded NUL content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testPath(std.testing.allocator, &tmp, "");
    defer std.testing.allocator.free(home);
    var write: Write = .{ .config = .{ .home = home } };
    var result = try runWrite(
        std.testing.allocator,
        &write,
        "{\"path\":\"~/nul\",\"content\":\"a\\u0000b\"}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.output, "3 bytes") != null);
    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "nul",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 'b' }, bytes);
}

test "display OOM after creation leaves committed file and returns OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "display-oom");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"content\":\"committed\"}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: []const u8) error{OutOfMemory}!void {
            return error.OutOfMemory;
        }
    };
    var sink: Sink = .{};
    var write: Write = .{};
    try std.testing.expectError(
        error.OutOfMemory,
        runWrite(
            std.testing.allocator,
            &write,
            args,
            .{ .display = ToolContract.DisplaySink.from(&sink) },
        ),
    );
    const content = try tmp.dir.readFileAlloc(
        std.testing.io,
        "display-oom",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("committed", content);
}

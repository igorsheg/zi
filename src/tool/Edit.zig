const std = @import("std");
const ToolContract = @import("Tool.zig");
const AtomicWrite = @import("AtomicWrite.zig");
const Path = @import("Path.zig");
const OutputCap = @import("OutputCap.zig");

const maximum_file_bytes: usize = 4 * 1024 * 1024;
const maximum_json_bytes: usize = 32 * 1024 * 1024;
const read_buffer_bytes: usize = 8192;

pub const Config = struct {
    home: ?[]const u8 = null,
};

pub const Edit = struct {
    config: Config = .{},

    pub fn tool(self: *Edit) ToolContract.Tool {
        return ToolContract.Tool.from(self, definition, .{
            .arg_name = "path",
            .output_style = .unified_diff,
        });
    }

    pub fn run(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Edit,
        args_json: ?[]const u8,
        run_context: ToolContract.RunContext,
    ) ToolContract.RunError!ToolContract.Result {
        _ = run_context;
        const input = args_json orelse "{}";
        if (input.len > maximum_json_bytes)
            return resultCopy(allocator, "invalid arguments: input exceeds 33554432 bytes");
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return resultFormat(allocator, "invalid arguments: {s}", .{@errorName(err)}),
        };
        defer parsed.deinit();

        const args = parseArgs(parsed.value) catch |err|
            return resultCopy(allocator, argumentErrorText(err));
        if (args.old_string.len == 0)
            return resultCopy(allocator, "'old_string' must be non-empty");
        if (std.mem.eql(u8, args.old_string, args.new_string))
            return resultCopy(allocator, "'old_string' and 'new_string' are identical: nothing to do");

        const path = try Path.expandHome(allocator, args.path, self.config.home);
        defer allocator.free(path);
        const original = readOriginal(allocator, io, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotRegular => return resultFormat(
                allocator,
                "{s} exists but is not a regular file",
                .{path},
            ),
            error.StreamTooLong => return resultFormat(
                allocator,
                "file {s} is larger than {d} bytes: refusing to edit",
                .{ path, maximum_file_bytes },
            ),
            else => return readErrorResult(allocator, path, err),
        };
        defer allocator.free(original);

        const match_count = countOccurrences(original, args.old_string);
        if (match_count == 0)
            return resultCopy(allocator, "'old_string' not found in file");
        if (match_count > 1 and !args.replace_all) {
            return resultFormat(
                allocator,
                "'old_string' matches {d} places in {s}: provide more context " ++
                    "to disambiguate, or set replace_all=true",
                .{ match_count, path },
            );
        }

        const replacement_count: usize = if (args.replace_all) match_count else 1;
        const updated_length = replacementLength(
            original.len,
            args.old_string.len,
            args.new_string.len,
            replacement_count,
        ) orelse return resultCopy(allocator, "replacement size overflows address space");
        if (updated_length > maximum_file_bytes) {
            return resultFormat(
                allocator,
                "content is {d} bytes; write cap is {d}",
                .{ updated_length, maximum_file_bytes },
            );
        }
        const updated = try replaceOccurrences(
            allocator,
            original,
            args.old_string,
            args.new_string,
            replacement_count,
            updated_length,
        );
        defer allocator.free(updated);

        const atomic = try AtomicWrite.writeWithDiff(allocator, io, path, updated, .{
            .maximum_file_bytes = maximum_file_bytes,
            .maximum_diff_bytes = OutputCap.maximum_capture_bytes,
            .expected_content = original,
        });
        return switch (atomic) {
            .diagnostic => |diagnostic| .{ .output = diagnostic },
            .written => |written| .{ .output = written.diff },
        };
    }

    pub fn preprocess(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Edit,
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

const Args = struct {
    path: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
};

const ArgumentError = error{ MissingPath, MissingOldString, MissingNewString };

fn parseArgs(value: std.json.Value) ArgumentError!Args {
    if (value != .object) return error.MissingPath;
    const path = value.object.get("path") orelse return error.MissingPath;
    if (path != .string or path.string.len == 0) return error.MissingPath;
    const old_string = value.object.get("old_string") orelse return error.MissingOldString;
    if (old_string != .string) return error.MissingOldString;
    const new_string = value.object.get("new_string") orelse return error.MissingNewString;
    if (new_string != .string) return error.MissingNewString;
    const replace_all = if (value.object.get("replace_all")) |replace| replace == .bool and replace.bool else false;
    return .{
        .path = path.string,
        .old_string = old_string.string,
        .new_string = new_string.string,
        .replace_all = replace_all,
    };
}

fn argumentErrorText(err: ArgumentError) []const u8 {
    return switch (err) {
        error.MissingPath => "missing 'path' argument",
        error.MissingOldString => "missing 'old_string' argument",
        error.MissingNewString => "missing 'new_string' argument",
    };
}

const ReadError = error{ OutOfMemory, NotRegular, StreamTooLong } ||
    std.Io.Dir.StatFileError || std.Io.File.OpenError || std.Io.File.StatError ||
    std.Io.File.Reader.Error;

fn readOriginal(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ReadError![]u8 {
    // Avoid knowingly opening FIFOs and devices. The handle stat below is the
    // authoritative check after open; Zig cannot make this preflight race-free.
    const path_stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (path_stat.kind != .file) return error.NotRegular;
    if (path_stat.size > maximum_file_bytes) return error.StreamTooLong;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegular;
    if (stat.size > maximum_file_bytes) return error.StreamTooLong;
    var buffer: [read_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const content = reader.interface.allocRemaining(
        allocator,
        .limited(maximum_file_bytes + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
        error.ReadFailed => return reader.err orelse error.InputOutput,
    };
    if (content.len > maximum_file_bytes) {
        allocator.free(content);
        return error.StreamTooLong;
    }
    return content;
}

fn countOccurrences(content: []const u8, search: []const u8) usize {
    if (search.len == 0 or search.len > content.len) return 0;
    var count: usize = 0;
    var offset: usize = 0;
    while (offset <= content.len - search.len) {
        if (std.mem.eql(u8, content[offset .. offset + search.len], search)) {
            count += 1;
            offset += search.len;
        } else {
            offset += 1;
        }
    }
    return count;
}

fn replacementLength(
    content_length: usize,
    search_length: usize,
    replacement_length: usize,
    count: usize,
) ?usize {
    const removed = std.math.mul(usize, search_length, count) catch return null;
    const inserted = std.math.mul(usize, replacement_length, count) catch return null;
    return std.math.add(usize, content_length - removed, inserted) catch null;
}

fn replaceOccurrences(
    allocator: std.mem.Allocator,
    content: []const u8,
    search: []const u8,
    replacement: []const u8,
    maximum_replacements: usize,
    result_length: usize,
) error{OutOfMemory}![]u8 {
    const result = try allocator.alloc(u8, result_length);
    errdefer allocator.free(result);
    var source: usize = 0;
    var destination: usize = 0;
    var replaced: usize = 0;
    while (replaced < maximum_replacements and source <= content.len - search.len) {
        const relative = std.mem.find(u8, content[source..], search) orelse break;
        const match = source + relative;
        const unchanged = content[source..match];
        @memcpy(result[destination .. destination + unchanged.len], unchanged);
        destination += unchanged.len;
        @memcpy(result[destination .. destination + replacement.len], replacement);
        destination += replacement.len;
        source = match + search.len;
        replaced += 1;
    }
    @memcpy(result[destination..], content[source..]);
    return result;
}

fn resultCopy(allocator: std.mem.Allocator, output: []const u8) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try allocator.dupe(u8, output) };
}

fn resultFormat(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try std.fmt.allocPrint(allocator, format, args) };
}

fn readErrorResult(
    allocator: std.mem.Allocator,
    path: []const u8,
    err: anyerror,
) error{OutOfMemory}!ToolContract.Result {
    return resultFormat(allocator, "error reading {s}: {s}", .{ path, errorReason(err) });
}

fn errorReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.InputOutput => "Input/output error",
        error.IsDir => "Is a directory",
        else => @errorName(err),
    };
}

const parameters = [_]ToolContract.Parameter{
    .{ .name = "path", .type = .string, .required = true, .description = "Path to the file." },
    .{
        .name = "old_string",
        .type = .string,
        .required = true,
        .description = "Exact text to find. Must be unique unless replace_all is set.",
    },
    .{ .name = "new_string", .type = .string, .required = true, .description = "Replacement text." },
    .{
        .name = "replace_all",
        .type = .boolean,
        .description = "Replace every occurrence instead of requiring uniqueness.",
    },
};

pub const definition: ToolContract.Definition = .{
    .name = "edit",
    .description = "Replace an exact string in a file. The `old_string` must match a byte " ++
        "sequence in the file exactly once unless `replace_all` is true. The `read` tool " ++
        "prefixes each line with a line number and a → arrow for display; that prefix is " ++
        "NOT part of the file on disk, so do not include it in `old_string` or `new_string`. " ++
        "Returns a unified diff of the change.",
    .parameters = &parameters,
};

fn testPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

fn writeTestFile(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    const file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

fn runEdit(allocator: std.mem.Allocator, edit_tool: *Edit, args: ?[]const u8) !ToolContract.Result {
    return edit_tool.tool().run(allocator, std.testing.io, args, .{});
}

test "edit validates exact arguments as ordinary results" {
    var edit_tool: Edit = .{};
    const cases = [_]struct { args: ?[]const u8, expected: []const u8 }{
        .{ .args = "{", .expected = "invalid arguments: UnexpectedEndOfInput" },
        .{ .args = null, .expected = "missing 'path' argument" },
        .{ .args = "[]", .expected = "missing 'path' argument" },
        .{ .args = "{\"path\":3}", .expected = "missing 'path' argument" },
        .{ .args = "{\"path\":\"x\"}", .expected = "missing 'old_string' argument" },
        .{ .args = "{\"path\":\"x\",\"old_string\":3}", .expected = "missing 'old_string' argument" },
        .{ .args = "{\"path\":\"x\",\"old_string\":\"a\"}", .expected = "missing 'new_string' argument" },
        .{
            .args = "{\"path\":\"x\",\"old_string\":\"\",\"new_string\":\"b\"}",
            .expected = "'old_string' must be non-empty",
        },
        .{
            .args = "{\"path\":\"x\",\"old_string\":\"a\",\"new_string\":\"a\"}",
            .expected = "'old_string' and 'new_string' are identical: nothing to do",
        },
    };
    for (cases) |case| {
        var result = try runEdit(std.testing.allocator, &edit_tool, case.args);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.output);
    }
}

test "edit replaces unique multiline bytes and returns a unified diff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "file", "alpha\n\treturn 0;\ngamma\n");
    const path = try testPath(std.testing.allocator, &tmp, "file");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"\\treturn 0;\\n\",\"new_string\":\"\\treturn 42;\\n\"}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var edit_tool: Edit = .{};
    var result = try runEdit(std.testing.allocator, &edit_tool, args);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.output, "-\treturn 0;\n+\treturn 42;\n") != null);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "file", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("alpha\n\treturn 42;\ngamma\n", content);
}

test "edit requires uniqueness and replace_all uses non-overlapping matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "file", "aaaa");
    const path = try testPath(std.testing.allocator, &tmp, "file");
    defer std.testing.allocator.free(path);
    var edit_tool: Edit = .{};
    const ambiguous_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"aa\",\"new_string\":\"b\"}}",
        .{path},
    );
    defer std.testing.allocator.free(ambiguous_args);
    var ambiguous = try runEdit(std.testing.allocator, &edit_tool, ambiguous_args);
    defer ambiguous.deinit(std.testing.allocator);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "'old_string' matches 2 places in {s}: provide more context to disambiguate, or set replace_all=true",
        .{path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, ambiguous.output);

    const all_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"aa\",\"new_string\":\"b\",\"replace_all\":true}}",
        .{path},
    );
    defer std.testing.allocator.free(all_args);
    var all = try runEdit(std.testing.allocator, &edit_tool, all_args);
    defer all.deinit(std.testing.allocator);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "file", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("bb", content);
}

test "edit reports no match, deletes all content, and treats non-true replace_all as false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "file", "delete me");
    const path = try testPath(std.testing.allocator, &tmp, "file");
    defer std.testing.allocator.free(path);
    var edit_tool: Edit = .{};
    const no_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"x\",\"new_string\":\"y\"}}",
        .{path},
    );
    defer std.testing.allocator.free(no_args);
    var no_match = try runEdit(std.testing.allocator, &edit_tool, no_args);
    defer no_match.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("'old_string' not found in file", no_match.output);
    const delete_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"delete me\",\"new_string\":\"\",\"replace_all\":1}}",
        .{path},
    );
    defer std.testing.allocator.free(delete_args);
    var deleted = try runEdit(std.testing.allocator, &edit_tool, delete_args);
    defer deleted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, deleted.output, "-delete me") != null);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "file", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqual(@as(usize, 0), content.len);
}

test "edit refuses non-regular missing and oversized files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    const directory = try testPath(std.testing.allocator, &tmp, "directory");
    defer std.testing.allocator.free(directory);
    var edit_tool: Edit = .{};
    const directory_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"a\",\"new_string\":\"b\"}}",
        .{directory},
    );
    defer std.testing.allocator.free(directory_args);
    var non_regular = try runEdit(std.testing.allocator, &edit_tool, directory_args);
    defer non_regular.deinit(std.testing.allocator);
    const expected_non_regular = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s} exists but is not a regular file",
        .{directory},
    );
    defer std.testing.allocator.free(expected_non_regular);
    try std.testing.expectEqualStrings(expected_non_regular, non_regular.output);

    const missing = try testPath(std.testing.allocator, &tmp, "missing");
    defer std.testing.allocator.free(missing);
    const missing_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"a\",\"new_string\":\"b\"}}",
        .{missing},
    );
    defer std.testing.allocator.free(missing_args);
    var not_found = try runEdit(std.testing.allocator, &edit_tool, missing_args);
    defer not_found.deinit(std.testing.allocator);
    const expected_missing = try std.fmt.allocPrint(
        std.testing.allocator,
        "error reading {s}: No such file or directory",
        .{missing},
    );
    defer std.testing.allocator.free(expected_missing);
    try std.testing.expectEqualStrings(expected_missing, not_found.output);

    const large = try testPath(std.testing.allocator, &tmp, "large");
    defer std.testing.allocator.free(large);
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, large, .{});
    try file.setLength(std.testing.io, maximum_file_bytes + 1);
    file.close(std.testing.io);
    const large_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"a\",\"new_string\":\"b\"}}",
        .{large},
    );
    defer std.testing.allocator.free(large_args);
    var oversized = try runEdit(std.testing.allocator, &edit_tool, large_args);
    defer oversized.deinit(std.testing.allocator);
    const expected_large = try std.fmt.allocPrint(
        std.testing.allocator,
        "file {s} is larger than 4194304 bytes: refusing to edit",
        .{large},
    );
    defer std.testing.allocator.free(expected_large);
    try std.testing.expectEqualStrings(expected_large, oversized.output);
}

test "edit supports embedded NUL bytes and bounded replacement output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "file", &.{ 'a', 0, 'a' });
    const path = try testPath(std.testing.allocator, &tmp, "file");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"a\\u0000a\",\"new_string\":\"b\\u0000b\"}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var edit_tool: Edit = .{};
    var result = try runEdit(std.testing.allocator, &edit_tool, args);
    defer result.deinit(std.testing.allocator);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "file", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualSlices(u8, &.{ 'b', 0, 'b' }, content);
}

test "edit definition display home expansion and preprocess match hax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "home", "old");
    const home = try testPath(std.testing.allocator, &tmp, "");
    defer std.testing.allocator.free(home);
    var edit_tool: Edit = .{ .config = .{ .home = home } };
    const tool = edit_tool.tool();
    try std.testing.expectEqualStrings("edit", tool.definition.name);
    try std.testing.expectEqualStrings("path", tool.display.arg_name.?);
    try std.testing.expectEqual(ToolContract.OutputStyle.unified_diff, tool.display.output_style);
    var result = try runEdit(
        std.testing.allocator,
        &edit_tool,
        "{\"path\":\"~/home\",\"old_string\":\"old\",\"new_string\":\"new\"}",
    );
    defer result.deinit(std.testing.allocator);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "home", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("new", content);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const preprocess_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}/file\",\"old_string\":\"a\",\"new_string\":\"b\"}}",
        .{cwd_buffer[0..cwd_length]},
    );
    defer std.testing.allocator.free(preprocess_args);
    const rewritten = (try tool.preprocess(std.testing.allocator, std.testing.io, preprocess_args)).?;
    defer std.testing.allocator.free(rewritten);
    try std.testing.expectEqualStrings("{\"path\":\"file\",\"old_string\":\"a\",\"new_string\":\"b\"}", rewritten);
}

fn exerciseEditAllocations(
    allocator: std.mem.Allocator,
    edit_tool: *Edit,
    path: []const u8,
    args: []const u8,
) !void {
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "foo foo\n");
    var result = try runEdit(allocator, edit_tool, args);
    result.deinit(allocator);
}

test "edit releases every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, &tmp, "oom");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"old_string\":\"foo\",\"new_string\":\"bar\",\"replace_all\":true}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var edit_tool: Edit = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEditAllocations,
        .{ &edit_tool, path, args },
    );
}

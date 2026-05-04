const std = @import("std");
const env = @import("env");
const system_command = @import("../../coding_agent/extensions/system_command.zig");
const run_setup = @import("run_setup.zig");

pub const Options = struct {
    cwd: ?[]const u8 = null,
    suffix: []const u8 = ".md",
    trim_final_newline: bool = true,
};

pub const Result = union(enum) {
    submitted: []const u8,
    cancelled,
    err: []const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .submitted => |text| allocator.free(text),
            .err => |msg| allocator.free(msg),
            .cancelled => {},
        }
        self.* = undefined;
    }
};

pub fn editText(self: anytype, initial_text: []const u8, opts: Options) Result {
    const allocator = self.msg_allocator;
    const editor_cmd = env.get("VISUAL") orelse env.get("EDITOR") orelse return errResult(allocator, "No editor configured. Set $VISUAL or $EDITOR.");
    if (editor_cmd.len == 0) return errResult(allocator, "No editor configured. Set $VISUAL or $EDITOR.");

    const tmp_path = makeTempPath(allocator, self.io, opts.suffix) catch return errResult(allocator, "failed to create temporary editor path");
    defer allocator.free(tmp_path);
    defer std.Io.Dir.deleteFile(.cwd(), self.io, tmp_path) catch {};

    std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = tmp_path, .data = initial_text }) catch return errResult(allocator, "failed to write temporary editor file");

    const argv = buildEditorArgv(allocator, editor_cmd, tmp_path) catch return errResult(allocator, "failed to build editor command");
    defer freeArgv(allocator, argv);
    if (argv.len == 0) return errResult(allocator, "No editor configured. Set $VISUAL or $EDITOR.");

    run_setup.suspendTerminalForExternalProcess(self);
    defer run_setup.resumeTerminalAfterExternalProcess(self) catch {};

    var command_result = system_command.run(allocator, self.io, .{
        .argv = argv,
        .cwd = opts.cwd,
        .stdio = .terminal,
    });
    defer command_result.deinit(allocator);

    const completed = switch (command_result) {
        .completed => |completed| completed,
        .timeout => return errResult(allocator, "editor timed out"),
        .err => |failed| return errResult(allocator, failed.message),
    };
    if (completed.code == null or completed.code.? != 0) return .cancelled;

    const raw = std.Io.Dir.readFileAlloc(.cwd(), self.io, tmp_path, allocator, .limited(16 * 1024 * 1024)) catch return errResult(allocator, "failed to read temporary editor file");
    if (!opts.trim_final_newline or raw.len == 0 or raw[raw.len - 1] != '\n') return .{ .submitted = raw };
    const trimmed = allocator.dupe(u8, raw[0 .. raw.len - 1]) catch {
        allocator.free(raw);
        return errResult(allocator, "failed to allocate edited text");
    };
    allocator.free(raw);
    return .{ .submitted = trimmed };
}

fn makeTempPath(allocator: std.mem.Allocator, io: std.Io, suffix: []const u8) ![]u8 {
    const tmp_dir = env.get("TMPDIR") orelse "/tmp";
    const ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return std.fmt.allocPrint(allocator, "{s}/zi-editor-{d}{s}", .{ tmp_dir, ns, suffix });
}

fn buildEditorArgv(allocator: std.mem.Allocator, editor_cmd: []const u8, path: []const u8) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).empty;
    errdefer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, editor_cmd, " \t\r\n");
    while (it.next()) |part| try parts.append(allocator, try allocator.dupe(u8, part));
    try parts.append(allocator, try allocator.dupe(u8, path));
    return parts.toOwnedSlice(allocator);
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn errResult(allocator: std.mem.Allocator, msg: []const u8) Result {
    return .{ .err = allocator.dupe(u8, msg) catch &.{} };
}

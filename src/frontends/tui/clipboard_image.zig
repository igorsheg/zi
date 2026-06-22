const std = @import("std");
const builtin = @import("builtin");

const runtime = @import("../../runtime/root.zig");

pub const ClipboardImage = struct {
    bytes: []u8,
    mime_type: []const u8,

    pub fn deinit(self: *ClipboardImage, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ReadError = error{
    NoImage,
    UnsupportedFormat,
    ToolUnavailable,
    ImageTooLarge,
    CommandFailed,
    Timeout,
    OutOfMemory,
};

const supported_mime_types = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
};

const list_timeout_ms: u64 = 1000;
const read_timeout_ms: u64 = 3000;
pub const max_image_bytes: usize = 50 * 1024 * 1024;
const stderr_bytes_max: usize = 4 * 1024;

fn baseMimeType(mime_type: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, mime_type, ';') orelse mime_type.len;
    return std.mem.trim(u8, mime_type[0..semi], " \t\r\n");
}

pub fn extensionForMimeType(mime_type: []const u8) ?[]const u8 {
    const base = baseMimeType(mime_type);
    if (std.ascii.eqlIgnoreCase(base, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(base, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(base, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(base, "image/gif")) return "gif";
    return null;
}

fn selectPreferredImageMimeType(types: []const u8) ?[]const u8 {
    for (supported_mime_types) |preferred| {
        var lines = std.mem.splitScalar(u8, types, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(baseMimeType(trimmed), preferred)) return trimmed;
        }
    }
    return null;
}

fn mapRunError(err: anyerror) ReadError {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.ToolUnavailable,
        error.AccessDenied => error.ToolUnavailable,
        error.StreamTooLong => error.ImageTooLarge,
        else => error.CommandFailed,
    };
}

fn exitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    argv: []const []const u8,
    timeout_ms: u64,
    max_stdout_bytes: usize,
    environ: ?*const std.process.Environ.Map,
) ReadError!std.process.RunResult {
    return runtime.runProcess(allocator, io, task_runtime, .{
        .argv = argv,
        .environ = environ,
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = max_stdout_bytes,
        .max_stderr_bytes = stderr_bytes_max,
    }) catch |err| return mapRunError(err);
}

pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
) ReadError!ClipboardImage {
    if (builtin.os.tag == .macos) return readViaMacOs(allocator, io, task_runtime, environ);

    const wayland = if (environ) |env|
        env.get("WAYLAND_DISPLAY") != null or std.mem.eql(u8, env.get("XDG_SESSION_TYPE") orelse "", "wayland")
    else
        false;

    if (wayland) {
        return readViaWlPaste(allocator, io, task_runtime, environ) catch |err| switch (err) {
            error.NoImage, error.ToolUnavailable, error.CommandFailed => readViaXclip(allocator, io, task_runtime, environ),
            else => err,
        };
    }

    return readViaXclip(allocator, io, task_runtime, environ) catch |err| switch (err) {
        error.NoImage, error.ToolUnavailable, error.CommandFailed => readViaWlPaste(allocator, io, task_runtime, environ),
        else => err,
    };
}

fn readViaMacOs(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
) ReadError!ClipboardImage {
    const check_script =
        "try\n" ++
        "set theType to (clipboard info for «class PNGf»)\n" ++
        "return \"image\"\n" ++
        "on error\n" ++
        "return \"none\"\n" ++
        "end try";
    const check = try runCapture(
        allocator,
        io,
        task_runtime,
        &.{ "/usr/bin/osascript", "-e", check_script },
        list_timeout_ms,
        256,
        environ,
    );
    defer allocator.free(check.stdout);
    defer allocator.free(check.stderr);
    if (!exitedSuccessfully(check.term)) return error.CommandFailed;
    if (!std.mem.eql(u8, std.mem.trim(u8, check.stdout, " \t\r\n"), "image")) return error.NoImage;

    const tmp_path = try makeMacOsTempPath(allocator, io);
    defer allocator.free(tmp_path);
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const script = try std.fmt.allocPrint(
        allocator,
        "set imgData to the clipboard as «class PNGf»\n" ++
            "set fp to open for access POSIX file \"{s}\" with write permission\n" ++
            "write imgData to fp\n" ++
            "close access fp",
        .{tmp_path},
    );
    defer allocator.free(script);

    const save = try runCapture(
        allocator,
        io,
        task_runtime,
        &.{ "/usr/bin/osascript", "-e", script },
        read_timeout_ms,
        256,
        environ,
    );
    defer allocator.free(save.stdout);
    defer allocator.free(save.stderr);
    if (!exitedSuccessfully(save.term)) return error.CommandFailed;

    var file = std.Io.Dir.openFileAbsolute(io, tmp_path, .{}) catch return error.CommandFailed;
    defer file.close(io);
    const file_len = file.length(io) catch return error.CommandFailed;
    if (file_len == 0) return error.NoImage;
    if (file_len > max_image_bytes) return error.ImageTooLarge;
    const bytes = allocator.alloc(u8, @intCast(file_len)) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    const len = file.readPositionalAll(io, bytes, 0) catch return error.CommandFailed;
    if (len != bytes.len) return error.CommandFailed;
    return .{ .bytes = bytes, .mime_type = "image/png" };
}

fn makeMacOsTempPath(allocator: std.mem.Allocator, io: std.Io) ReadError![]u8 {
    var buffer: [128]u8 = undefined;
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const path = std.fmt.bufPrint(&buffer, "/tmp/zi-clipboard-read-{d}.png", .{stamp}) catch unreachable;
    return allocator.dupe(u8, path) catch return error.OutOfMemory;
}

fn readViaWlPaste(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
) ReadError!ClipboardImage {
    const list = try runCapture(allocator, io, task_runtime, &.{ "wl-paste", "--list-types" }, list_timeout_ms, 16 * 1024, environ);
    defer allocator.free(list.stdout);
    defer allocator.free(list.stderr);
    if (!exitedSuccessfully(list.term)) return error.ToolUnavailable;
    const selected = selectPreferredImageMimeType(list.stdout) orelse return error.NoImage;
    const base = baseMimeType(selected);
    if (extensionForMimeType(base) == null) return error.UnsupportedFormat;

    const data = try runCapture(
        allocator,
        io,
        task_runtime,
        &.{ "wl-paste", "--type", selected, "--no-newline" },
        read_timeout_ms,
        max_image_bytes,
        environ,
    );
    defer allocator.free(data.stderr);
    if (!exitedSuccessfully(data.term)) {
        allocator.free(data.stdout);
        return error.CommandFailed;
    }
    if (data.stdout.len == 0) {
        allocator.free(data.stdout);
        return error.NoImage;
    }
    return .{ .bytes = data.stdout, .mime_type = base };
}

fn readViaXclip(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
) ReadError!ClipboardImage {
    const targets = runCapture(
        allocator,
        io,
        task_runtime,
        &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
        list_timeout_ms,
        16 * 1024,
        environ,
    ) catch |err| switch (err) {
        error.ToolUnavailable => return err,
        else => return error.NoImage,
    };
    defer allocator.free(targets.stdout);
    defer allocator.free(targets.stderr);
    if (!exitedSuccessfully(targets.term)) return error.NoImage;

    const selected = selectPreferredImageMimeType(targets.stdout) orelse return error.NoImage;
    const base = baseMimeType(selected);
    if (extensionForMimeType(base) == null) return error.UnsupportedFormat;
    const data = try runCapture(
        allocator,
        io,
        task_runtime,
        &.{ "xclip", "-selection", "clipboard", "-t", selected, "-o" },
        read_timeout_ms,
        max_image_bytes,
        environ,
    );
    defer allocator.free(data.stderr);
    if (!exitedSuccessfully(data.term)) {
        allocator.free(data.stdout);
        return error.CommandFailed;
    }
    if (data.stdout.len == 0) {
        allocator.free(data.stdout);
        return error.NoImage;
    }
    return .{ .bytes = data.stdout, .mime_type = base };
}

test "selects preferred supported image type" {
    try std.testing.expectEqualStrings("image/png", selectPreferredImageMimeType("text/plain\nimage/jpeg\nimage/png\n").?);
    try std.testing.expectEqualStrings("image/webp;foo", selectPreferredImageMimeType("image/bmp\nimage/webp;foo\n").?);
    try std.testing.expect(selectPreferredImageMimeType("text/plain\n") == null);
}

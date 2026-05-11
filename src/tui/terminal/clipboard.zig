const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const runtime_process = @import("../../zio/root.zig").process;

const supported_image_mime_types = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
};
const max_clipboard_image_bytes = 50 * 1024 * 1024;
const clipboard_list_timeout_ms = 1000;
const clipboard_read_timeout_ms = 3000;

const macos_clipboard = if (builtin.os.tag == .macos) struct {
    extern fn zi_clipboard_write_text(bytes: [*]const u8, len: usize) bool;
    extern fn zi_clipboard_read_png(out_bytes: *[*]u8, out_len: *usize) bool;
    extern fn zi_clipboard_free(ptr: [*]u8) void;
} else struct {
    fn zi_clipboard_write_text(_: [*]const u8, _: usize) bool {
        return false;
    }

    fn zi_clipboard_read_png(_: *[*]u8, _: *usize) bool {
        return false;
    }

    fn zi_clipboard_free(_: [*]u8) void {}
};

/// Best-effort clipboard write for TUI interactions.
///
/// Always emits OSC 52 first so remote sessions can still copy through the
/// terminal. Local/native helpers are then attempted opportunistically. The
/// return value reports whether a local/native helper confirmed success; OSC 52
/// delivery cannot be acknowledged by the terminal.
pub fn copyText(text: []const u8) bool {
    if (text.len == 0) return false;
    emitOsc52(text);

    return switch (builtin.os.tag) {
        .macos => macos_clipboard.zi_clipboard_write_text(text.ptr, text.len) or
            copyViaCommand(&.{"/usr/bin/pbcopy"}, text),
        else => true,
    };
}

/// Best-effort clipboard image read for interactive paste.
///
/// Returns an owned raw byte slice when an image is available, otherwise null.
/// Failures are intentionally collapsed to null so callsites can present a
/// simple "no image available" UX without exposing platform helper details.
pub fn readImage(allocator: std.mem.Allocator) ?[]u8 {
    return switch (builtin.os.tag) {
        .macos => readImageMacos(allocator),
        .linux => readImageLinux(allocator),
        .windows => readImageWindows(allocator),
        else => null,
    };
}

fn emitOsc52(text: []const u8) void {
    const Encoder = std.base64.standard.Encoder;
    const encoded_len = Encoder.calcSize(text.len);
    const allocator = std.heap.page_allocator;
    const encoded = allocator.alloc(u8, encoded_len) catch return;
    defer allocator.free(encoded);
    _ = Encoder.encode(encoded, text);

    const prefix = "\x1b]52;c;";
    const suffix = "\x07";
    const total_len = prefix.len + encoded.len + suffix.len;
    const seq = allocator.alloc(u8, total_len) catch return;
    defer allocator.free(seq);

    @memcpy(seq[0..prefix.len], prefix);
    @memcpy(seq[prefix.len .. prefix.len + encoded.len], encoded);
    @memcpy(seq[prefix.len + encoded.len ..], suffix);

    const stdout: std.Io.File = .{ .handle = posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var out_buf: [512]u8 = undefined;
    var writer = stdout.writer(std.Options.debug_io, &out_buf);
    writer.interface.writeAll(seq) catch return;
    writer.interface.flush() catch {};
}

fn readImageMacos(allocator: std.mem.Allocator) ?[]u8 {
    var native_bytes: [*]u8 = undefined;
    var native_len: usize = 0;
    if (!macos_clipboard.zi_clipboard_read_png(&native_bytes, &native_len)) return null;
    defer macos_clipboard.zi_clipboard_free(native_bytes);

    if (native_len == 0 or native_len > max_clipboard_image_bytes) return null;
    return allocator.dupe(u8, native_bytes[0..native_len]) catch null;
}

fn readImageLinux(allocator: std.mem.Allocator) ?[]u8 {
    if (isWaylandSession()) {
        return readImageViaWlPaste(allocator) orelse readImageViaXclip(allocator) orelse readImageWslWindowsClipboard(allocator);
    }
    return readImageViaXclip(allocator) orelse readImageViaWlPaste(allocator) orelse readImageWslWindowsClipboard(allocator);
}

fn readImageWindows(allocator: std.mem.Allocator) ?[]u8 {
    return readImageViaPowerShell(allocator, "powershell.exe");
}

fn readImageWslWindowsClipboard(allocator: std.mem.Allocator) ?[]u8 {
    if (!isWsl()) return null;
    return readImageViaPowerShell(allocator, "powershell.exe");
}

fn isWaylandSession() bool {
    if (@import("env").get("WAYLAND_DISPLAY") != null) return true;
    const session_type = @import("env").get("XDG_SESSION_TYPE") orelse return false;
    return std.mem.eql(u8, session_type, "wayland");
}

fn isWsl() bool {
    if (@import("env").get("WSL_DISTRO_NAME") != null) return true;
    if (@import("env").get("WSLENV") != null) return true;

    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, "/proc/version", .{}) catch return false;
    defer file.close(io);
    var buf: [512]u8 = undefined;
    const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return false,
    };
    return std.ascii.indexOfIgnoreCase(buf[0..n], "microsoft") != null or
        std.ascii.indexOfIgnoreCase(buf[0..n], "wsl") != null;
}

fn readImageViaWlPaste(allocator: std.mem.Allocator) ?[]u8 {
    const preferred = if (runCommandCaptureTimeout(
        allocator,
        &.{ "wl-paste", "--list-types" },
        clipboard_list_timeout_ms,
    )) |types| blk: {
        defer allocator.free(types);
        break :blk selectPreferredImageMimeType(types);
    } else null;

    if (preferred) |mime_type| {
        if (readImageViaCommand(allocator, &.{ "wl-paste", "--type", mime_type, "--no-newline" })) |bytes| {
            return bytes;
        }
    }

    for (supported_image_mime_types) |mime_type| {
        if (readImageViaCommand(allocator, &.{ "wl-paste", "--type", mime_type, "--no-newline" })) |bytes| {
            return bytes;
        }
    }
    return null;
}

fn readImageViaXclip(allocator: std.mem.Allocator) ?[]u8 {
    const preferred = if (runCommandCaptureTimeout(
        allocator,
        &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
        clipboard_list_timeout_ms,
    )) |targets| blk: {
        defer allocator.free(targets);
        break :blk selectPreferredImageMimeType(targets);
    } else null;

    if (preferred) |mime_type| {
        if (readImageViaCommand(allocator, &.{ "xclip", "-selection", "clipboard", "-t", mime_type, "-o" })) |bytes| {
            return bytes;
        }
    }

    for (supported_image_mime_types) |mime_type| {
        if (readImageViaCommand(allocator, &.{ "xclip", "-selection", "clipboard", "-t", mime_type, "-o" })) |bytes| {
            return bytes;
        }
    }
    return null;
}

fn readImageViaPowerShell(allocator: std.mem.Allocator, exe: []const u8) ?[]u8 {
    const script =
        \\Add-Type -AssemblyName System.Windows.Forms;
        \\Add-Type -AssemblyName System.Drawing;
        \\$img = [System.Windows.Forms.Clipboard]::GetImage();
        \\if ($img) {
        \\  $ms = New-Object System.IO.MemoryStream;
        \\  $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png);
        \\  [Convert]::ToBase64String($ms.ToArray());
        \\}
    ;
    const encoded = runCommandCaptureTimeout(allocator, &.{ exe, "-NoProfile", "-Command", script }, 5000) orelse return null;
    defer allocator.free(encoded);
    return decodeBase64Owned(allocator, encoded);
}

fn readImageViaCommand(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    return runCommandCaptureTimeout(allocator, argv, clipboard_read_timeout_ms);
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    return runCommandCaptureTimeout(allocator, argv, null);
}

fn runCommandCaptureTimeout(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: ?u64) ?[]u8 {
    var result = runtime_process.run(allocator, std.Options.debug_io, .{
        .argv = argv,
        .timeout_ms = timeout_ms,
        .stdout_limit = .limited(max_clipboard_image_bytes),
        .stderr = .ignore,
    }) catch return null;
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        .timed_out, .stdout_too_long, .stderr_too_long, .aborted => return null,
    };
    switch (completed.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    if (completed.stdout.len == 0) return null;
    return allocator.dupe(u8, completed.stdout) catch null;
}

fn selectPreferredImageMimeType(types_text: []const u8) ?[]const u8 {
    for (supported_image_mime_types) |preferred| {
        var lines = std.mem.splitScalar(u8, types_text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, baseMimeType(trimmed), preferred)) return preferred;
        }
    }
    return null;
}

fn baseMimeType(mime_type: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, mime_type, " \t\r\n");
    const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse return trimmed;
    return std.mem.trim(u8, trimmed[0..semi], " \t\r\n");
}

fn decodeBase64Owned(allocator: std.mem.Allocator, encoded: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, encoded, " \t\r\n");
    if (trimmed.len == 0) return null;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(trimmed) catch return null;
    if (decoded_len == 0 or decoded_len > max_clipboard_image_bytes) return null;

    const decoded = allocator.alloc(u8, decoded_len) catch return null;
    std.base64.standard.Decoder.decode(decoded, trimmed) catch {
        allocator.free(decoded);
        return null;
    };
    return decoded;
}

fn copyViaCommand(argv: []const []const u8, text: []const u8) bool {
    var result = runtime_process.run(std.heap.page_allocator, std.Options.debug_io, .{
        .argv = argv,
        .stdin = .{ .bytes = text },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    defer result.deinit(std.heap.page_allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        .timed_out, .stdout_too_long, .stderr_too_long, .aborted => return false,
    };
    return switch (completed.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const testing = std.testing;

test "clipboard image mime selection prefers supported types" {
    try testing.expectEqualStrings("image/png", selectPreferredImageMimeType("text/plain\nimage/bmp\nimage/png; charset=binary\n").?);
    try testing.expectEqualStrings("image/png", selectPreferredImageMimeType("image/jpeg\r\nimage/png\r\n").?);
    try testing.expect(selectPreferredImageMimeType("text/plain\nimage/bmp\n") == null);
}

test "clipboard base64 decoder ignores surrounding whitespace" {
    const decoded = decodeBase64Owned(testing.allocator, " aGVsbG8=\n") orelse return error.ExpectedDecode;
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("hello", decoded);
}

test "clipboard detects wayland sessions from standard environment variables" {
    const actual = isWaylandSession();
    const expected = @import("env").get("WAYLAND_DISPLAY") != null or
        (if (@import("env").get("XDG_SESSION_TYPE")) |value| std.mem.eql(u8, value, "wayland") else false);
    try testing.expectEqual(expected, actual);
}

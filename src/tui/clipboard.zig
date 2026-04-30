const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const supported_image_mime_types = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
};
const max_clipboard_image_bytes = 50 * 1024 * 1024;
const macos_clipboard_image_script =
    \\ObjC.import("AppKit");
    \\ObjC.import("Foundation");
    \\var pb = $.NSPasteboard.generalPasteboard;
    \\var data = pb.dataForType($.NSPasteboardTypePNG);
    \\if (!data) {
    \\  var tiff = pb.dataForType($.NSPasteboardTypeTIFF);
    \\  if (tiff) {
    \\    var rep = $.NSBitmapImageRep.imageRepWithData(tiff);
    \\    if (rep) {
    \\      data = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
    \\    }
    \\  }
    \\}
    \\if (!data) {
    \\  "";
    \\} else {
    \\  ObjC.unwrap(data.base64EncodedStringWithOptions(0));
    \\}
;

/// Best-effort clipboard write for TUI interactions.
///
/// Always emits OSC 52 first so remote sessions can still copy through the
/// terminal. Local helper tools are then attempted opportunistically.
pub fn copyText(text: []const u8) void {
    if (text.len == 0) return;
    emitOsc52(text);

    switch (builtin.os.tag) {
        .macos => _ = copyViaCommand(&.{"/usr/bin/pbcopy"}, text),
        else => {},
    }
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
        else => null,
    };
}

fn emitOsc52(text: []const u8) void {
    // Tiny helper allocations, freed before return.
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
    return readImageViaCommand(allocator, &.{ "pngpaste", "-" }) orelse
        readImageViaCommand(allocator, &.{ "/opt/homebrew/bin/pngpaste", "-" }) orelse
        readImageViaCommand(allocator, &.{ "/usr/local/bin/pngpaste", "-" }) orelse
        readImageViaMacOsascript(allocator);
}

fn readImageLinux(allocator: std.mem.Allocator) ?[]u8 {
    if (isWaylandSession()) {
        return readImageViaWlPaste(allocator) orelse readImageViaXclip(allocator);
    }
    return readImageViaXclip(allocator) orelse readImageViaWlPaste(allocator);
}

fn isWaylandSession() bool {
    if (@import("env").get("WAYLAND_DISPLAY") != null) return true;
    const session_type = @import("env").get("XDG_SESSION_TYPE") orelse return false;
    return std.mem.eql(u8, session_type, "wayland");
}

fn readImageViaWlPaste(allocator: std.mem.Allocator) ?[]u8 {
    for (supported_image_mime_types) |mime_type| {
        if (readImageViaCommand(allocator, &.{ "wl-paste", "--type", mime_type, "--no-newline" })) |bytes| {
            return bytes;
        }
    }
    return null;
}

fn readImageViaXclip(allocator: std.mem.Allocator) ?[]u8 {
    for (supported_image_mime_types) |mime_type| {
        if (readImageViaCommand(allocator, &.{ "xclip", "-selection", "clipboard", "-t", mime_type, "-o" })) |bytes| {
            return bytes;
        }
    }
    return null;
}

fn readImageViaMacOsascript(allocator: std.mem.Allocator) ?[]u8 {
    const encoded = runCommandCapture(allocator, &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", macos_clipboard_image_script }) orelse return null;
    defer allocator.free(encoded);
    return decodeBase64Owned(allocator, encoded);
}

fn readImageViaCommand(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    return runCommandCapture(allocator, argv);
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(std.Options.debug_io, &stdout_buf);
    const stdout = stdout_reader.interface.allocRemaining(allocator, .limited(max_clipboard_image_bytes)) catch return null;
    const term = child.wait(std.Options.debug_io) catch {
        allocator.free(stdout);
        return null;
    };

    if (term != .exited or term.exited != 0 or stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }
    return stdout;
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
    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .expand_arg0 = .expand,
    }) catch return false;

    if (child.stdin) |stdin_file| {
        var write_buf: [4096]u8 = undefined;
        var stdin_writer = stdin_file.writer(std.Options.debug_io, &write_buf);
        stdin_writer.interface.writeAll(text) catch {
            _ = child.wait(std.Options.debug_io) catch {};
            return false;
        };
        stdin_writer.interface.flush() catch {
            _ = child.wait(std.Options.debug_io) catch {};
            return false;
        };
        stdin_file.close(std.Options.debug_io);
        child.stdin = null;
    }

    const term = child.wait(std.Options.debug_io) catch return false;
    return term == .exited and term.exited == 0;
}

const testing = std.testing;

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

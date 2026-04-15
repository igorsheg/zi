const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

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

    _ = posix.write(posix.STDOUT_FILENO, seq) catch {};
}

fn copyViaCommand(argv: []const []const u8, text: []const u8) bool {
    // Short-lived child-process bookkeeping allocator; storage dies with the
    // helper process object before return.
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.expand_arg0 = .expand;

    child.spawn() catch return false;
    child.waitForSpawn() catch {
        _ = child.wait() catch {};
        return false;
    };

    if (child.stdin) |stdin_file| {
        stdin_file.writeAll(text) catch {
            _ = child.wait() catch {};
            return false;
        };
        stdin_file.close();
        child.stdin = null;
    }

    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

const std = @import("std");

const NotifyMode = enum {
    osc777,
    osc99,
    osc9,
};

pub fn notify(title: ?[]const u8, body: []const u8) void {
    if (body.len == 0) return;

    var buf: [2048]u8 = undefined;
    const mode = detectMode();
    const tmux = inTmux();
    const message = formatNotification(&buf, mode, tmux, title, body) catch return;

    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only }) catch return;
    defer tty.close();
    tty.writeAll(message) catch {};
}

fn detectMode() NotifyMode {
    if (std.posix.getenv("KITTY_WINDOW_ID") != null) return .osc99;
    if (std.posix.getenv("GHOSTTY_RESOURCES_DIR") != null) return .osc777;
    if (std.posix.getenv("GHOSTTY_BIN_DIR") != null) return .osc777;

    if (std.posix.getenv("TERM_PROGRAM")) |term_program| {
        if (std.mem.eql(u8, term_program, "ghostty")) return .osc777;
        if (std.mem.eql(u8, term_program, "WezTerm")) return .osc777;
        if (std.mem.eql(u8, term_program, "iTerm.app")) return .osc777;
    }

    if (std.posix.getenv("TERM")) |term| {
        if (std.mem.startsWith(u8, term, "foot")) return .osc777;
        if (std.mem.startsWith(u8, term, "rxvt-unicode")) return .osc777;
    }

    return .osc9;
}

fn inTmux() bool {
    return std.posix.getenv("TMUX") != null;
}

fn formatNotification(
    buf: []u8,
    mode: NotifyMode,
    tmux: bool,
    title: ?[]const u8,
    body: []const u8,
) ![]const u8 {
    const safe_title = title orelse "Zi";
    return switch (mode) {
        .osc777 => if (tmux)
            try std.fmt.bufPrint(buf, "\x1bPtmux;\x1b\x1b]777;notify;{s};{s}\x1b\x1b\\\x1b\\", .{ safe_title, body })
        else
            try std.fmt.bufPrint(buf, "\x1b]777;notify;{s};{s}\x1b\\", .{ safe_title, body }),
        .osc99 => if (tmux)
            try std.fmt.bufPrint(buf, "\x1bPtmux;\x1b\x1b]99;i=1:d=0;{s}\x1b\x1b\\\x1b\x1b]99;i=1:p=body;{s}\x1b\x1b\\\x1b\\", .{ safe_title, body })
        else
            try std.fmt.bufPrint(buf, "\x1b]99;i=1:d=0;{s}\x1b\\\x1b]99;i=1:p=body;{s}\x1b\\", .{ safe_title, body }),
        .osc9 => if (tmux)
            try std.fmt.bufPrint(buf, "\x1bPtmux;\x1b\x1b]9;{s}: {s}\x1b\x1b\\\x1b\\", .{ safe_title, body })
        else
            try std.fmt.bufPrint(buf, "\x1b]9;{s}: {s}\x1b\\", .{ safe_title, body }),
    };
}

test "terminal notification formats OSC 777 with title and body" {
    var buf: [128]u8 = undefined;
    const message = try formatNotification(&buf, .osc777, false, "Zi", "Ready");
    try std.testing.expectEqualStrings("\x1b]777;notify;Zi;Ready\x1b\\", message);
}

test "terminal notification formats OSC 9 fallback" {
    var buf: [128]u8 = undefined;
    const message = try formatNotification(&buf, .osc9, false, "Zi", "Ready");
    try std.testing.expectEqualStrings("\x1b]9;Zi: Ready\x1b\\", message);
}

test "terminal notification formats tmux passthrough" {
    var buf: [160]u8 = undefined;
    const message = try formatNotification(&buf, .osc777, true, "Zi", "Ready");
    try std.testing.expectEqualStrings("\x1bPtmux;\x1b\x1b]777;notify;Zi;Ready\x1b\x1b\\\x1b\\", message);
}

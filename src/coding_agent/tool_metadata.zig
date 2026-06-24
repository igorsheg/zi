const std = @import("std");

pub const Presentation = enum { generic, command, file, patch };
pub const BodyMode = enum { visible, hidden_on_success };
pub const CollapseMode = enum { head, tail };

pub const Collapse = struct {
    mode: CollapseMode = .tail,
    lines_max: u8 = 5,
};

pub const Display = struct {
    presentation: Presentation = .generic,
    body_mode: BodyMode = .visible,
    collapse: Collapse = .{},
    shows_duration: bool = false,
};

pub fn displayForTool(name: []const u8) Display {
    if (std.mem.eql(u8, name, "bash")) return .{
        .presentation = .command,
        .collapse = .{ .mode = .tail, .lines_max = 5 },
        .shows_duration = true,
    };
    if (std.mem.eql(u8, name, "read")) return .{
        .presentation = .file,
        .body_mode = .hidden_on_success,
        .collapse = .{ .mode = .head, .lines_max = 10 },
    };
    if (std.mem.eql(u8, name, "edit")) return .{
        .presentation = .patch,
        .collapse = .{ .mode = .head, .lines_max = 10 },
    };
    if (std.mem.eql(u8, name, "write")) return .{
        .presentation = .file,
        .collapse = .{ .mode = .head, .lines_max = 10 },
    };
    return .{};
}

test "builtin display metadata covers pi-mono-style tool chrome" {
    const bash = displayForTool("bash");
    try std.testing.expectEqual(Presentation.command, bash.presentation);
    try std.testing.expectEqual(CollapseMode.tail, bash.collapse.mode);
    try std.testing.expectEqual(@as(u8, 5), bash.collapse.lines_max);
    try std.testing.expect(bash.shows_duration);

    const read = displayForTool("read");
    try std.testing.expectEqual(Presentation.file, read.presentation);
    try std.testing.expectEqual(BodyMode.hidden_on_success, read.body_mode);
    try std.testing.expectEqual(CollapseMode.head, read.collapse.mode);
    try std.testing.expectEqual(@as(u8, 10), read.collapse.lines_max);

    const edit = displayForTool("edit");
    try std.testing.expectEqual(Presentation.patch, edit.presentation);

    const unknown = displayForTool("custom");
    try std.testing.expectEqual(Presentation.generic, unknown.presentation);
}

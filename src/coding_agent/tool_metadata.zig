const std = @import("std");

pub const Presentation = enum { generic, command, file, patch, search, directory };
pub const BodyMode = enum { visible, hidden_on_success };
pub const CollapseMode = enum { head, tail };

pub const Collapse = struct {
    mode: CollapseMode = .tail,
    rows_max: u8 = 5,
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
        .collapse = .{ .mode = .tail, .rows_max = 5 },
        .shows_duration = true,
    };
    if (std.mem.eql(u8, name, "read")) return .{
        .presentation = .file,
        .body_mode = .hidden_on_success,
        .collapse = .{ .mode = .head, .rows_max = 10 },
    };
    if (std.mem.eql(u8, name, "edit")) return .{
        .presentation = .patch,
        .collapse = .{ .mode = .head, .rows_max = 10 },
    };
    if (std.mem.eql(u8, name, "write")) return .{
        .presentation = .file,
        .collapse = .{ .mode = .head, .rows_max = 10 },
    };
    if (std.mem.eql(u8, name, "grep")) return .{
        .presentation = .search,
        .collapse = .{ .mode = .head, .rows_max = 15 },
    };
    if (std.mem.eql(u8, name, "find")) return .{
        .presentation = .directory,
        .collapse = .{ .mode = .head, .rows_max = 20 },
    };
    if (std.mem.eql(u8, name, "ls")) return .{
        .presentation = .directory,
        .collapse = .{ .mode = .head, .rows_max = 20 },
    };
    return .{};
}

test "builtin display metadata covers pi-mono-style tool chrome" {
    const bash = displayForTool("bash");
    try std.testing.expectEqual(Presentation.command, bash.presentation);
    try std.testing.expectEqual(CollapseMode.tail, bash.collapse.mode);
    try std.testing.expect(bash.shows_duration);

    const read = displayForTool("read");
    try std.testing.expectEqual(Presentation.file, read.presentation);
    try std.testing.expectEqual(BodyMode.hidden_on_success, read.body_mode);
    try std.testing.expectEqual(CollapseMode.head, read.collapse.mode);

    const edit = displayForTool("edit");
    try std.testing.expectEqual(Presentation.patch, edit.presentation);

    const unknown = displayForTool("custom");
    try std.testing.expectEqual(Presentation.generic, unknown.presentation);
}

const std = @import("std");
const agent = @import("../../agent/root.zig");
const chrome = @import("../chrome.zig");
const Editor = @import("../Editor.zig");
const input = @import("../input.zig");
const Loop = @import("../Loop.zig").Loop;
const screen = @import("../screen.zig");

pub const snapshot_bytes_max: usize = 2 * 1024 * 1024;
pub const Error = error{SnapshotTooLarge} || std.mem.Allocator.Error;

const scenario_steps_max: usize = 128;
const scenario_checkpoints_max: usize = 32;

const ScenarioStep = union(enum) {
    dispatch: input.Action,
    apply_event: agent.AgentEvent,
    tick: u64,
    resize: struct { width: u16, height: u16 },
    checkpoint_frame: struct { name: []const u8, width: u16, height: u16 },
};

const Scenario = struct {
    steps: [scenario_steps_max]ScenarioStep = undefined,
    len: usize = 0,
    checkpoint_count: usize = 0,

    fn append(self: *Scenario, step: ScenarioStep) !void {
        if (self.len == self.steps.len) return error.TooManyScenarioSteps;
        if (step == .checkpoint_frame) {
            if (self.checkpoint_count == scenario_checkpoints_max) return error.TooManyScenarioCheckpoints;
            self.checkpoint_count += 1;
        }
        self.steps[self.len] = step;
        self.len += 1;
    }

    fn run(self: *const Scenario, owner: *Loop) !void {
        for (self.steps[0..self.len]) |step| switch (step) {
            .dispatch => |action| try owner.dispatch(action),
            .apply_event => |event| {
                try owner.transcript.apply(owner.io, event);
                owner.dirty = true;
            },
            .tick => |now_ns| try owner.tick(now_ns),
            .resize => |size| _ = owner.noteResize(size.width, size.height),
            .checkpoint_frame => |checkpoint| {
                const frame = try owner.composeFrameAt(checkpoint.width, checkpoint.height, 0);
                const actual = try serialize(std.testing.allocator, &frame, checkpoint.width, checkpoint.height);
                defer std.testing.allocator.free(actual);
                try expectBaseline(checkpoint.name, actual);
            },
        };
    }
};

pub fn serialize(
    allocator: std.mem.Allocator,
    frame: *const screen.Frame,
    width: u16,
    height: u16,
) Error![]u8 {
    const storage = try allocator.alloc(u8, snapshot_bytes_max);
    defer allocator.free(storage);
    var writer = std.Io.Writer.fixed(storage);
    writeSnapshot(allocator, &writer, frame, width, height) catch return error.SnapshotTooLarge;
    return allocator.dupe(u8, writer.buffered());
}

fn writeSnapshot(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    frame: *const screen.Frame,
    width: u16,
    height: u16,
) !void {
    try writer.print("frame width={d} height={d}\n", .{ width, height });
    if (frame.cursor) |cursor| {
        try writer.print("cursor row={d} col={d}\n", .{ cursor.row, cursor.col });
    } else {
        try writer.writeAll("cursor null\n");
    }
    for (frame.rows(), 0..) |*row, row_index| {
        var text: std.Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        for (row.spans()) |span| {
            if (text.written().len > snapshot_bytes_max -| span.text.len) return error.WriteFailed;
            try text.writer.writeAll(span.text);
        }
        try writer.print("row {d} text=", .{row_index});
        try std.json.Stringify.value(text.written(), .{}, writer);
        try writer.writeAll(" surface=");
        try writeStyle(writer, row.row_style);
        try writer.writeByte('\n');
        for (row.spans(), 0..) |span, span_index| {
            try writer.print("  span {d} text=", .{span_index});
            try std.json.Stringify.value(span.text, .{}, writer);
            try writer.writeAll(" style=");
            try writeStyle(writer, span.style);
            try writer.writeByte('\n');
        }
    }
}

fn writeStyle(writer: *std.Io.Writer, style: screen.Style) !void {
    try writer.writeAll("{fg=");
    try writeColor(writer, style.fg);
    try writer.writeAll(",bg=");
    try writeColor(writer, style.bg);
    try writer.writeAll(",ul=");
    try writeColor(writer, style.ul);
    try writer.print(",ul_style={s},bold={},dim={},italic={},blink={},reverse={},invisible={},strikethrough={}}}", .{
        @tagName(style.ul_style),
        style.bold,
        style.dim,
        style.italic,
        style.blink,
        style.reverse,
        style.invisible,
        style.strikethrough,
    });
}

fn writeColor(writer: *std.Io.Writer, color: screen.Color) !void {
    switch (color) {
        .default => try writer.writeAll("default"),
        .index => |index| try writer.print("index({d})", .{index}),
        .rgb => |rgb| try writer.print("rgb(#{X:0>2}{X:0>2}{X:0>2})", .{ rgb[0], rgb[1], rgb[2] }),
    }
}

fn expectBaseline(name: []const u8, actual: []const u8) !void {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "docs/baselines/tui/{s}.txt", .{name});
    const expected = std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, std.testing.allocator, .limited(snapshot_bytes_max)) catch |err| {
        if (err == error.FileNotFound and updateRequested()) {
            try writeBaseline(path, actual);
            return;
        }
        std.debug.print("missing semantic baseline {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer std.testing.allocator.free(expected);
    if (!std.mem.eql(u8, expected, actual)) {
        if (updateRequested()) {
            try writeBaseline(path, actual);
            return;
        }
        std.debug.print("semantic baseline mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ path, expected, actual });
        return error.TestExpectedEqual;
    }
}

fn updateRequested() bool {
    const value = std.c.getenv("ZI_UPDATE_TUI_GOLDENS") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

fn writeBaseline(path: []const u8, actual: []const u8) !void {
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "docs/baselines/tui");
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = path, .data = actual });
}

test "semantic frame golden startup idle" {
    var editor: Editor = .{};
    const frame = try chrome.compose(.{ .editor = &editor }, 80, 24);
    const actual = try serialize(std.testing.allocator, &frame, 80, 24);
    defer std.testing.allocator.free(actual);
    try expectBaseline("startup-idle-80x24", actual);
}

test "semantic frame golden multiline unicode" {
    var editor: Editor = .{};
    try editor.insert("wide 界界\ncombining e\u{301} and wrapped text");
    const frame = try chrome.compose(.{ .status = .{ .text = "Preparing images… (esc to cancel)" }, .editor = &editor }, 40, 10);
    const actual = try serialize(std.testing.allocator, &frame, 40, 10);
    defer std.testing.allocator.free(actual);
    try expectBaseline("multiline-unicode-40x10", actual);
}

test "typed semantic scenario is bounded and drives concrete owner actions" {
    var owner = try Loop.init(std.testing.allocator, null);
    defer owner.deinit();
    owner.io = std.testing.io;
    var scenario: Scenario = .{};
    try scenario.append(.{ .resize = .{ .width = 40, .height = 10 } });
    try scenario.append(.{ .dispatch = .{ .insert = "typed" } });
    try scenario.append(.{ .tick = 1 });
    try scenario.run(&owner);
    try std.testing.expectEqualStrings("typed", owner.editor.text());

    var full: Scenario = .{};
    for (0..scenario_steps_max) |_| try full.append(.{ .tick = 0 });
    try std.testing.expectError(error.TooManyScenarioSteps, full.append(.{ .tick = 0 }));
}

test "semantic serializer includes surfaces spans styles and cursor" {
    var frame: screen.Frame = .{};
    var line: screen.Line = .{ .row_style = screen.surface.user_message };
    try line.append(.{ .text = "hello", .style = screen.text.warning });
    try frame.appendLine(line);
    frame.cursor = .{ .row = 0, .col = 5 };
    const actual = try serialize(std.testing.allocator, &frame, 10, 1);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "cursor row=0 col=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "row 0 text=\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "surface={fg=default,bg=rgb(#0D1218)") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "style={fg=rgb(#E6C384)") != null);
}

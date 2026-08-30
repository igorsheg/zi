const std = @import("std");
const ai = @import("../ai/root.zig");
const terminal = @import("../terminal/root.zig");

pub const EffortOutcome = union(enum) {
    canceled,
    selected: ?[]const u8,
};

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, []const terminal.Picker.Item, usize) anyerror!?usize,

    pub fn run(self: Runner, items: []const terminal.Picker.Item, initial_index: usize) !?usize {
        return self.run_fn(self.context, items, initial_index);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("SelectionPicker.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn run(
                context: *anyopaque,
                items: []const terminal.Picker.Item,
                initial_index: usize,
            ) anyerror!?usize {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(items, initial_index);
            }
        };
        return .{ .context = implementation, .run_fn = Adapter.run };
    }
};

pub const TerminalRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout: std.Io.File,
    writer: *std.Io.Writer,
    display_columns: terminal.DisplayColumns.Policy,
    style: terminal.Picker.Style,
    limits: terminal.Picker.Limits = .{},

    pub fn run(
        self: *TerminalRunner,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        return terminal.Picker.run(
            self.allocator,
            self.io,
            self.stdin,
            self.stdout.handle,
            self.writer,
            .{
                .title = "select reasoning effort",
                .items = items,
                .initial_index = initial_index,
                .display_columns = self.display_columns,
                .style = self.style,
            },
            self.limits,
        );
    }
};

/// Offers hax's distinct provider-default row followed by the exact provider
/// vocabulary in its declared order. Returned explicit values borrow `levels`.
pub fn effort(
    runner: Runner,
    levels: *const ai.Effort.Set,
    current_effort: ?[]const u8,
) !EffortOutcome {
    std.debug.assert(levels.count != 0);
    var rows: [ai.Effort.maximum_levels + 1]terminal.Picker.Item = undefined;
    rows[0] = .{
        .label = "default",
        .description = "Let the provider choose the reasoning effort",
    };
    var initial_index: usize = 0;
    for (0..levels.count) |index| {
        const value = levels.valueAt(index);
        const current = if (current_effort) |effort_value|
            std.mem.eql(u8, effort_value, value)
        else
            false;
        rows[index + 1] = .{ .label = value, .current = current };
        if (current) initial_index = index + 1;
    }

    const selected = try runner.run(rows[0 .. @as(usize, levels.count) + 1], initial_index) orelse
        return .canceled;
    std.debug.assert(selected <= levels.count);
    return .{ .selected = if (selected == 0) null else levels.valueAt(selected - 1) };
}

const FakeRunner = struct {
    selected: ?usize,
    expected_initial: usize,
    valid: bool = false,

    pub fn run(
        self: *FakeRunner,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        self.valid = items.len == 4 and
            std.mem.eql(u8, items[0].label, "default") and
            std.mem.eql(u8, items[0].description.?, "Let the provider choose the reasoning effort") and
            std.mem.eql(u8, items[1].label, "none") and
            std.mem.eql(u8, items[2].label, "low") and
            std.mem.eql(u8, items[3].label, "high") and
            items[2].current == (self.expected_initial == 2) and
            initial_index == self.expected_initial;
        return self.selected;
    }
};

test "effort picker keeps default distinct and preserves provider vocabulary" {
    const levels = try ai.Effort.Set.init(&.{ "none", "low", "high" });
    var explicit_runner: FakeRunner = .{ .selected = 1, .expected_initial = 2 };
    const explicit = try effort(Runner.from(&explicit_runner), &levels, "low");
    try std.testing.expect(explicit_runner.valid);
    try std.testing.expectEqualStrings("none", explicit.selected.?);

    var default_runner: FakeRunner = .{ .selected = 0, .expected_initial = 2 };
    const provider_default = try effort(Runner.from(&default_runner), &levels, "low");
    try std.testing.expect(provider_default.selected == null);
}

test "effort picker cancellation is a no-op result" {
    const levels = try ai.Effort.Set.init(&.{ "none", "low", "high" });
    var runner: FakeRunner = .{ .selected = null, .expected_initial = 0 };
    try std.testing.expect((try effort(Runner.from(&runner), &levels, null)) == .canceled);
    try std.testing.expect(runner.valid);
}

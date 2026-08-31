const std = @import("std");
const persistence = @import("../persistence/root.zig");
const terminal = @import("../terminal/root.zig");

pub const maximum_sessions: usize = 200;
pub const maximum_subject_cells: usize = 60;

pub const Outcome = union(enum) {
    selected: usize,
    canceled,
    empty,
};

pub const Request = struct {
    entries: []const persistence.SessionIndex.Entry,
    exclude_path: ?[]const u8 = null,
};

/// Synchronous picker. Entries and paths are borrowed only for the call.
pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, Request) anyerror!Outcome,

    pub fn run(self: Runner, request: Request) !Outcome {
        return self.run_fn(self.context, request);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("SessionPicker.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn runFn(context: *anyopaque, request: Request) anyerror!Outcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(request);
            }
        };
        return .{ .context = implementation, .run_fn = Adapter.runFn };
    }
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout: std.Io.File,
    writer: *std.Io.Writer,
    entries: []const persistence.SessionIndex.Entry,
    now_epoch_seconds: i64,
    exclude_path: ?[]const u8 = null,
    write_empty: bool = true,
    display_columns: terminal.DisplayColumns.Policy = .auto,
    style: terminal.Picker.Style = .{},
};

pub fn run(inputs: Inputs) terminal.Picker.Error!Outcome { // ziglint-ignore: Z015
    const visible_count = collectVisibleIndexes(inputs.entries, inputs.exclude_path, &.{});
    if (visible_count == 0) {
        if (inputs.write_empty) {
            try inputs.writer.writeAll("no past conversations in this directory\n");
            try inputs.writer.flush();
        }
        return .empty;
    }
    const picker_count = @min(visible_count, maximum_sessions);
    var arena: std.heap.ArenaAllocator = .init(inputs.allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const items = temporary.alloc(terminal.Picker.Item, picker_count) catch return error.OutOfMemory;
    const entry_indexes = temporary.alloc(usize, picker_count) catch return error.OutOfMemory;
    const mapped_count = collectVisibleIndexes(inputs.entries, inputs.exclude_path, entry_indexes);
    std.debug.assert(mapped_count == visible_count);
    for (entry_indexes, 0..) |entry_index, item_index| {
        const entry = inputs.entries[entry_index];
        var label = persistence.SessionLabel.read(
            temporary,
            inputs.io,
            entry.path,
            persistence.SessionLabel.default_prompt_cells,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => persistence.SessionLabel.Label{},
        };
        const detail = try formatRelativeTime(temporary, inputs.now_epoch_seconds, entry.mtime_nanoseconds);
        const description = try formatProvenance(temporary, &label);
        items[item_index] = .{
            .label = label.prompt orelse "(no preview)",
            .detail = detail,
            .description = description,
        };
    }
    const title = if (picker_count < visible_count)
        std.fmt.allocPrint(
            temporary,
            "resume a conversation · newest {d} of {d}",
            .{ picker_count, visible_count },
        ) catch return error.OutOfMemory
    else
        "resume a conversation";
    const selected = try terminal.Picker.run(
        inputs.allocator,
        inputs.io,
        inputs.stdin,
        inputs.stdout.handle,
        inputs.writer,
        .{
            .title = title,
            .items = items,
            .repeat_clipped_label = true,
            .display_columns = inputs.display_columns,
            .style = inputs.style,
        },
        .{ .max_items = maximum_sessions },
    );
    return if (selected) |selected_index|
        .{ .selected = entry_indexes[selected_index] }
    else
        .canceled;
}

fn collectVisibleIndexes(
    entries: []const persistence.SessionIndex.Entry,
    exclude_path: ?[]const u8,
    output: []usize,
) usize {
    var visible_count: usize = 0;
    for (entries, 0..) |entry, entry_index| {
        if (exclude_path) |excluded| if (std.mem.eql(u8, entry.path, excluded)) continue;
        if (visible_count < output.len) output[visible_count] = entry_index;
        visible_count += 1;
    }
    return visible_count;
}

fn formatRelativeTime(
    allocator: std.mem.Allocator,
    now_epoch_seconds: i64,
    mtime_nanoseconds: i96,
) error{OutOfMemory}![]u8 {
    const mtime_seconds_wide = @divFloor(mtime_nanoseconds, std.time.ns_per_s);
    const mtime_seconds: i64 = if (mtime_seconds_wide < std.math.minInt(i64))
        std.math.minInt(i64)
    else if (mtime_seconds_wide > std.math.maxInt(i64))
        std.math.maxInt(i64)
    else
        @intCast(mtime_seconds_wide);
    const seconds_ago = if (mtime_seconds >= now_epoch_seconds)
        0
    else
        std.math.sub(i64, now_epoch_seconds, mtime_seconds) catch std.math.maxInt(i64);
    if (seconds_ago < 60) return allocator.dupe(u8, "just now") catch error.OutOfMemory;
    if (seconds_ago < 3600) {
        return std.fmt.allocPrint(allocator, "{d}m ago", .{@divFloor(seconds_ago, 60)}) catch
            error.OutOfMemory;
    }
    if (seconds_ago < 86400) {
        return std.fmt.allocPrint(allocator, "{d}h ago", .{@divFloor(seconds_ago, 3600)}) catch
            error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{d}d ago", .{@divFloor(seconds_ago, 86400)}) catch
        error.OutOfMemory;
}

fn formatProvenance(
    allocator: std.mem.Allocator,
    label: *const persistence.SessionLabel.Label,
) error{OutOfMemory}!?[]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (label.preset) |preset| if (preset.len != 0) {
        output.append(allocator, '[') catch return error.OutOfMemory;
        output.appendSlice(allocator, preset) catch return error.OutOfMemory;
        output.append(allocator, ']') catch return error.OutOfMemory;
        if (hasSelectionFields(label)) output.append(allocator, ' ') catch return error.OutOfMemory;
    };
    try appendField(allocator, &output, label.provider, false);
    try appendField(allocator, &output, label.model, output.items.len != 0);
    try appendField(allocator, &output, label.effort, output.items.len != 0);
    const has_selection = output.items.len != 0;
    var git: std.ArrayList(u8) = .empty;
    defer git.deinit(allocator);
    try appendField(allocator, &git, label.git_branch, false);
    if (label.git_subject) |subject| if (subject.len != 0) {
        const clipped = persistence.SessionLabel.truncate(allocator, subject, maximum_subject_cells) catch
            return error.OutOfMemory;
        defer allocator.free(clipped);
        try appendField(allocator, &git, clipped, git.items.len != 0);
    };
    if (git.items.len != 0) {
        if (has_selection) output.append(allocator, '\n') catch return error.OutOfMemory;
        output.appendSlice(allocator, git.items) catch return error.OutOfMemory;
    }
    if (output.items.len == 0) {
        output.deinit(allocator);
        return null;
    }
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn hasSelectionFields(label: *const persistence.SessionLabel.Label) bool {
    return nonEmpty(label.provider) != null or nonEmpty(label.model) != null or nonEmpty(label.effort) != null;
}

fn appendField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: ?[]const u8,
    separator: bool,
) error{OutOfMemory}!void {
    const bytes = nonEmpty(value) orelse return;
    if (separator) output.appendSlice(allocator, " · ") catch return error.OutOfMemory;
    output.appendSlice(allocator, bytes) catch return error.OutOfMemory;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len == 0) null else bytes;
}

test "relative age follows hax boundaries and future clamp" {
    const allocator = std.testing.allocator;
    const now: i64 = 100_000;
    const cases = [_]struct { mtime: i64, expected: []const u8 }{
        .{ .mtime = now + 1, .expected = "just now" },
        .{ .mtime = now - 59, .expected = "just now" },
        .{ .mtime = now - 60, .expected = "1m ago" },
        .{ .mtime = now - 3599, .expected = "59m ago" },
        .{ .mtime = now - 3600, .expected = "1h ago" },
        .{ .mtime = now - 86400, .expected = "1d ago" },
    };
    for (cases) |case| {
        const value = try formatRelativeTime(allocator, now, @as(i96, case.mtime) * std.time.ns_per_s);
        defer allocator.free(value);
        try std.testing.expectEqualStrings(case.expected, value);
    }
}

test "provenance matches banner selection and git lines" {
    var label: persistence.SessionLabel.Label = .{
        .provider = @constCast("openai"),
        .model = @constCast("gpt"),
        .effort = @constCast("high"),
        .preset = @constCast("work"),
        .git_branch = @constCast("main"),
        .git_subject = @constCast("subject"),
    };
    const value = (try formatProvenance(std.testing.allocator, &label)).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("[work] openai · gpt · high\nmain · subject", value);
}

test "provenance permits preset-only and absent values" {
    var preset: persistence.SessionLabel.Label = .{ .preset = @constCast("review") };
    const value = (try formatProvenance(std.testing.allocator, &preset)).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("[review]", value);
    var empty: persistence.SessionLabel.Label = .{};
    try std.testing.expect((try formatProvenance(std.testing.allocator, &empty)) == null);
}

test "active exclusion preserves original indexes and caps newest picker rows" {
    var entries: [maximum_sessions + 2]persistence.SessionIndex.Entry = undefined;
    for (&entries) |*entry| {
        entry.* = .{
            .name = @constCast("session.jsonl"),
            .path = @constCast("visible"),
            .id = null,
            .mtime_nanoseconds = 0,
            .meta = .{},
        };
    }
    entries[1].path = @constCast("active");
    var indexes: [maximum_sessions]usize = undefined;

    try std.testing.expectEqual(
        @as(usize, maximum_sessions + 1),
        collectVisibleIndexes(&entries, "active", &indexes),
    );
    try std.testing.expectEqual(@as(usize, 0), indexes[0]);
    try std.testing.expectEqual(@as(usize, 2), indexes[1]);
    try std.testing.expectEqual(@as(usize, maximum_sessions), indexes[maximum_sessions - 1]);
}

const std = @import("std");
const config = @import("../config/root.zig");

pub const Tint = enum {
    teal,
    violet,
    rose,
    sage,

    pub fn canonical(self: Tint) []const u8 {
        return @tagName(self);
    }
};

pub fn parseTint(value: []const u8) ?Tint {
    inline for (std.meta.fields(Tint)) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub const Arguments = struct {
    name: []const u8,
    tint_text: ?[]const u8,
};

/// Parses the borrowed slash-command argument without trimming the tint tail.
pub fn parse(argument: ?[]const u8) ?Arguments {
    const bytes = argument orelse return null;
    var cursor: usize = 0;
    while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
    const name_start = cursor;
    while (cursor < bytes.len and !std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
    if (cursor == name_start) return null;
    const name = bytes[name_start..cursor];
    while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
    return .{
        .name = name,
        .tint_text = if (cursor < bytes.len) bytes[cursor..] else null,
    };
}

pub const SelectionFacts = struct {
    generation: u64,
    provider: []const u8,
    model: []const u8,
    effort: ?[]const u8,
    active_preset: ?[]const u8,
    model_discovered: bool,
};

pub const InitialTint = union(enum) {
    none,
    unsupported,
    selected: Tint,
};

/// Move-only inspection. Both optional slices are allocator-owned.
pub const Inspection = struct {
    path: ?[]u8,
    exists: bool,
    detail: ?[]u8,
    initial_tint: InitialTint,

    pub fn deinit(self: *Inspection, allocator: std.mem.Allocator) void {
        if (self.path) |value| allocator.free(value);
        if (self.detail) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Request = struct {
    name: []const u8,
    tint: ?Tint,
    selection: SelectionFacts,
};

pub const Source = struct {
    context: *anyopaque,
    inspect_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, ?[]const u8) anyerror!Inspection,
    save_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!config.ConfigWriter.SaveOutcome,

    pub fn inspect(
        self: Source,
        allocator: std.mem.Allocator,
        name: []const u8,
        active_preset: ?[]const u8,
    ) !Inspection {
        return self.inspect_fn(self.context, allocator, name, active_preset);
    }

    pub fn save(
        self: Source,
        outcome_allocator: std.mem.Allocator,
        request: Request,
    ) !config.ConfigWriter.SaveOutcome {
        return self.save_fn(self.context, outcome_allocator, request);
    }

    pub fn from(implementation: anytype) Source {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("PresetSave.Source.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn inspect(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                name: []const u8,
                active_preset: ?[]const u8,
            ) anyerror!Inspection {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.inspectPresetSave(allocator, name, active_preset);
            }

            fn save(
                context: *anyopaque,
                outcome_allocator: std.mem.Allocator,
                request: Request,
            ) anyerror!config.ConfigWriter.SaveOutcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.savePreset(outcome_allocator, request);
            }
        };
        return .{
            .context = implementation,
            .inspect_fn = Adapter.inspect,
            .save_fn = Adapter.save,
        };
    }
};

test "preset save policy parses names and literal tint tails" {
    try std.testing.expect(parse(null) == null);
    try std.testing.expect(parse(" \t\n") == null);
    const bare = parse("  review  ").?;
    try std.testing.expectEqualStrings("review", bare.name);
    try std.testing.expect(bare.tint_text == null);
    const tinted = parse("\treview  RoSe \t").?;
    try std.testing.expectEqualStrings("review", tinted.name);
    try std.testing.expectEqualStrings("RoSe \t", tinted.tint_text.?);
}

test "preset save policy canonicalizes only supported tints" {
    try std.testing.expectEqual(Tint.teal, parseTint("TEAL").?);
    try std.testing.expectEqual(Tint.violet, parseTint("Violet").?);
    try std.testing.expectEqualStrings("rose", parseTint("ROSE").?.canonical());
    try std.testing.expectEqual(Tint.sage, parseTint("sage").?);
    try std.testing.expect(parseTint("none") == null);
    try std.testing.expect(parseTint("rose ") == null);
}

const TestSource = struct {
    inspected_name: ?[]const u8 = null,
    inspected_active: ?[]const u8 = null,
    saved: ?Request = null,

    pub fn inspectPresetSave(
        self: *TestSource,
        allocator: std.mem.Allocator,
        name: []const u8,
        active_preset: ?[]const u8,
    ) !Inspection {
        self.inspected_name = name;
        self.inspected_active = active_preset;
        const path = try allocator.dupe(u8, "config.json");
        errdefer allocator.free(path);
        const detail = try allocator.dupe(u8, "mock · model · high");
        return .{
            .path = path,
            .exists = true,
            .detail = detail,
            .initial_tint = .{ .selected = .rose },
        };
    }

    pub fn savePreset(
        self: *TestSource,
        _: std.mem.Allocator,
        request: Request,
    ) !config.ConfigWriter.SaveOutcome {
        self.saved = request;
        return .{ .written = .saved };
    }
};

test "preset save policy forwards typed requests and owns inspection bytes" {
    var implementation: TestSource = .{};
    const source = Source.from(&implementation);
    var inspection = try source.inspect(std.testing.allocator, "review", "work");
    defer inspection.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review", implementation.inspected_name.?);
    try std.testing.expectEqualStrings("work", implementation.inspected_active.?);
    try std.testing.expectEqualStrings("config.json", inspection.path.?);
    try std.testing.expectEqualStrings("mock · model · high", inspection.detail.?);
    try std.testing.expectEqual(Tint.rose, inspection.initial_tint.selected);

    var outcome = try source.save(std.testing.allocator, .{
        .name = "review",
        .tint = .sage,
        .selection = .{
            .generation = 7,
            .provider = "mock",
            .model = "mock-model",
            .effort = "high",
            .active_preset = "work",
            .model_discovered = false,
        },
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.ConfigWriter.SaveKind.saved, outcome.written);
    try std.testing.expectEqual(Tint.sage, implementation.saved.?.tint.?);
    try std.testing.expectEqual(@as(u64, 7), implementation.saved.?.selection.generation);
}

test "preset save policy inspection releases every allocation on OOM" {
    var implementation: TestSource = .{};
    const source = Source.from(&implementation);
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator, source_value: Source) !void {
            var inspection = try source_value.inspect(allocator, "review", null);
            inspection.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{source});
}

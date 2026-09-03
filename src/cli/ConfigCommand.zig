const std = @import("std");
const config = @import("../config/root.zig");
const render = @import("../render/root.zig");
const terminal = @import("../terminal/root.zig");
const SelectionPicker = @import("SelectionPicker.zig");
const DiagnosticText = @import("DiagnosticText.zig");

pub const maximum_key_bytes: usize = 63;
pub const maximum_subject_bytes: usize = 4096;

pub const ApplyResult = union(enum) {
    failed,
    changed: config.Settings.Inspection,
};

pub const Source = struct {
    context: *anyopaque,
    inspect_fn: *const fn (
        std.mem.Allocator,
        *anyopaque,
        *const config.Settings.Setting,
        usize,
    ) anyerror!config.Settings.Inspection,
    apply_fn: *const fn (
        std.mem.Allocator,
        *anyopaque,
        *const config.Settings.Setting,
        config.Settings.Update,
        usize,
    ) anyerror!ApplyResult,
    theme_fn: *const fn (*const anyopaque) render.Theme,

    pub fn inspect(
        self: Source,
        allocator: std.mem.Allocator,
        setting: *const config.Settings.Setting,
        maximum: usize,
    ) !config.Settings.Inspection {
        return self.inspect_fn(allocator, self.context, setting, maximum);
    }

    pub fn apply(
        self: Source,
        allocator: std.mem.Allocator,
        setting: *const config.Settings.Setting,
        update: config.Settings.Update,
        maximum: usize,
    ) !ApplyResult {
        return self.apply_fn(allocator, self.context, setting, update, maximum);
    }

    pub fn theme(self: Source) render.Theme {
        return self.theme_fn(self.context);
    }

    pub fn from(implementation: anytype) Source {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("ConfigCommand.Source.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn inspect(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                setting: *const config.Settings.Setting,
                maximum: usize,
            ) anyerror!config.Settings.Inspection {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.inspect(allocator, setting, maximum);
            }

            fn apply(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                setting: *const config.Settings.Setting,
                update: config.Settings.Update,
                maximum: usize,
            ) anyerror!ApplyResult {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.apply(allocator, setting, update, maximum);
            }

            fn theme(context: *const anyopaque) render.Theme {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.theme();
            }
        };
        return .{
            .context = implementation,
            .inspect_fn = Adapter.inspect,
            .apply_fn = Adapter.apply,
            .theme_fn = Adapter.theme,
        };
    }
};

pub const Outcome = union(enum) {
    handled,
    preseed: []const u8,
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    styled: bool,
    source: Source,
    picker: ?SelectionPicker.Runner = null,
    preseed_buffer: []u8,
};

pub fn run(inputs: Inputs, argument: ?[]const u8) !Outcome {
    @memset(inputs.preseed_buffer, 0);
    const bytes = argument orelse return runPicker(inputs);
    const parsed = parse(bytes) orelse return .handled;
    if (parsed.key.len > maximum_key_bytes) {
        try writeUnknown(inputs.writer, parsed.key, false);
        return .handled;
    }
    const setting = config.Settings.find(parsed.key) orelse {
        try writeUnknown(inputs.writer, parsed.key, true);
        return .handled;
    };
    const value = parsed.value orelse {
        try writeInspection(inputs, setting);
        try writeGuidance(inputs.writer, setting);
        return .handled;
    };

    const update = config.Settings.validateUpdate(setting, value) catch |err| switch (err) {
        error.ReadOnly => {
            try writeReadOnlyMutation(inputs.writer, setting);
            return .handled;
        },
        error.InvalidValue => {
            try writeInvalid(inputs.writer, setting, value);
            return .handled;
        },
    };
    try applyAndWrite(inputs, setting, update);
    return .handled;
}

fn runPicker(inputs: Inputs) !Outcome {
    const picker = inputs.picker orelse return .handled;
    const setting_outcome = try SelectionPicker.configSetting(inputs.allocator, picker, inputs.source);
    const index = switch (setting_outcome) {
        .canceled => return .handled,
        .budget_exceeded => {
            try inputs.writer.writeAll(
                "couldn't prepare the configuration list — keeping the current settings\n",
            );
            return .handled;
        },
        .selected => |value| value,
    };
    const settings = config.Settings.list();
    if (index >= settings.len) return .handled;
    const setting = &settings[index];
    if (!setting.editable) {
        try writeInspection(inputs, setting);
        try writeGuidance(inputs.writer, setting);
        return .handled;
    }

    if (setting.choices.len != 0) {
        const value_outcome = try SelectionPicker.configValue(
            inputs.allocator,
            picker,
            inputs.source,
            setting,
            inputs.preseed_buffer,
        );
        switch (value_outcome) {
            .canceled => return .handled,
            .exact => |seed| return .{ .preseed = seed },
            .selected => |update| {
                try applyAndWrite(inputs, setting, update);
                return .handled;
            },
        }
    }

    var inspection = try inputs.source.inspect(inputs.allocator, setting, maximum_subject_bytes);
    defer inspection.deinit(inputs.allocator);
    @memset(inputs.preseed_buffer, 0);
    const value = if (!inspection.invalid and !std.mem.eql(u8, inspection.display, "unset"))
        inspection.display
    else
        setting.default orelse setting.example orelse "";
    const seed = try std.fmt.bufPrint(
        inputs.preseed_buffer,
        "/config {s} {s}",
        .{ setting.key, value },
    );
    return .{ .preseed = seed };
}

fn applyAndWrite(
    inputs: Inputs,
    setting: *const config.Settings.Setting,
    update: config.Settings.Update,
) !void {
    const result = try inputs.source.apply(
        inputs.allocator,
        setting,
        update,
        maximum_subject_bytes,
    );
    switch (result) {
        .failed => try writeApplyFailed(inputs.writer, setting),
        .changed => |value| {
            var inspection = value;
            defer inspection.deinit(inputs.allocator);
            try writeInspectionValue(inputs, setting, &inspection);
        },
    }
}

fn writeApplyFailed(writer: *std.Io.Writer, setting: *const config.Settings.Setting) !void {
    try writer.writeAll("couldn't change '");
    _ = try DiagnosticText.writeBounded(writer, setting.key, maximum_subject_bytes);
    try writer.writeAll("' — keeping the current settings\n");
}

const Parsed = struct {
    key: []const u8,
    value: ?[]const u8,
};

fn parse(argument: []const u8) ?Parsed {
    var key_end: usize = 0;
    while (key_end < argument.len and !std.ascii.isWhitespace(argument[key_end])) key_end += 1;
    if (key_end == 0) return null;
    var value_start = key_end;
    while (value_start < argument.len and std.ascii.isWhitespace(argument[value_start])) value_start += 1;
    return .{
        .key = argument[0..key_end],
        .value = if (value_start == argument.len) null else argument[value_start..],
    };
}

fn writeInspection(inputs: Inputs, setting: *const config.Settings.Setting) !void {
    var inspection = try inputs.source.inspect(inputs.allocator, setting, maximum_subject_bytes);
    defer inspection.deinit(inputs.allocator);
    try writeInspectionValue(inputs, setting, &inspection);
}

fn writeInspectionValue(
    inputs: Inputs,
    setting: *const config.Settings.Setting,
    inspection: *const config.Settings.Inspection,
) !void {
    const theme = inputs.source.theme();
    if (inputs.styled) try inputs.writer.writeAll(theme.accent.open);
    try inputs.writer.writeAll(setting.key);
    if (inputs.styled) try inputs.writer.writeAll(theme.accent.close);
    try inputs.writer.writeAll(" = ");
    _ = try DiagnosticText.writeBounded(inputs.writer, inspection.display, maximum_subject_bytes);
    try inputs.writer.writeAll(" (");
    try inputs.writer.writeAll(inspection.source.label());
    if (inspection.invalid) try inputs.writer.writeAll(", invalid");
    try inputs.writer.writeAll(")\n");
}

fn writeGuidance(writer: *std.Io.Writer, setting: *const config.Settings.Setting) !void {
    if (setting.editable) return;
    if (dedicatedCommand(setting.key)) |command| {
        try writer.print("  change it with /{s}\n", .{command});
        return;
    }
    try writer.writeAll("  read-only at runtime — set ");
    try DiagnosticText.write(writer, setting.env);
    try writer.writeAll(" or config.json and restart to change\n");
}

fn writeUnknown(writer: *std.Io.Writer, key: []const u8, include_hint: bool) !void {
    try writer.writeAll("unknown setting '");
    _ = try DiagnosticText.writeBounded(writer, key, maximum_subject_bytes);
    try writer.writeByte('\'');
    if (include_hint) try writer.writeAll(" — /config lists them");
    try writer.writeByte('\n');
}

fn writeReadOnlyMutation(writer: *std.Io.Writer, setting: *const config.Settings.Setting) !void {
    try writer.writeByte('\'');
    try writer.writeAll(setting.key);
    if (dedicatedCommand(setting.key)) |command| {
        try writer.print("' can't be changed from /config — use /{s}\n", .{command});
        return;
    }
    try writer.writeAll("' can't be changed at runtime — set ");
    try DiagnosticText.write(writer, setting.env);
    try writer.writeAll(" or config.json and restart\n");
}

fn writeInvalid(
    writer: *std.Io.Writer,
    setting: *const config.Settings.Setting,
    value: []const u8,
) !void {
    try writer.writeAll("invalid value '");
    _ = try DiagnosticText.writeBounded(writer, value, maximum_subject_bytes);
    try writer.writeAll("' for ");
    try writer.writeAll(setting.key);
    try writer.writeAll(" (expected: ");
    var hint_buffer: [160]u8 = undefined;
    try writer.writeAll(config.Settings.expectedHint(setting, &hint_buffer));
    try writer.writeAll(", or default)\n");
}

fn dedicatedCommand(key: []const u8) ?[]const u8 {
    inline for (.{ "provider", "model", "effort", "preset" }) |command| {
        if (std.mem.eql(u8, key, command)) return command;
    }
    return null;
}

const FakeSource = struct {
    value: []const u8 = "85",
    source: config.Store.Source = .default,
    invalid: bool = false,

    pub fn inspect(
        self: *FakeSource,
        allocator: std.mem.Allocator,
        _: *const config.Settings.Setting,
        _: usize,
    ) !config.Settings.Inspection {
        return .{
            .display = try allocator.dupe(u8, self.value),
            .source = self.source,
            .invalid = self.invalid,
            .clipped = false,
        };
    }

    pub fn apply(
        self: *FakeSource,
        allocator: std.mem.Allocator,
        setting: *const config.Settings.Setting,
        update: config.Settings.Update,
        maximum: usize,
    ) !ApplyResult {
        switch (update) {
            .clear => {
                self.value = "85";
                self.source = .default;
            },
            .set => |value| {
                self.value = value;
                self.source = .run;
            },
        }
        return .{ .changed = try self.inspect(allocator, setting, maximum) };
    }

    pub fn theme(_: *const FakeSource) render.Theme {
        return render.Theme.resolve(.{ .configured_theme = "off", .configured_tint = "teal" }) catch unreachable;
    }
};

fn runForTest(source: *FakeSource, argument: ?[]const u8, output: *std.Io.Writer.Allocating) !void {
    var preseed: [128]u8 = undefined;
    _ = try run(.{
        .allocator = std.testing.allocator,
        .writer = &output.writer,
        .styled = false,
        .source = .from(source),
        .preseed_buffer = &preseed,
    }, argument);
}

test "direct config query mutation clear and diagnostics are exact" {
    var source: FakeSource = .{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try runForTest(&source, "compact.threshold", &output);
    try std.testing.expectEqualStrings("compact.threshold = 85 (default)\n", output.written());
    output.clearRetainingCapacity();

    try runForTest(&source, "compact.threshold 75", &output);
    try std.testing.expectEqualStrings("compact.threshold = 75 (run)\n", output.written());
    output.clearRetainingCapacity();

    try runForTest(&source, "compact.threshold default", &output);
    try std.testing.expectEqualStrings("compact.threshold = 85 (default)\n", output.written());
    output.clearRetainingCapacity();

    try runForTest(&source, "compact.threshold 101", &output);
    try std.testing.expectEqualStrings(
        "invalid value '101' for compact.threshold (expected: a whole number from 1 to 100, or default)\n",
        output.written(),
    );
    output.clearRetainingCapacity();

    try runForTest(&source, "provider x", &output);
    try std.testing.expectEqualStrings(
        "'provider' can't be changed from /config — use /provider\n",
        output.written(),
    );
}

const ConfigPicker = struct {
    calls: usize = 0,

    pub fn run(
        self: *ConfigPicker,
        title: []const u8,
        items: []const terminal.Picker.Item,
        _: usize,
    ) !?usize {
        self.calls += 1;
        if (self.calls == 1) {
            try std.testing.expectEqualStrings("configuration", title);
            for (items) |item| try std.testing.expect(!std.mem.startsWith(u8, item.label, "providers."));
            for (items, 0..) |item, index| {
                if (std.mem.eql(u8, item.label, "display_width")) return index;
            }
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(std.mem.startsWith(u8, title, "display_width — "));
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item.label, "exact value...")) {
                try std.testing.expectEqualStrings("Enter an exact value such as 100", item.description.?);
                return index;
            }
        }
        return error.TestUnexpectedResult;
    }
};

test "bare config uses two picker stages and returns stable exact preseed" {
    var source: FakeSource = .{ .value = "auto", .source = .default };
    var picker: ConfigPicker = .{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var preseed: [128]u8 = undefined;
    const outcome = try run(.{
        .allocator = std.testing.allocator,
        .writer = &output.writer,
        .styled = false,
        .source = .from(&source),
        .picker = SelectionPicker.Runner.from(&picker),
        .preseed_buffer = &preseed,
    }, null);
    try std.testing.expectEqual(@as(usize, 2), picker.calls);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    switch (outcome) {
        .handled => return error.TestUnexpectedResult,
        .preseed => |bytes| try std.testing.expectEqualStrings("/config display_width 100", bytes),
    }
}

const InvalidExactPicker = struct {
    pub fn run(
        _: *InvalidExactPicker,
        _: []const u8,
        items: []const terminal.Picker.Item,
        _: usize,
    ) !?usize {
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item.label, "compact.threshold")) return index;
        }
        return error.TestUnexpectedResult;
    }
};

test "invalid free-form picker preseed uses the registry default" {
    var source: FakeSource = .{ .value = "banana", .source = .env, .invalid = true };
    var picker: InvalidExactPicker = .{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var preseed: [128]u8 = undefined;
    const outcome = try run(.{
        .allocator = std.testing.allocator,
        .writer = &output.writer,
        .styled = false,
        .source = .from(&source),
        .picker = SelectionPicker.Runner.from(&picker),
        .preseed_buffer = &preseed,
    }, null);
    switch (outcome) {
        .handled => return error.TestUnexpectedResult,
        .preseed => |bytes| try std.testing.expectEqualStrings("/config compact.threshold 85", bytes),
    }
}

test "bare config is silent and unknown keys preserve the long-key distinction" {
    var source: FakeSource = .{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try runForTest(&source, null, &output);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);

    try runForTest(&source, "missing", &output);
    try std.testing.expectEqualStrings("unknown setting 'missing' — /config lists them\n", output.written());
    output.clearRetainingCapacity();

    const long_key = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    try runForTest(&source, long_key, &output);
    try std.testing.expectEqualStrings(
        "unknown setting 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'\n",
        output.written(),
    );
}

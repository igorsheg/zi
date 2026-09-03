const std = @import("std");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const render = @import("../render/root.zig");
const ProviderConfig = @import("../ProviderConfig.zig");
const terminal = @import("../terminal/root.zig");
const ModelOrder = @import("ModelOrder.zig");
const PresetSave = @import("PresetSave.zig");
const ConfigCommand = @import("ConfigCommand.zig");
const DiagnosticText = @import("DiagnosticText.zig");

pub const EffortOutcome = union(enum) {
    canceled,
    selected: ?[]const u8,
};

pub const ModelOutcome = union(enum) {
    canceled,
    selected: usize,
};

pub const ProviderOutcome = union(enum) {
    canceled,
    selected: usize,
};

pub const PresetOutcome = union(enum) {
    canceled,
    selected: usize,
};

pub const ConfigSettingOutcome = union(enum) {
    canceled,
    budget_exceeded,
    selected: usize,
};

pub const ConfigValueOutcome = union(enum) {
    canceled,
    selected: config.Settings.Update,
    exact: []const u8,
};

pub const PresetOverwriteOutcome = enum {
    canceled,
    keep,
    overwrite,
};

pub const PresetTintOutcome = union(enum) {
    canceled,
    selected: ?PresetSave.Tint,
};

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, []const u8, []const terminal.Picker.Item, usize) anyerror!?usize,

    pub fn run(
        self: Runner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        return self.run_fn(self.context, title, items, initial_index);
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
                title: []const u8,
                items: []const terminal.Picker.Item,
                initial_index: usize,
            ) anyerror!?usize {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(title, items, initial_index);
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
    repeat_clipped_label: bool = false,

    pub fn run(
        self: *TerminalRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        return terminal.Picker.run(
            self.allocator,
            self.io,
            self.stdin,
            self.stdout.handle,
            self.writer,
            self.pickerOptions(title, items, initial_index),
            self.limits,
        );
    }

    fn pickerOptions(
        self: *const TerminalRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) terminal.Picker.Options {
        return .{
            .title = title,
            .items = items,
            .initial_index = initial_index,
            .repeat_clipped_label = self.repeat_clipped_label,
            .display_columns = self.display_columns,
            .style = self.style,
        };
    }
};

const config_picker_bytes: usize = 256 * 1024;

pub fn configSetting(
    allocator: std.mem.Allocator,
    runner: Runner,
    source: ConfigCommand.Source,
) !ConfigSettingOutcome {
    const storage = try allocator.alloc(u8, config_picker_bytes);
    defer {
        std.crypto.secureZero(u8, storage);
        allocator.free(storage);
    }
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const temporary = fixed.allocator();
    const settings = config.Settings.list();
    const rows = temporary.alloc(terminal.Picker.Item, settings.len) catch
        return .budget_exceeded;
    const indexes = temporary.alloc(usize, settings.len) catch
        return .budget_exceeded;
    var count: usize = 0;
    for (settings, 0..) |*setting, index| {
        if (std.mem.startsWith(u8, setting.key, "providers.")) continue;
        var inspection = try source.inspect(allocator, setting, ConfigCommand.maximum_subject_bytes);
        defer inspection.deinit(allocator);

        var detail: std.Io.Writer.Allocating = .init(temporary);
        _ = DiagnosticText.writeBounded(
            &detail.writer,
            inspection.display,
            ConfigCommand.maximum_subject_bytes,
        ) catch return .budget_exceeded;
        detail.writer.print(
            " ({s}{s})",
            .{
                inspection.source.label(),
                if (inspection.invalid) ", invalid" else "",
            },
        ) catch return .budget_exceeded;

        var hint_buffer: [160]u8 = undefined;
        const description = if (setting.editable)
            std.fmt.allocPrint(
                temporary,
                "{s}; expected {s} or default",
                .{ setting.description, config.Settings.expectedHint(setting, &hint_buffer) },
            ) catch return .budget_exceeded
        else
            setting.description;
        rows[count] = .{
            .label = setting.key,
            .detail = detail.written(),
            .dim = !setting.editable,
            .description = description,
        };
        indexes[count] = index;
        count += 1;
    }
    const selected = try runner.run("configuration", rows[0..count], 0) orelse return .canceled;
    if (selected >= count) return .canceled;
    return .{ .selected = indexes[selected] };
}

pub fn configValue(
    allocator: std.mem.Allocator,
    runner: Runner,
    source: ConfigCommand.Source,
    setting: *const config.Settings.Setting,
    preseed_buffer: []u8,
) !ConfigValueOutcome {
    var inspection = try source.inspect(allocator, setting, ConfigCommand.maximum_subject_bytes);
    defer inspection.deinit(allocator);
    const extra: usize = @intFromBool(setting.example != null);
    const rows = try allocator.alloc(terminal.Picker.Item, setting.choices.len + 1 + extra);
    defer allocator.free(rows);
    rows[0] = .{
        .label = "default",
        .description = "Clear the runtime override and use the environment, saved configuration, or built-in default",
    };
    var initial_index: usize = 0;
    for (setting.choices, 0..) |value, index| {
        const current = std.ascii.eqlIgnoreCase(inspection.display, value);
        rows[index + 1] = .{
            .label = value,
            .current = current,
            .label_color = if (std.mem.eql(u8, setting.key, "tint"))
                (source.theme().withTint(value) catch source.theme()).stance.open
            else
                null,
        };
        if (current) initial_index = index + 1;
    }
    var exact_description: ?[]u8 = null;
    defer if (exact_description) |bytes| allocator.free(bytes);
    const validated = config.Settings.validateUpdate(setting, inspection.display) catch null;
    const exact_valid = if (validated) |update| update == .set else false;
    const exact_value_valid = exact_valid and initial_index == 0;
    if (setting.example) |example| {
        exact_description = try std.fmt.allocPrint(
            allocator,
            "Enter an exact value such as {s}",
            .{example},
        );
        rows[rows.len - 1] = .{
            .label = "exact value...",
            .description = exact_description.?,
            .current = exact_value_valid,
        };
        if (exact_value_valid) initial_index = rows.len - 1;
    }
    const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ setting.key, setting.description });
    defer allocator.free(title);
    const selected = try runner.run(title, rows, initial_index) orelse return .canceled;
    if (selected >= rows.len) return .canceled;
    if (selected == 0) return .{ .selected = .clear };
    if (selected <= setting.choices.len)
        return .{ .selected = .{ .set = setting.choices[selected - 1] } };

    const exact = if (!inspection.invalid and exact_value_valid)
        inspection.display
    else
        setting.example orelse "";
    const seed = try std.fmt.bufPrint(preseed_buffer, "/config {s} {s}", .{ setting.key, exact });
    return .{ .exact = seed };
}

/// Sorts by display label while returning an index into registry-priority
/// choices. Dimmed unavailable rows remain selectable.
pub fn provider(
    allocator: std.mem.Allocator,
    runner: Runner,
    choices: []const ProviderConfig.ProviderChoice,
    current_provider: []const u8,
) !ProviderOutcome {
    if (choices.len == 0) return .canceled;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const order = try temporary.alloc(usize, choices.len);
    for (order, 0..) |*destination, index| destination.* = index;
    std.mem.sort(usize, order, choices, lessProviderIndex);

    const rows = try temporary.alloc(terminal.Picker.Item, choices.len);
    var initial_index: usize = 0;
    for (order, rows, 0..) |source_index, *row, row_index| {
        const choice = choices[source_index];
        const current = std.mem.eql(u8, choice.id, current_provider);
        row.* = .{
            .label = choice.label,
            .description = if (!std.mem.eql(u8, choice.label, choice.id))
                try std.fmt.allocPrint(temporary, "id: {s}", .{choice.id})
            else
                null,
            .detail = choice.reason,
            .dim = !choice.available,
            .current = current,
        };
        if (current) initial_index = row_index;
    }
    const selected = try runner.run("select a provider", rows, initial_index) orelse return .canceled;
    std.debug.assert(selected < order.len);
    return .{ .selected = order[selected] };
}

fn lessProviderIndex(choices: []const ProviderConfig.ProviderChoice, left: usize, right: usize) bool {
    const label_order = std.mem.order(u8, choices[left].label, choices[right].label);
    if (label_order != .eq) return label_order == .lt;
    return std.mem.lessThan(u8, choices[left].id, choices[right].id);
}

pub fn presetOverwrite(
    allocator: std.mem.Allocator,
    runner: Runner,
    name: []const u8,
    detail: ?[]const u8,
) !PresetOverwriteOutcome {
    const title = try std.fmt.allocPrint(allocator, "preset '{s}' already exists", .{name});
    defer allocator.free(title);
    const rows = [_]terminal.Picker.Item{
        .{
            .label = "keep it",
            .description = "Leave the existing definition alone",
            .current = true,
        },
        .{
            .label = "overwrite",
            .detail = detail,
            .description = "Replace it with the current selection",
        },
    };
    const selected = try runner.run(title, &rows, 0) orelse return .canceled;
    std.debug.assert(selected < rows.len);
    return if (selected == 0) .keep else .overwrite;
}

pub fn presetTint(
    runner: Runner,
    base_theme: render.Theme,
    initial: PresetSave.InitialTint,
) !PresetTintOutcome {
    var rows = [_]terminal.Picker.Item{
        .{
            .label = "none",
            .description = "Carry no tint of its own: your tint setting applies",
        },
        .{ .label = "teal" },
        .{ .label = "violet" },
        .{ .label = "rose" },
        .{ .label = "sage" },
    };
    const tints = [_]PresetSave.Tint{ .teal, .violet, .rose, .sage };
    for (tints, 1..) |tint, index| {
        const preview = base_theme.withTint(tint.canonical()) catch unreachable;
        rows[index].label_color = if (preview.stance.open.len == 0) null else preview.stance.open;
    }
    const initial_index: usize = switch (initial) {
        .none => index: {
            rows[0].current = true;
            break :index 0;
        },
        .unsupported => 0,
        .selected => |selected| index: {
            const value = @intFromEnum(selected) + 1;
            rows[value].current = true;
            break :index value;
        },
    };
    const selected = try runner.run("tint for this preset", &rows, initial_index) orelse return .canceled;
    std.debug.assert(selected < rows.len);
    return .{ .selected = if (selected == 0) null else tints[selected - 1] };
}

/// Builds bounded preset rows and returns an index into the cached plan slice.
pub fn preset(
    allocator: std.mem.Allocator,
    runner: Runner,
    plans: []const config.Preset.Plan,
    providers: []const ProviderConfig.ProviderChoice,
    current_preset: ?[]const u8,
    base_theme: render.Theme,
) !PresetOutcome {
    if (plans.len == 0) return .canceled;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();

    var configured: std.StringHashMapUnmanaged(void) = .empty;
    for (providers) |provider_value| try configured.put(temporary, provider_value.id, {});

    const order = try temporary.alloc(usize, plans.len);
    for (order, 0..) |*destination, index| destination.* = index;
    std.mem.sort(usize, order, plans, lessPresetIndex);

    const rows = try temporary.alloc(terminal.Picker.Item, plans.len);
    var initial_index: usize = 0;
    for (order, rows, 0..) |source_index, *row, row_index| {
        const plan = &plans[source_index];
        const known = ai.ProviderRegistry.find(plan.provider) != null or configured.contains(plan.provider);
        const current = if (current_preset) |name| std.mem.eql(u8, name, plan.name) else false;
        const preview = if (plan.tint.value) |tint| base_theme.withTint(tint) catch unreachable else base_theme;
        row.* = .{
            .label = plan.name,
            .description = plan.description.value,
            .detail = if (known)
                try presetDetail(temporary, plan)
            else
                try std.fmt.allocPrint(temporary, "unknown provider '{s}'", .{plan.provider}),
            .dim = !known,
            .current = current,
            .label_color = if (preview.stance.open.len == 0) null else preview.stance.open,
        };
        if (current) initial_index = row_index;
    }

    const selected = try runner.run("select a preset", rows, initial_index) orelse return .canceled;
    std.debug.assert(selected < order.len);
    return .{ .selected = order[selected] };
}

fn lessPresetIndex(plans: []const config.Preset.Plan, left: usize, right: usize) bool {
    return std.mem.lessThan(u8, plans[left].name, plans[right].name);
}

fn presetDetail(allocator: std.mem.Allocator, plan: *const config.Preset.Plan) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var has_segment = false;
    try appendSeparator(&output.writer, &has_segment);
    try output.writer.writeAll(plan.provider);
    if (plan.model.value) |model_value| if (model_value.len != 0) {
        try appendSeparator(&output.writer, &has_segment);
        try output.writer.writeAll(model_value);
    };
    if (plan.effort.value) |effort_value| if (effort_value.len != 0) {
        try appendSeparator(&output.writer, &has_segment);
        try output.writer.writeAll(effort_value);
    };
    return output.toOwnedSlice();
}

/// Builds bounded, picker-lifetime rows. `metadata` is aligned with `models` and
/// already contains provider-over-catalog merges.
pub fn model(
    allocator: std.mem.Allocator,
    runner: Runner,
    models: []const ai.ModelListing.Model,
    metadata: []const ai.ModelMeta.Metadata,
    current_model: []const u8,
    sort_models: bool,
) !ModelOutcome {
    std.debug.assert(models.len > 1);
    std.debug.assert(models.len == metadata.len);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const order = try temporary.alloc(usize, models.len);
    for (order, 0..) |*destination, index| destination.* = index;
    if (sort_models) std.mem.sort(usize, order, models, lessModelIndex);

    const rows = try temporary.alloc(terminal.Picker.Item, models.len);
    var initial_index: usize = 0;
    for (order, rows, 0..) |source_index, *row, row_index| {
        const facts = metadata[source_index];
        const current = std.mem.eql(u8, models[source_index].id, current_model);
        row.* = .{
            .label = models[source_index].id,
            .description = try modelDescription(temporary, models[source_index], facts),
            .detail = if (models[source_index].metadata.tools == .no) "no tool calling" else null,
            .dim = models[source_index].metadata.tools == .no,
            .current = current,
        };
        if (current) initial_index = row_index;
    }

    const selected = try runner.run("select a model", rows, initial_index) orelse return .canceled;
    std.debug.assert(selected < order.len);
    return .{ .selected = order[selected] };
}

fn lessModelIndex(models: []const ai.ModelListing.Model, left: usize, right: usize) bool {
    return ModelOrder.lessThan({}, models[left].id, models[right].id);
}

fn modelDescription(
    allocator: std.mem.Allocator,
    model_value: ai.ModelListing.Model,
    metadata: ai.ModelMeta.Metadata,
) !?[]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var has_segment = false;
    if (metadata.context_window != 0) {
        try appendSeparator(&output.writer, &has_segment);
        try writeTokenCount(&output.writer, metadata.context_window);
        try output.writer.writeAll(" context");
    }
    if (metadata.image_input == .no) {
        try appendSeparator(&output.writer, &has_segment);
        try output.writer.writeAll("no images");
    }
    if (metadata.rates.input) |input_rate| if (metadata.rates.output) |output_rate| {
        try appendSeparator(&output.writer, &has_segment);
        if (input_rate == 0 and output_rate == 0) {
            try output.writer.writeAll("free");
        } else if (metadata.rates.cache_read) |cache_rate| {
            try output.writer.writeByte('$');
            try writeRate(&output.writer, input_rate);
            try output.writer.writeAll(" in / $");
            try writeRate(&output.writer, cache_rate);
            try output.writer.writeAll(" cached / $");
            try writeRate(&output.writer, output_rate);
            try output.writer.writeAll(" out per Mtok");
        } else {
            try output.writer.writeByte('$');
            try writeRate(&output.writer, input_rate);
            try output.writer.writeAll(" in / $");
            try writeRate(&output.writer, output_rate);
            try output.writer.writeAll(" out per Mtok");
        }
    };
    if (model_value.description) |prose| {
        if (has_segment) try output.writer.writeByte('\n');
        try output.writer.writeAll(prose);
        has_segment = true;
    }
    if (!has_segment) {
        output.deinit();
        return null;
    }
    const owned: []const u8 = try output.toOwnedSlice();
    return owned;
}

fn appendSeparator(writer: *std.Io.Writer, has_segment: *bool) !void {
    if (has_segment.*) try writer.writeAll(" · ");
    has_segment.* = true;
}

fn writeTokenCount(writer: *std.Io.Writer, tokens: u64) !void {
    if (tokens >= 1_000_000) {
        const rounded_tenths = (tokens +| 50_000) / 100_000;
        const whole = rounded_tenths / 10;
        const decimal = rounded_tenths % 10;
        if (decimal == 0) return writer.print("{d}M", .{whole});
        return writer.print("{d}.{d}M", .{ whole, decimal });
    }
    if (tokens >= 1_000) return writer.print("{d}k", .{tokens / 1_000});
    return writer.print("{d}", .{tokens});
}

fn writeRate(writer: *std.Io.Writer, rate: f64) !void {
    if (rate == 0) return writer.writeByte('0');
    var buffer: [64]u8 = undefined;
    const magnitude = @abs(rate);
    const rendered = if (magnitude >= 1_000 or magnitude < 0.0001)
        try std.fmt.bufPrint(&buffer, "{e:.2}", .{rate})
    else if (magnitude >= 100)
        try std.fmt.bufPrint(&buffer, "{d:.0}", .{rate})
    else if (magnitude >= 10)
        try std.fmt.bufPrint(&buffer, "{d:.1}", .{rate})
    else if (magnitude >= 1)
        try std.fmt.bufPrint(&buffer, "{d:.2}", .{rate})
    else if (magnitude >= 0.1)
        try std.fmt.bufPrint(&buffer, "{d:.3}", .{rate})
    else if (magnitude >= 0.01)
        try std.fmt.bufPrint(&buffer, "{d:.4}", .{rate})
    else if (magnitude >= 0.001)
        try std.fmt.bufPrint(&buffer, "{d:.5}", .{rate})
    else
        try std.fmt.bufPrint(&buffer, "{d:.6}", .{rate});
    const exponent = std.mem.findScalar(u8, rendered, 'e');
    var mantissa_end = exponent orelse rendered.len;
    if (std.mem.indexOfScalar(u8, rendered[0..mantissa_end], '.') != null) {
        while (mantissa_end != 0 and rendered[mantissa_end - 1] == '0') mantissa_end -= 1;
        if (mantissa_end != 0 and rendered[mantissa_end - 1] == '.') mantissa_end -= 1;
    }
    try writer.writeAll(rendered[0..mantissa_end]);
    if (exponent) |index| try writer.writeAll(rendered[index..]);
}

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

    const selected = try runner.run(
        "select reasoning effort",
        rows[0 .. @as(usize, levels.count) + 1],
        initial_index,
    ) orelse return .canceled;
    std.debug.assert(selected <= levels.count);
    return .{ .selected = if (selected == 0) null else levels.valueAt(selected - 1) };
}

test "terminal runner forwards clipped-label repetition and defaults it off" {
    const items = [_]terminal.Picker.Item{.{ .label = "row" }};
    const base: TerminalRunner = .{
        .allocator = undefined,
        .io = undefined,
        .stdin = undefined,
        .stdout = undefined,
        .writer = undefined,
        .display_columns = .auto,
        .style = .{},
    };
    try std.testing.expect(!base.pickerOptions("title", &items, 0).repeat_clipped_label);
    var repeating = base;
    repeating.repeat_clipped_label = true;
    try std.testing.expect(repeating.pickerOptions("title", &items, 0).repeat_clipped_label);
}

const FakeRunner = struct {
    selected: ?usize,
    expected_title: []const u8,
    expected_initial: usize,
    valid: bool = false,

    pub fn run(
        self: *FakeRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        self.valid = std.mem.eql(u8, title, self.expected_title) and initial_index == self.expected_initial;
        if (std.mem.eql(u8, title, "select reasoning effort")) {
            self.valid = self.valid and items.len == 4 and
                std.mem.eql(u8, items[0].label, "default") and
                std.mem.eql(u8, items[1].label, "none") and
                std.mem.eql(u8, items[2].label, "low") and
                std.mem.eql(u8, items[3].label, "high");
        }
        return self.selected;
    }
};

test "effort picker keeps default distinct and passes its title" {
    const levels = try ai.Effort.Set.init(&.{ "none", "low", "high" });
    var runner: FakeRunner = .{
        .selected = 1,
        .expected_title = "select reasoning effort",
        .expected_initial = 2,
    };
    const selected = try effort(Runner.from(&runner), &levels, "low");
    try std.testing.expect(runner.valid);
    try std.testing.expectEqualStrings("none", selected.selected.?);
}

test "effort picker cancellation is a no-op result" {
    const levels = try ai.Effort.Set.init(&.{ "none", "low", "high" });
    var runner: FakeRunner = .{
        .selected = null,
        .expected_title = "select reasoning effort",
        .expected_initial = 0,
    };
    try std.testing.expect((try effort(Runner.from(&runner), &levels, null)) == .canceled);
}

const RowRunner = struct {
    selected: ?usize = 0,
    sorted: bool = false,
    rendered: bool = false,

    pub fn run(
        self: *RowRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        self.sorted = std.mem.eql(u8, title, "select a model") and
            std.mem.eql(u8, items[0].label, "gpt-5.4") and
            std.mem.eql(u8, items[1].label, "gpt-5") and initial_index == 1;
        self.rendered = std.mem.eql(
            u8,
            items[0].description.?,
            "1.5M context · no images · $2 in / $0.5 cached / $8 out per Mtok\nnew model",
        ) and items[0].dim and std.mem.eql(u8, items[0].detail.?, "no tool calling");
        return self.selected;
    }
};

fn exerciseModelRows(allocator: std.mem.Allocator) !void {
    const models = [_]ai.ModelListing.Model{
        .{ .id = "gpt-5", .description = "base" },
        .{ .id = "gpt-5.4", .description = "new model", .metadata = .{ .tools = .no } },
    };
    const metadata = [_]ai.ModelMeta.Metadata{
        .{},
        .{
            .context_window = 1_500_000,
            .image_input = .no,
            .rates = .{ .input = 2, .output = 8, .cache_read = 0.5 },
        },
    };
    var runner: RowRunner = .{};
    const selected = model(
        allocator,
        Runner.from(&runner),
        &models,
        &metadata,
        "gpt-5",
        true,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 1), selected.selected);
    try std.testing.expect(runner.sorted);
    try std.testing.expect(runner.rendered);
}

test "model rows sort indexes and render merged hax facts" {
    try exerciseModelRows(std.testing.allocator);
}

const KeepOrderRunner = struct {
    valid: bool = false,

    pub fn run(
        self: *KeepOrderRunner,
        _: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        self.valid = std.mem.eql(u8, items[0].label, "gpt-5") and
            std.mem.eql(u8, items[1].label, "gpt-5.4") and initial_index == 0;
        return 1;
    }
};

test "model rows preserve provider order when sorting is disabled" {
    const models = [_]ai.ModelListing.Model{ .{ .id = "gpt-5" }, .{ .id = "gpt-5.4" } };
    const metadata = [_]ai.ModelMeta.Metadata{ .{}, .{} };
    var runner: KeepOrderRunner = .{};
    const selected = try model(
        std.testing.allocator,
        Runner.from(&runner),
        &models,
        &metadata,
        "gpt-5",
        false,
    );
    try std.testing.expect(runner.valid);
    try std.testing.expectEqual(@as(usize, 1), selected.selected);
}

test "model row numbers round like hax" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeTokenCount(&writer, 1_950_000);
    try writer.writeByte('|');
    try writeRate(&writer, 1.2345);
    try writer.writeByte('|');
    try writeRate(&writer, 1234.5);
    try writer.writeByte('|');
    try writeRate(&writer, 0.00001234);
    try std.testing.expectEqualStrings("2M|1.23|1.23e3|1.23e-5", writer.buffered());
}

test "model row ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseModelRows, .{});
}

const ProviderRowRunner = struct {
    valid: bool = false,

    pub fn run(
        self: *ProviderRowRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        self.valid = std.mem.eql(u8, title, "select a provider") and items.len == 2 and
            std.mem.eql(u8, items[0].label, "Alpha") and items[0].dim and
            std.mem.eql(u8, items[0].detail.?, "offline\x1b[2J") and
            std.mem.eql(u8, items[0].description.?, "id: z-provider") and
            std.mem.eql(u8, items[1].label, "Zulu") and initial_index == 1;
        return 0;
    }
};

const ConfigBudgetSource = struct {
    value: []const u8,

    pub fn inspect(
        self: *ConfigBudgetSource,
        allocator: std.mem.Allocator,
        _: *const config.Settings.Setting,
        _: usize,
    ) !config.Settings.Inspection {
        return .{
            .display = try allocator.dupe(u8, self.value),
            .source = .env,
            .invalid = false,
            .clipped = false,
        };
    }

    pub fn apply(
        _: *ConfigBudgetSource,
        _: std.mem.Allocator,
        _: *const config.Settings.Setting,
        _: config.Settings.Update,
        _: usize,
    ) !ConfigCommand.ApplyResult {
        return .failed;
    }

    pub fn theme(_: *const ConfigBudgetSource) render.Theme {
        return render.Theme.resolve(.{ .configured_theme = "off", .configured_tint = "teal" }) catch unreachable;
    }
};

const ConfigBudgetRunner = struct {
    saw_escaped_control: bool = false,

    pub fn run(
        self: *ConfigBudgetRunner,
        _: []const u8,
        items: []const terminal.Picker.Item,
        _: usize,
    ) !?usize {
        try std.testing.expectEqual(@as(usize, 38), items.len);
        for (items) |item| {
            const detail = item.detail orelse continue;
            try std.testing.expect(std.mem.indexOfScalar(u8, detail, 0x1b) == null);
            if (std.mem.indexOf(u8, detail, "\\x1b") != null) self.saw_escaped_control = true;
        }
        return null;
    }
};

test "config rows retain worst-case bounded details and visibly escape controls" {
    var large: [ConfigCommand.maximum_subject_bytes]u8 = @splat('x');
    large[0] = 0x1b;
    var source: ConfigBudgetSource = .{ .value = &large };
    var runner: ConfigBudgetRunner = .{};
    const outcome = try configSetting(
        std.testing.allocator,
        Runner.from(&runner),
        ConfigCommand.Source.from(&source),
    );
    try std.testing.expect(outcome == .canceled);
    try std.testing.expect(runner.saw_escaped_control);
}

fn exerciseProviderRows(allocator: std.mem.Allocator) !void {
    const choices = [_]ProviderConfig.ProviderChoice{
        .{ .id = "a-provider", .label = "Zulu", .available = true, .reason = null },
        .{ .id = "z-provider", .label = "Alpha", .available = false, .reason = "offline\x1b[2J" },
    };
    var runner: ProviderRowRunner = .{};
    const selected = try provider(allocator, Runner.from(&runner), &choices, "a-provider");
    try std.testing.expect(runner.valid);
    try std.testing.expectEqual(@as(usize, 1), selected.selected);
}

test "provider picker sorts labels and keeps unavailable rows selectable" {
    try exerciseProviderRows(std.testing.allocator);
}

test "provider picker releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseProviderRows, .{});
}

const PresetRowRunner = struct {
    rose: []const u8,
    valid: bool = false,

    pub fn run(
        self: *PresetRowRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        self.valid = std.mem.eql(u8, title, "select a preset") and items.len == 3 and
            std.mem.eql(u8, items[0].label, "alpha") and items[0].dim and
            std.mem.eql(u8, items[0].detail.?, "unknown provider 'missing'") and
            std.mem.eql(u8, items[1].label, "review") and items[1].current and
            std.mem.eql(u8, items[1].description.?, "review code") and
            std.mem.eql(u8, items[1].detail.?, "mock · mock-model · high") and
            std.mem.eql(u8, items[1].label_color.?, self.rose) and
            std.mem.eql(u8, items[2].label, "work") and !items[2].dim and
            std.mem.eql(u8, items[2].detail.?, "custom") and initial_index == 1;
        return 2;
    }
};

fn exercisePresetRows(allocator: std.mem.Allocator) !void {
    const plans = [_]config.Preset.Plan{
        .{
            .name = @constCast("work"),
            .provider = @constCast("custom"),
            .model = .{},
            .effort = .{},
            .system_prompt = .{},
            .system_prompt_append = .{},
            .tint = .{},
            .description = .{},
        },
        .{
            .name = @constCast("alpha"),
            .provider = @constCast("missing"),
            .model = .{},
            .effort = .{},
            .system_prompt = .{},
            .system_prompt_append = .{},
            .tint = .{},
            .description = .{},
        },
        .{
            .name = @constCast("review"),
            .provider = @constCast("mock"),
            .model = .{ .value = @constCast("mock-model") },
            .effort = .{ .value = @constCast("high") },
            .system_prompt = .{},
            .system_prompt_append = .{},
            .tint = .{ .value = @constCast("rose") },
            .description = .{ .value = @constCast("review code") },
        },
    };
    const providers = [_]ProviderConfig.ProviderChoice{.{
        .id = "custom",
        .label = "Custom",
        .available = false,
        .reason = "offline",
    }};
    const base_theme = try render.Theme.resolve(.{
        .configured_theme = "dark",
        .configured_tint = "teal",
    });
    const rose = (try base_theme.withTint("rose")).stance.open;
    var runner: PresetRowRunner = .{ .rose = rose };
    const selected = try preset(
        allocator,
        Runner.from(&runner),
        &plans,
        &providers,
        "review",
        base_theme,
    );
    try std.testing.expect(runner.valid);
    try std.testing.expectEqual(@as(usize, 0), selected.selected);
}

const PresetSavePickerRunner = struct {
    selection: ?usize,
    overwrite_valid: bool = false,
    tint_valid: bool = false,
    expected_initial: usize = 0,
    expected_current: ?usize = null,
    expected_colors: [4]?[]const u8 = @splat(null),

    pub fn run(
        self: *PresetSavePickerRunner,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        if (std.mem.startsWith(u8, title, "preset '")) {
            self.overwrite_valid = std.mem.eql(u8, title, "preset 'review' already exists") and
                items.len == 2 and initial_index == 0 and
                std.mem.eql(u8, items[0].label, "keep it") and items[0].current and
                std.mem.eql(u8, items[0].description.?, "Leave the existing definition alone") and
                std.mem.eql(u8, items[1].label, "overwrite") and
                std.mem.eql(u8, items[1].detail.?, "mock · model · high") and
                std.mem.eql(u8, items[1].description.?, "Replace it with the current selection");
        } else {
            self.tint_valid = std.mem.eql(u8, title, "tint for this preset") and items.len == 5 and
                initial_index == self.expected_initial and
                std.mem.eql(u8, items[0].label, "none") and
                std.mem.eql(u8, items[0].description.?, "Carry no tint of its own: your tint setting applies");
            for (items, 0..) |item, index| {
                const should_be_current = if (self.expected_current) |current| current == index else false;
                self.tint_valid = self.tint_valid and item.current == should_be_current;
                if (index != 0) self.tint_valid = self.tint_valid and
                    std.mem.eql(u8, item.label_color.?, self.expected_colors[index - 1].?);
            }
        }
        return self.selection;
    }
};

test "preset save picker renders exact overwrite rows and maps all outcomes" {
    var runner: PresetSavePickerRunner = .{ .selection = 0 };
    try std.testing.expectEqual(PresetOverwriteOutcome.keep, try presetOverwrite(
        std.testing.allocator,
        Runner.from(&runner),
        "review",
        "mock · model · high",
    ));
    try std.testing.expect(runner.overwrite_valid);
    runner.selection = 1;
    try std.testing.expectEqual(PresetOverwriteOutcome.overwrite, try presetOverwrite(
        std.testing.allocator,
        Runner.from(&runner),
        "review",
        "mock · model · high",
    ));
    runner.selection = null;
    try std.testing.expectEqual(PresetOverwriteOutcome.canceled, try presetOverwrite(
        std.testing.allocator,
        Runner.from(&runner),
        "review",
        "mock · model · high",
    ));
}

test "preset save picker renders tint previews defaults and typed selections" {
    const base = try render.Theme.resolve(.{ .configured_theme = "dark", .configured_tint = "teal" });
    var runner: PresetSavePickerRunner = .{ .selection = 3, .expected_initial = 3, .expected_current = 3 };
    const tint_values = [_]PresetSave.Tint{ .teal, .violet, .rose, .sage };
    for (tint_values, 0..) |tint, index| {
        runner.expected_colors[index] = (try base.withTint(tint.canonical())).stance.open;
    }
    const rose = try presetTint(Runner.from(&runner), base, .{ .selected = .rose });
    try std.testing.expect(runner.tint_valid);
    try std.testing.expectEqual(PresetSave.Tint.rose, rose.selected.?);

    runner.tint_valid = false;
    runner.selection = 0;
    runner.expected_initial = 0;
    runner.expected_current = null;
    const unsupported = try presetTint(Runner.from(&runner), base, .unsupported);
    try std.testing.expect(runner.tint_valid);
    try std.testing.expect(unsupported.selected == null);

    runner.tint_valid = false;
    runner.selection = null;
    runner.expected_current = 0;
    try std.testing.expect((try presetTint(Runner.from(&runner), base, .none)) == .canceled);
    try std.testing.expect(runner.tint_valid);
}

fn exercisePresetSaveOverwriteOom(allocator: std.mem.Allocator) !void {
    var runner: PresetSavePickerRunner = .{ .selection = 0 };
    _ = try presetOverwrite(allocator, Runner.from(&runner), "review", "mock · model · high");
}

test "preset save picker overwrite releases every allocation on OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePresetSaveOverwriteOom,
        .{},
    );
}

test "preset picker renders hax rows and maps sorted indexes" {
    try exercisePresetRows(std.testing.allocator);
}

test "preset picker releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercisePresetRows, .{});
}

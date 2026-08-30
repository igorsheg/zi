const std = @import("std");
const ai = @import("../ai/root.zig");
const render = @import("../render/root.zig");
const text = @import("../text/root.zig");
const DiagnosticText = @import("DiagnosticText.zig");
const Interactive = @import("Interactive.zig");
const RunSelection = @import("RunSelection.zig");
const SelectionPicker = @import("SelectionPicker.zig");
const Slash = @import("Slash.zig");

const bold = "\x1b[1m";
const reset = "\x1b[0m";
const minimum_text_cells: usize = 20;
const stacked_indent: usize = 4;

pub const WidthSource = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque) usize,

    pub fn resolve(self: WidthSource) usize {
        return self.resolve_fn(self.context);
    }

    pub fn from(implementation: anytype) WidthSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("InteractiveCommands.WidthSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(context: *const anyopaque) usize {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.resolve();
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
    }
};

const Shortcut = struct {
    key: []const u8,
    description: []const u8,
};

const shortcuts = [_]Shortcut{
    .{ .key = "enter", .description = "submit prompt" },
    .{ .key = "shift-enter", .description = "insert newline (terminal must be configured to send LF)" },
    .{ .key = "esc", .description = "pause after the current step to steer the model" },
    .{ .key = "esc esc", .description = "interrupt model or running tool immediately" },
    .{ .key = "ctrl-c", .description = "cancel current prompt line" },
    .{ .key = "ctrl-d", .description = "quit (on empty prompt)" },
    .{ .key = "ctrl-l", .description = "clear screen and redraw prompt" },
};

const specs = [_]Slash.Spec{
    .{
        .name = "effort",
        .summary = "set reasoning effort",
        .display = .managed,
        .handler_fn = runEffort,
    },
    .{
        .name = "help",
        .summary = "show this help",
        .handler_fn = runHelp,
    },
};

comptime {
    Slash.assertValidSpecs(&specs);
}

/// Process-lifetime command presentation owner. Every callback borrows this
/// stable address synchronously; no submitted line or frame output is retained.
pub const Owner = struct {
    writer: *std.Io.Writer,
    theme: render.Theme,
    styled: bool,
    columns: usize,
    width_source: ?WidthSource = null,
    frame: ?*render.Frame = null,
    run_selection: ?*RunSelection.Owner = null,
    effort_picker: ?SelectionPicker.Runner = null,

    pub fn init(
        writer: *std.Io.Writer,
        theme: render.Theme,
        styled: bool,
        columns: usize,
    ) Owner {
        return .{
            .writer = writer,
            .theme = theme,
            .styled = styled,
            .columns = @max(columns, 1),
        };
    }

    pub fn setWidthSource(self: *Owner, source: WidthSource) void {
        self.width_source = source;
    }

    pub fn setFrame(self: *Owner, frame: *render.Frame) void {
        self.frame = frame;
    }

    pub fn setRunSelection(self: *Owner, run_selection: *RunSelection.Owner) void {
        self.run_selection = run_selection;
    }

    pub fn setEffortPicker(self: *Owner, picker: SelectionPicker.Runner) void {
        self.effort_picker = picker;
    }

    pub fn gateway(self: *Owner) Interactive.CommandGateway {
        return Interactive.CommandGateway.from(self);
    }

    pub fn classifyCommand(self: *Owner, line: []const u8) Interactive.CommandClassification {
        return switch (Slash.classify(line, &specs)) {
            .prompt => .prompt,
            .command => |command| .{ .command = .{
                .context = self,
                .execute_fn = executeToken,
                .registry_index = command.registry_index,
                .name = command.name,
                .argument = command.argument,
                .usage = switch (command.usage) {
                    .valid => .valid,
                    .unknown => .unknown,
                    .bad_usage => .bad_usage,
                },
            } },
        };
    }

    pub fn executeCommand(
        self: *Owner,
        token: Interactive.CommandToken,
    ) !Interactive.CommandOutcome {
        const outcome = try Slash.execute(.{
            .registry_index = token.registry_index,
            .name = token.name,
            .argument = token.argument,
            .usage = switch (token.usage) {
                .valid => .valid,
                .unknown => .unknown,
                .bad_usage => .bad_usage,
            },
        }, &specs, self, Slash.Output.from(self));
        try self.flush();
        return switch (outcome) {
            .handled => .handled,
            .exit => .exit,
        };
    }

    fn executeToken(
        context: *anyopaque,
        token: Interactive.CommandToken,
    ) anyerror!Interactive.CommandOutcome {
        const self: *Owner = @ptrCast(@alignCast(context));
        return self.executeCommand(token);
    }

    pub fn beginCommandOutput(self: *Owner) !void {
        if (self.frame) |frame| {
            frame.syncExternal(1);
            try frame.openBlock();
        }
    }

    pub fn unknownCommand(self: *Owner, name: []const u8) !void {
        try self.writeStyle(self.theme.error_style.open);
        try self.write("unknown command: /");
        try self.write(name);
        try self.write(". type /help for the list.");
        try self.writeStyle(self.theme.error_style.close);
        try self.write("\n");
    }

    pub fn badCommandUsage(self: *Owner, name: []const u8) !void {
        try self.writeStyle(self.theme.error_style.open);
        try self.write("/");
        try self.write(name);
        try self.write(" takes no arguments.");
        try self.writeStyle(self.theme.error_style.close);
        try self.write("\n");
    }

    fn columnsNow(self: *const Owner) usize {
        return @max(if (self.width_source) |source| source.resolve() else self.columns, 1);
    }

    fn renderHelp(self: *Owner) !void {
        const columns = self.columnsNow();
        var label_width: usize = 0;
        for (specs) |spec| {
            label_width = @max(label_width, 1 + spec.name.len);
            if (spec.alias) |alias| label_width = @max(label_width, 1 + alias.len);
        }
        for (shortcuts) |shortcut| label_width = @max(label_width, shortcut.key.len);
        const description_column = label_width + 4;

        try self.writeHeading("commands");
        for (specs) |spec| {
            var label_buffer: [Slash.maximum_name_bytes + 2]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buffer, "/{s}", .{spec.name});
            try self.writeLabelRow(label, spec.summary, description_column, columns, false);
            if (spec.alias) |alias| {
                var alias_buffer: [Slash.maximum_name_bytes + 2]u8 = undefined;
                const alias_label = try std.fmt.bufPrint(&alias_buffer, "/{s}", .{alias});
                var summary_buffer: [96]u8 = undefined;
                const summary = try std.fmt.bufPrint(&summary_buffer, "alias for /{s}", .{spec.name});
                try self.writeLabelRow(alias_label, summary, description_column, columns, true);
            }
        }

        try self.write("\n");
        try self.writeHeading("shortcuts");
        for (shortcuts) |shortcut| {
            try self.writeLabelRow(shortcut.key, shortcut.description, description_column, columns, false);
        }
    }

    fn writeNote(self: *Owner, message: []const u8) !void {
        try self.writeStyle(self.theme.chrome_dim.open);
        try self.write(message);
        try self.writeStyle(self.theme.chrome_dim.close);
        try self.write("\n");
    }

    fn writeError(self: *Owner, message: []const u8) !void {
        try self.writeStyle(self.theme.error_style.open);
        try self.write(message);
        try self.writeStyle(self.theme.error_style.close);
        try self.write("\n");
    }

    fn writeDiagnosticNote(self: *Owner, message: []const u8) !void {
        var storage: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        DiagnosticText.write(&writer, message) catch {
            return self.writeNote("selection changed (details omitted)");
        };
        try self.writeNote(writer.buffered());
    }

    fn writeHeading(self: *Owner, heading: []const u8) !void {
        if (self.styled) try self.write(bold);
        try self.write(heading);
        if (self.styled) try self.write(reset);
        try self.write("\n");
    }

    fn writeLabelRow(
        self: *Owner,
        label: []const u8,
        description: []const u8,
        description_column: usize,
        columns: usize,
        dimmed: bool,
    ) !void {
        try self.write("  ");
        const label_style = if (dimmed) self.theme.chrome_dim else self.theme.chrome;
        try self.writeStyle(label_style.open);
        try self.write(label);
        try self.writeStyle(label_style.close);

        if (columns -| description_column >= minimum_text_cells) {
            try self.writeSpaces(description_column -| 2 -| label.len);
            try self.writeWrapped(description, description_column, columns, dimmed);
        } else {
            try self.write("\n");
            try self.writeSpaces(stacked_indent);
            try self.writeWrapped(description, stacked_indent, columns, dimmed);
        }
    }

    fn writeWrapped(
        self: *Owner,
        description: []const u8,
        indent: usize,
        columns: usize,
        dimmed: bool,
    ) !void {
        const budget = @max(columns -| indent, 1);
        var remaining = description;
        var first = true;
        while (remaining.len != 0 or first) {
            const split = wrapRow(remaining, budget);
            if (!first) try self.writeSpaces(indent);
            if (dimmed) try self.writeStyle(self.theme.chrome_dim.open);
            try self.write(remaining[0..split.row_end]);
            if (dimmed) try self.writeStyle(self.theme.chrome_dim.close);
            try self.write("\n");
            remaining = remaining[split.next_start..];
            first = false;
        }
    }

    fn writeSpaces(self: *Owner, count: usize) !void {
        var remaining = count;
        const spaces = "                                ";
        while (remaining != 0) {
            const amount = @min(remaining, spaces.len);
            try self.write(spaces[0..amount]);
            remaining -= amount;
        }
    }

    fn writeStyle(self: *Owner, style: []const u8) !void {
        if (self.styled and style.len != 0) try self.write(style);
    }

    fn write(self: *Owner, bytes: []const u8) !void {
        if (self.frame) |frame| return frame.writeAll(bytes);
        return self.writer.writeAll(bytes);
    }

    fn flush(self: *Owner) !void {
        if (self.frame) |frame| return frame.flush();
        return self.writer.flush();
    }
};

fn runEffort(context: *anyopaque, _: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    const live = self.run_selection orelse {
        try self.writeNote("no provider selected — use /provider to choose one first");
        return .handled;
    };
    const current = live.current();
    const levels = current.efforts;
    if (levels.count == 0) {
        var buffer: [256]u8 = undefined;
        try self.writeDiagnosticNote(effortUnavailableMessage(&buffer, current));
        return .handled;
    }

    const picker = self.effort_picker orelse return .handled;
    const choice = SelectionPicker.effort(picker, &levels, current.effort) catch return .handled;
    const selected = switch (choice) {
        .canceled => return .handled,
        .selected => |value| value,
    };
    if (live.current().generation != current.generation) return .handled;
    var candidate = live.prepare(.{
        .model = if (current.preset != null) current.model else null,
        .model_label = current.model_label orelse current.model,
        .effort = selected,
    }) catch {
        try self.writeError("couldn't change reasoning effort — keeping the current selection");
        return .handled;
    };
    defer candidate.deinit();
    live.commit(&candidate);

    const committed = live.current();
    if (committed.effort) |effort_value| {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "switched to {s} · {s} · {s}",
            .{ committed.provider_label, committed.model, effort_value },
        ) catch "switched reasoning effort";
        try self.writeDiagnosticNote(message);
    } else {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "switched to {s} · {s}",
            .{ committed.provider_label, committed.model },
        ) catch "switched to provider-default reasoning effort";
        try self.writeDiagnosticNote(message);
    }
    return .handled;
}

fn effortUnavailableMessage(
    buffer: []u8,
    current: RunSelection.CurrentSelection,
) []const u8 {
    if (current.provider_efforts.count != 0) return std.fmt.bufPrint(
        buffer,
        "{s} doesn't take reasoning-effort levels",
        .{current.model},
    ) catch "this model doesn't take reasoning-effort levels";
    return std.fmt.bufPrint(
        buffer,
        "the {s} provider doesn't expose reasoning-effort levels",
        .{current.provider_label},
    ) catch "the current provider doesn't expose reasoning-effort levels";
}

fn runHelp(context: *anyopaque, _: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    try self.renderHelp();
    return .handled;
}

const RowSplit = struct {
    row_end: usize,
    next_start: usize,
};

fn wrapRow(input: []const u8, budget: usize) RowSplit {
    if (input.len == 0) return .{ .row_end = 0, .next_start = 0 };

    var offset: usize = 0;
    var width: usize = 0;
    var last_space: ?usize = null;
    while (offset < input.len) {
        if (input[offset] == '\n') return .{ .row_end = offset, .next_start = offset + 1 };
        const glyph = text.DisplayWidth.next(input, offset).?;
        if (glyph.is_ascii_space) last_space = offset;
        if (width + glyph.width > budget) {
            if (last_space) |space| return .{
                .row_end = space,
                .next_start = skipSpaces(input, space),
            };
            if (offset == 0) offset += glyph.consumed;
            return .{ .row_end = offset, .next_start = offset };
        }
        width += glyph.width;
        offset += glyph.consumed;
    }
    return .{ .row_end = input.len, .next_start = input.len };
}

fn skipSpaces(input: []const u8, start: usize) usize {
    var offset = start;
    while (offset < input.len and input[offset] == ' ') offset += 1;
    return offset;
}

fn testTheme() !render.Theme {
    return render.Theme.resolve(.{ .configured_theme = "off", .configured_tint = "teal" });
}

fn executeTestCommand(owner: *Owner, line: []const u8) !Interactive.CommandOutcome {
    return switch (owner.classifyCommand(line)) {
        .prompt => error.TestUnexpectedResult,
        .command => |token| token.execute(),
    };
}

test "help lists only implemented commands and supported shortcuts" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);

    try std.testing.expectEqual(Interactive.CommandOutcome.handled, try executeTestCommand(&owner, "/help"));
    try std.testing.expectEqualStrings(
        "commands\n" ++
            "  /effort      set reasoning effort\n" ++
            "  /help        show this help\n" ++
            "\nshortcuts\n" ++
            "  enter        submit prompt\n" ++
            "  shift-enter  insert newline (terminal must be configured to send LF)\n" ++
            "  esc          pause after the current step to steer the model\n" ++
            "  esc esc      interrupt model or running tool immediately\n" ++
            "  ctrl-c       cancel current prompt line\n" ++
            "  ctrl-d       quit (on empty prompt)\n" ++
            "  ctrl-l       clear screen and redraw prompt\n",
        output.written(),
    );
}

test "help stacks descriptions on narrow displays and wraps by cells" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 20);

    _ = try executeTestCommand(&owner, "/help");
    try std.testing.expect(std.mem.find(u8, output.written(), "  /help\n    show this help\n") != null);
    try std.testing.expect(std.mem.find(
        u8,
        output.written(),
        "  shift-enter\n    insert newline\n    (terminal must\n    be configured to\n",
    ) != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b[?1049") == null);
}

test "effort unavailability distinguishes model restrictions from provider vocabulary" {
    var buffer: [256]u8 = undefined;
    var provider_efforts = try ai.Effort.Set.init(&.{"high"});
    const base: RunSelection.CurrentSelection = .{
        .provider = "p",
        .provider_label = "Provider",
        .model = "model-x",
        .model_label = "Model X",
        .effort = null,
        .preset = null,
        .provider_efforts = provider_efforts,
        .efforts = .{},
        .model_metadata = .{},
    };
    try std.testing.expectEqualStrings(
        "model-x doesn't take reasoning-effort levels",
        effortUnavailableMessage(&buffer, base),
    );
    provider_efforts = try ai.Effort.Set.init(&.{});
    var no_provider_levels = base;
    no_provider_levels.provider_efforts = provider_efforts;
    try std.testing.expectEqualStrings(
        "the Provider provider doesn't expose reasoning-effort levels",
        effortUnavailableMessage(&buffer, no_provider_levels),
    );
}

test "selection notices escape terminal controls" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);

    try owner.writeDiagnosticNote("provider\x1b[31m\nmodel");
    try std.testing.expectEqualStrings("provider\\x1b[31m\\nmodel\n", output.written());
}

test "unknown and bad usage diagnostics are exact and safe" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);

    _ = try executeTestCommand(&owner, "/unknown");
    _ = try executeTestCommand(&owner, "/help extra");
    try std.testing.expectEqualStrings(
        "unknown command: /unknown. type /help for the list.\n/help takes no arguments.\n",
        output.written(),
    );
}

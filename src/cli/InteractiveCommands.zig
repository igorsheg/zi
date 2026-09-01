const std = @import("std");
const ai = @import("../ai/root.zig");
const render = @import("../render/root.zig");
const text = @import("../text/root.zig");
const DiagnosticText = @import("DiagnosticText.zig");
const CompactConversation = @import("CompactConversation.zig");
const Interactive = @import("Interactive.zig");
const NewConversation = @import("NewConversation.zig");
const ResumeConversation = @import("ResumeConversation.zig");
const UndoConversation = @import("UndoConversation.zig");
const ProviderConfig = @import("../ProviderConfig.zig");
const RunSelection = @import("RunSelection.zig");
const RunLogSeam = @import("RunLogSeam.zig");
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
        .name = "new",
        .alias = "clear",
        .summary = "start a fresh conversation (optional: preset)",
        .arguments = .optional,
        .handler_fn = runNew,
    },
    .{
        .name = "resume",
        .summary = "resume a previous conversation",
        .handler_fn = runResume,
    },
    .{
        .name = "undo",
        .summary = "revert conversation to before an earlier message (optional: turns back)",
        .arguments = .optional,
        .display = .managed,
        .handler_fn = runUndo,
    },
    .{
        .name = "provider",
        .summary = "switch provider, then model and effort",
        .display = .managed,
        .handler_fn = runProvider,
    },
    .{
        .name = "model",
        .summary = "switch model, then effort",
        .display = .managed,
        .handler_fn = runModel,
    },
    .{
        .name = "effort",
        .summary = "set reasoning effort",
        .display = .managed,
        .handler_fn = runEffort,
    },
    .{
        .name = "compact",
        .summary = "summarize history to free up context (optional: focus instructions)",
        .arguments = .optional,
        .display = .managed,
        .handler_fn = runCompact,
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
    run_log_seam: ?*RunLogSeam.Owner = null,
    io: ?std.Io = null,
    listing_generation: ?Interactive.Generation = null,
    listing_tick: ?ai.Provider.Tick = null,
    selection_picker: ?SelectionPicker.Runner = null,
    new_conversation: ?NewConversation.Runner = null,
    resume_conversation: ?ResumeConversation.Runner = null,
    undo_conversation: ?UndoConversation.Runner = null,
    compact_conversation: ?CompactConversation.Runner = null,
    persistence_warning_written: bool = false,

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

    pub fn setRunLogSeam(self: *Owner, run_log_seam: *RunLogSeam.Owner) void {
        self.run_log_seam = run_log_seam;
    }

    pub fn setIo(self: *Owner, io: std.Io) void {
        self.io = io;
    }

    pub fn setListingCancellation(
        self: *Owner,
        generation: Interactive.Generation,
        tick: ai.Provider.Tick,
    ) void {
        self.listing_generation = generation;
        self.listing_tick = tick;
    }

    pub fn setSelectionPicker(self: *Owner, io: std.Io, picker: SelectionPicker.Runner) void {
        self.io = io;
        self.selection_picker = picker;
    }

    pub fn setNewConversation(self: *Owner, runner: NewConversation.Runner) void {
        self.new_conversation = runner;
    }

    pub fn setResumeConversation(self: *Owner, runner: ResumeConversation.Runner) void {
        self.resume_conversation = runner;
    }

    pub fn setUndoConversation(self: *Owner, runner: UndoConversation.Runner) void {
        self.undo_conversation = runner;
    }

    pub fn setCompactConversation(self: *Owner, runner: CompactConversation.Runner) void {
        self.compact_conversation = runner;
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
            .history_changed => .history_changed,
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

    fn renderNewBanner(self: *Owner, current: RunSelection.CurrentSelection) !void {
        const frame = self.frame orelse return;
        try render.Banner.render(self.writer, self.theme, self.columnsNow(), .{
            .preset = current.preset,
            .provider = current.provider_label,
            .model_label = current.model_label,
            .model = current.model,
            .effort = current.effort,
        });
        frame.syncExternal(1);
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

    fn writeCompactNotice(self: *Owner, message: []const u8) !void {
        try self.beginCommandOutput();
        try self.writeStyle(self.theme.chrome_dim.open);
        try self.write("── ");
        try self.write(message);
        try self.write(" ──");
        try self.writeStyle(self.theme.chrome_dim.close);
        try self.write("\n");
    }

    fn writeError(self: *Owner, message: []const u8) !void {
        try self.writeStyle(self.theme.error_style.open);
        try self.write(message);
        try self.writeStyle(self.theme.error_style.close);
        try self.write("\n");
    }

    fn writeDiagnosticError(self: *Owner, message: []const u8) !void {
        var storage: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        DiagnosticText.write(&writer, message) catch return self.writeError("failed to list models");
        try self.writeError(writer.buffered());
    }

    fn writeProviderUnavailable(self: *Owner, choice: ProviderConfig.ProviderChoice) !void {
        var buffer: [512]u8 = undefined;
        const reason = choice.reason orelse
            if (isLocalProvider(choice.id)) "server not reachable" else "unavailable";
        const message = std.fmt.bufPrint(
            &buffer,
            "{s} is unavailable — {s}",
            .{ choice.label, reason },
        ) catch "that provider is unavailable";
        try self.writeDiagnosticNote(message);
    }

    fn writeProviderListingUnsupported(self: *Owner, choice: ProviderConfig.ProviderChoice) !void {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{s} can't list models — set one with HAX_MODEL or in config",
            .{choice.label},
        ) catch "that provider can't list models — set one with HAX_MODEL or in config";
        try self.writeDiagnosticError(message);
    }

    fn writeProviderNoChoice(
        self: *Owner,
        before: RunSelection.CurrentSelection,
        choice: ProviderConfig.ProviderChoice,
    ) !void {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "staying on {s} — no model chosen for {s}",
            .{ before.provider, choice.id },
        ) catch "no model chosen — keeping the current selection";
        try self.writeDiagnosticNote(message);
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

fn runNew(context: *anyopaque, call: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    const runner = self.new_conversation orelse return .handled;
    const outcome = runner.run(call.argument);
    switch (outcome) {
        .changed => |result| {
            if (result.preset_persistence) |persistence_result| {
                try writePersistenceWarning(self, persistence_result);
            }
            if (result.old_branch_incomplete) {
                try self.writeDiagnosticNote(
                    "the previous conversation was already unrecordable; its final state may be incomplete",
                );
            }
            if (self.frame != null) {
                const live = self.run_selection orelse return .history_changed;
                try self.renderNewBanner(live.current());
            }
            return .history_changed;
        },
        .unchanged => |reason| {
            try writeNewUnchanged(self, call.argument, reason);
            return .handled;
        },
        .partial => |partial| {
            if (partial.preset_persistence) |persistence_result| {
                try writePersistenceWarning(self, persistence_result);
            }
            try writeNewPartial(self, call.argument, partial);
            return .handled;
        },
    }
}

fn runUndo(context: *anyopaque, call: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    const runner = self.undo_conversation orelse return .handled;
    switch (runner.run(call.argument)) {
        .changed => |changed| {
            if (changed.sync_failed) try self.writeError(
                "the session file was truncated but could not be synchronized; recording is uncertain",
            );
            runner.replay();
            return .history_changed;
        },
        .unchanged => |reason| {
            switch (reason) {
                .nothing => try self.writeNote(UndoConversation.nothing_to_undo),
                .needs_number => try self.writeNote(UndoConversation.needs_number),
                .invalid_range => |maximum| {
                    var buffer: [128]u8 = undefined;
                    const message = try std.fmt.bufPrint(
                        &buffer,
                        "/undo takes a number of turns between 1 and {d}",
                        .{maximum},
                    );
                    try self.writeError(message);
                },
                .canceled => {},
                .reconcile_retryable => try self.writeError(
                    "couldn't finish recording the conversation; try /undo again",
                ),
                .reconcile_quarantined => try self.writeError(
                    "the conversation is unrecordable; it was not changed",
                ),
                .preparation => try self.writeError(
                    "couldn't prepare the undo; conversation left unchanged",
                ),
                .disk_unchanged, .disk_indeterminate => try self.writeError(UndoConversation.disk_failure),
            }
            return .handled;
        },
    }
}

fn runResume(context: *anyopaque, _: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    if (self.frame == null) {
        try self.writeNote("/resume requires an interactive terminal");
        return .handled;
    }
    const runner = self.resume_conversation orelse return .handled;
    switch (runner.run()) {
        .changed => |changed| {
            try writeResumeWarnings(self, changed);
            runner.replay();
            return .history_changed;
        },
        .unchanged => |reason| {
            switch (reason) {
                .no_candidates => try self.writeNote("no past conversations in this directory"),
                .canceled => {},
                .could_not_read => try self.writeError("could not read session"),
                .reconcile_retryable => try self.writeError(
                    "couldn't finish recording the current conversation; try /resume again",
                ),
                .reconcile_quarantined => try self.writeError(
                    "the current conversation became unrecordable; it was not resumed",
                ),
                .preparation => try self.writeError("could not read session"),
            }
            return .handled;
        },
        .partial => |reason| {
            switch (reason) {
                .settlement => |settlement| switch (settlement.shutdown) {
                    .partial, .failed => try self.writeError(
                        "couldn't stop every background task; the current conversation was not replaced",
                    ),
                    .no_tasks, .complete => try self.writeError(
                        "couldn't finish the current conversation safely; it was not replaced",
                    ),
                },
                .binding, .publication => try self.writeError(
                    "the conversation changed while /resume was committing; the current history remains active",
                ),
            }
            return .handled;
        },
    }
}

fn writeResumeWarnings(self: *Owner, changed: ResumeConversation.Changed) !void {
    switch (changed.result.selection) {
        .restored => {},
        .core_restored => |outcome| try self.writeDiagnosticNote(switch (outcome) {
            .no_preset => "the session had no recorded preset; restored provider, model, and effort",
            .missing_preset => "the recorded preset is missing; restored provider, model, and effort",
            .invalid_preset => "the recorded preset is invalid; restored provider, model, and effort",
            .mismatched_preset => "the recorded preset no longer matches; restored provider, model, and effort",
            .restored => unreachable,
        }),
        .kept_current => try self.writeDiagnosticNote(
            "couldn't restore the recorded selection; staying on the current provider, model, and effort",
        ),
    }
    switch (changed.result.recording) {
        .appending => {},
        .unrecorded_explicit => try self.writeDiagnosticNote(
            "session recording is disabled; resumed history will not be recorded",
        ),
        .unrecorded_provider_policy => try self.writeDiagnosticNote(
            "the restored provider disables automatic session recording; resumed history will not be recorded",
        ),
        .unrecorded_unavailable => try self.writeDiagnosticNote(
            "could not append to the selected session; resumed history will not be recorded",
        ),
    }
    if (changed.old_branch_incomplete) try self.writeDiagnosticNote(
        "the previous conversation was already unrecordable; its final state may be incomplete",
    );
}

fn runProvider(context: *anyopaque, call: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    const live = self.run_selection orelse return .handled;
    const io = self.io orelse return .handled;
    const picker = self.selection_picker orelse return .handled;
    const before = live.current();

    var choices = live.providerChoices() catch {
        try self.writeError("couldn't prepare the provider list — keeping the current selection");
        return .handled;
    };
    defer choices.deinit();
    if (choices.values.len == 0) {
        try self.writeNote("no providers are configured");
        return .handled;
    }
    const provider_choice = SelectionPicker.provider(
        live.allocator,
        picker,
        choices.values,
        before.provider,
    ) catch return .handled;
    const selected_index = switch (provider_choice) {
        .canceled => return .handled,
        .selected => |index| index,
    };
    if (live.current().generation != before.generation) return .handled;
    const selected_provider = choices.values[selected_index];
    if (!selected_provider.available or isLocalProvider(selected_provider.id)) {
        if (self.listing_generation) |generation| generation.arm() catch return .handled;
        const available = live.recheckProvider(
            io,
            selected_provider.id,
            self.listing_tick,
        ) catch |err| {
            if (self.listing_generation) |generation| try generation.disarm();
            if (err == error.Cancelled) return .handled;
            try self.writeProviderUnavailable(selected_provider);
            return .handled;
        };
        if (self.listing_generation) |generation| try generation.disarm();
        if (!available) {
            try self.writeProviderUnavailable(selected_provider);
            return .handled;
        }
    }
    if (std.mem.eql(u8, selected_provider.id, before.provider)) {
        return runModel(context, call);
    }

    var prospective = live.prepareProviderListing(selected_provider.id) catch {
        try self.writeError("couldn't prepare that provider — keeping the current selection");
        return .handled;
    };
    defer prospective.deinit();
    if (live.current().generation != before.generation) return .handled;

    try self.writeNote("fetching models...");
    if (self.listing_generation) |generation| generation.arm() catch return .handled;
    var listing = prospective.runtime.listModels(
        live.allocator,
        io,
        self.listing_tick,
    ) catch |err| {
        if (self.listing_generation) |generation| try generation.disarm();
        if (err == error.Cancelled) return .handled;
        try self.writeError("couldn't list models for that provider — keeping the current selection");
        return .handled;
    };
    if (self.listing_generation) |generation| try generation.disarm();
    defer listing.deinit();

    var selected_model: ?ai.ModelListing.Model = null;
    var selected_effort: ?[]const u8 = null;
    var effort_selected = true;
    var model_provenance: RunSelection.ModelProvenance = .inherited;
    switch (listing) {
        .unsupported => {
            try self.writeProviderListingUnsupported(selected_provider);
            if (prospective.runtime.defaultModel() == null) {
                try self.writeProviderNoChoice(before, selected_provider);
                return .handled;
            }
            const levels = prospective.runtime.efforts();
            if (levels.count != 0) {
                const effort_choice = SelectionPicker.effort(picker, &levels, null) catch return .handled;
                effort_selected = true;
                selected_effort = switch (effort_choice) {
                    .canceled => return .handled,
                    .selected => |value| value,
                };
            }
        },
        .failure => |failure| {
            try self.writeDiagnosticError(failure.message);
            try self.writeProviderNoChoice(before, selected_provider);
            return .handled;
        },
        .models => |models_owner| {
            const models = models_owner.models;
            if (models.len == 0) {
                try self.writeProviderNoChoice(before, selected_provider);
                return .handled;
            }
            const catalog = live.allocator.alloc(ai.ModelMeta.Metadata, models.len) catch {
                try self.writeError("couldn't prepare the model list — keeping the current selection");
                return .handled;
            };
            defer live.allocator.free(catalog);
            const merged = live.allocator.alloc(ai.ModelMeta.Metadata, models.len) catch {
                try self.writeError("couldn't prepare the model list — keeping the current selection");
                return .handled;
            };
            defer live.allocator.free(merged);
            live.catalogMetadataBatchFor(
                live.allocator,
                prospective.runtime.catalogId(),
                models,
                catalog,
            ) catch {
                try self.writeError("couldn't prepare the model list — keeping the current selection");
                return .handled;
            };
            for (models, merged, catalog) |model_value, *merged_value, *catalog_value| {
                merged_value.* = ai.ModelMeta.merge(&model_value.metadata, catalog_value);
            }
            var model_index: usize = 0;
            if (models.len > 1) {
                const choice = SelectionPicker.model(
                    live.allocator,
                    picker,
                    models,
                    merged,
                    "",
                    prospective.sort_models,
                ) catch return .handled;
                model_index = switch (choice) {
                    .canceled => return .handled,
                    .selected => |index| index,
                };
                model_provenance = .explicit;
            }
            selected_model = models[model_index];
            if (models.len == 1) model_provenance = singletonModelProvenance(
                prospective.runtime.modelDiscovered() or
                    (std.mem.eql(u8, selected_provider.id, "llamacpp") and
                        prospective.runtime.defaultModel() == null),
            );
            const provider_efforts = prospective.runtime.providerEfforts();
            const levels = ai.ModelMeta.resolveEfforts(
                &provider_efforts,
                &selected_model.?.metadata.efforts,
                &catalog[model_index].efforts,
            );
            if (levels.count != 0) {
                const effort_choice = SelectionPicker.effort(picker, &levels, null) catch return .handled;
                effort_selected = true;
                selected_effort = switch (effort_choice) {
                    .canceled => return .handled,
                    .selected => |value| value,
                };
            }
        },
    }
    if (live.current().generation != before.generation) return .handled;

    var candidate = live.prepare(.{
        .provider = selected_provider.id,
        .model = if (selected_model) |model_value| model_value.id else null,
        .model_label = if (selected_model) |model_value| model_value.id else null,
        .effort = selected_effort,
        .reported_metadata = .{ .replace = if (selected_model) |model_value| model_value.metadata else null },
        .model_provenance = model_provenance,
        .effort_selected = effort_selected,
    }) catch {
        try self.writeError("couldn't switch provider — keeping the current selection");
        return .handled;
    };
    defer candidate.deinit();
    try commitAndWarn(self, live, &candidate);
    try writeSelectionNotice(self, live.current());
    return .handled;
}

fn runModel(context: *anyopaque, _: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    const live = self.run_selection orelse {
        try self.writeNote("no provider selected — use /provider to choose one first");
        return .handled;
    };
    const io = self.io orelse return .handled;
    const before = live.current();
    try self.writeNote("fetching models...");
    var listing_armed = false;
    if (self.listing_generation) |generation| {
        generation.arm() catch return .handled;
        listing_armed = true;
    }
    var listing = live.listModels(live.allocator, io, self.listing_tick) catch |err| {
        if (listing_armed) {
            try self.listing_generation.?.disarm();
            listing_armed = false;
        }
        if (err == error.Cancelled) return .handled;
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "failed to list models for {s}",
            .{before.provider_label},
        ) catch "failed to list models for the current provider";
        try self.writeDiagnosticError(message);
        return .handled;
    };
    if (listing_armed) {
        try self.listing_generation.?.disarm();
        listing_armed = false;
    }
    defer listing.deinit();
    switch (listing) {
        .unsupported => {
            var buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buffer,
                "{s} can't list models — set one with HAX_MODEL or in config",
                .{before.provider_label},
            ) catch "the current provider can't list models — set one in config";
            try self.writeDiagnosticNote(message);
            return .handled;
        },
        .failure => |failure| {
            try self.writeDiagnosticError(failure.message);
            return .handled;
        },
        .models => {},
    }
    const models = listing.models.models;
    if (models.len == 0) {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{s} has no models available",
            .{before.provider_label},
        ) catch "the current provider has no models available";
        try self.writeDiagnosticNote(message);
        return .handled;
    }

    const merged = live.allocator.alloc(ai.ModelMeta.Metadata, models.len) catch {
        try self.writeError("couldn't prepare the model list — keeping the current selection");
        return .handled;
    };
    defer live.allocator.free(merged);
    const catalog = live.allocator.alloc(ai.ModelMeta.Metadata, models.len) catch {
        try self.writeError("couldn't prepare the model list — keeping the current selection");
        return .handled;
    };
    defer live.allocator.free(catalog);
    live.catalogMetadataBatch(live.allocator, models, catalog) catch {
        try self.writeError("couldn't prepare the model list — keeping the current selection");
        return .handled;
    };
    for (models, merged, catalog) |model_value, *merged_value, *catalog_value| {
        merged_value.* = ai.ModelMeta.merge(&model_value.metadata, catalog_value);
    }
    if (live.current().generation != before.generation) return .handled;

    var selected_index: usize = 0;
    var provenance: RunSelection.ModelProvenance = .inherited;
    if (models.len > 1) {
        const picker = self.selection_picker orelse return .handled;
        const choice = SelectionPicker.model(
            live.allocator,
            picker,
            models,
            merged,
            before.model,
            before.sort_models,
        ) catch return .handled;
        selected_index = switch (choice) {
            .canceled => return .handled,
            .selected => |index| index,
        };
        provenance = .explicit;
    }
    if (live.current().generation != before.generation) return .handled;

    const selected_model = models[selected_index];
    if (models.len == 1) provenance = singletonModelProvenance(before.model_discovered);
    const levels = ai.ModelMeta.resolveEfforts(
        &before.provider_efforts,
        &selected_model.metadata.efforts,
        &catalog[selected_index].efforts,
    );
    var selected_effort: ?[]const u8 = null;
    var effort_selected = true;
    if (levels.count != 0) {
        const picker = self.selection_picker orelse return .handled;
        const effort_choice = SelectionPicker.effort(picker, &levels, before.effort) catch return .handled;
        effort_selected = true;
        selected_effort = switch (effort_choice) {
            .canceled => return .handled,
            .selected => |value| value,
        };
    }
    if (live.current().generation != before.generation) return .handled;

    var candidate = live.prepare(.{
        .model = selected_model.id,
        .model_label = selected_model.id,
        .effort = selected_effort,
        .reported_metadata = .{ .replace = selected_model.metadata },
        .model_provenance = provenance,
        .effort_selected = effort_selected,
    }) catch {
        try self.writeError("couldn't change model — keeping the current selection");
        return .handled;
    };
    defer candidate.deinit();
    try commitAndWarn(self, live, &candidate);
    try writeSelectionNotice(self, live.current());
    return .handled;
}

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

    const picker = self.selection_picker orelse return .handled;
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
        .model_provenance = if (current.preset != null) .explicit else .inherited,
        .effort_selected = true,
    }) catch {
        try self.writeError("couldn't change reasoning effort — keeping the current selection");
        return .handled;
    };
    defer candidate.deinit();
    try commitAndWarn(self, live, &candidate);

    try writeSelectionNotice(self, live.current());
    return .handled;
}

fn writeNewUnchanged(
    self: *Owner,
    preset: ?[]const u8,
    reason: NewConversation.Unchanged,
) !void {
    switch (reason) {
        .preset => |preset_reason| switch (preset_reason) {
            .missing => try writeNamedPresetError(self, "unknown preset '", preset orelse "", "'"),
            .invalid => try writeNamedPresetError(self, "invalid preset '", preset orelse "", "'"),
            .preparation => try writeNamedPresetError(self, "couldn't apply preset '", preset orelse "", "'"),
        },
        .reconcile_retryable => try self.writeError(
            "couldn't finish recording the current conversation; try /new again",
        ),
        .reconcile_quarantined => try self.writeError(
            "the current conversation became unrecordable; it was not cleared",
        ),
        .preparation => try self.writeError("couldn't prepare a fresh conversation; nothing changed"),
    }
}

fn writeNewPartial(
    self: *Owner,
    preset: ?[]const u8,
    partial: NewConversation.Partial,
) !void {
    if (partial.preset_committed) {
        try writeNamedPresetError(
            self,
            "preset '",
            preset orelse "",
            "' was applied, but the current conversation was not cleared",
        );
    } else switch (partial.cause) {
        .settlement => |settlement| switch (settlement.shutdown) {
            .partial, .failed => try self.writeError(
                "couldn't stop every background task; the current conversation was not cleared",
            ),
            .no_tasks, .complete => try self.writeError(
                "couldn't finish the current conversation safely; it was not cleared",
            ),
        },
        .binding, .publication, .unexpected_preset_publication => try self.writeError(
            "the conversation changed while /new was committing; the current history remains active",
        ),
    }
    if (partial.selection_restore) |restore| switch (restore) {
        .synchronized, .unrecorded => {},
        .retryable => try self.writeError(
            "the preset is active, but recording its metadata is still pending; retry /new before exiting",
        ),
        .quarantined => try self.writeError(
            "the preset is active, but the current conversation is now unrecordable",
        ),
    };
}

fn writeNamedPresetError(
    self: *Owner,
    prefix: []const u8,
    name: []const u8,
    suffix: []const u8,
) !void {
    if (self.styled) try self.writer.writeAll(self.theme.error_style.open);
    try self.writer.writeAll(prefix);
    try DiagnosticText.write(self.writer, name);
    try self.writer.writeAll(suffix);
    if (self.styled) try self.writer.writeAll(self.theme.error_style.close);
    try self.writer.writeByte('\n');
    if (self.frame) |frame| frame.syncExternal(1);
}

fn isLocalProvider(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "llamacpp") or std.mem.eql(u8, provider_id, "ollama");
}

fn singletonModelProvenance(discovered: bool) RunSelection.ModelProvenance {
    return if (discovered) .discovered else .concrete;
}

fn commitAndWarn(
    self: *Owner,
    live: *RunSelection.Owner,
    candidate: *RunSelection.Candidate,
) !void {
    const result = live.commit(candidate);
    if (self.run_log_seam) |seam| seam.rebuildTranscript(.selection, live.session);
    try writePersistenceWarning(self, result);
}

fn writePersistenceWarning(self: *Owner, result: RunSelection.CommitResult) !void {
    if (result != .run_only or self.persistence_warning_written) return;
    self.persistence_warning_written = true;
    try self.writeDiagnosticNote("couldn't save to state.json — this choice applies to this run only");
}

fn writeSelectionNotice(self: *Owner, committed: RunSelection.CurrentSelection) !void {
    if (committed.effort) |effort_value| {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "switched to {s} · {s} · {s}",
            .{ committed.provider_label, committed.model, effort_value },
        ) catch "switched selection";
        return self.writeDiagnosticNote(message);
    }
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "switched to {s} · {s}",
        .{ committed.provider_label, committed.model },
    ) catch "switched selection";
    return self.writeDiagnosticNote(message);
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

fn runCompact(context: *anyopaque, call: Slash.Call) anyerror!Slash.HandlerOutcome {
    const self: *Owner = @ptrCast(@alignCast(context));
    const runner = self.compact_conversation orelse return .handled;
    var result = runner.run(call.argument);
    defer result.deinit();

    switch (result.outcome) {
        .no_provider => try self.writeCompactNotice(CompactConversation.no_provider),
        .no_model => try self.writeCompactNotice(CompactConversation.no_model),
        .empty => try self.writeCompactNotice(CompactConversation.nothing),
        .compacted => try self.writeCompactNotice("conversation compacted"),
        .cancelled => try self.writeCompactNotice("compaction cancelled"),
        .no_summary => try self.writeCompactNotice("compaction produced no summary"),
        .provider_failure => failure: {
            var storage: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            writer.writeAll("compaction failed: ") catch unreachable;
            DiagnosticText.write(&writer, result.diagnostic orelse "stream failed") catch {
                try self.writeCompactNotice("compaction failed: stream failed");
                break :failure;
            };
            try self.writeCompactNotice(writer.buffered());
        },
    }
    if (result.issue.usage_observer_failed) try self.writeError(
        "compaction usage was recorded in history but could not be added to usage totals",
    );
    switch (result.issue.durability) {
        .failed => try self.writeError("compaction history changed but could not be recorded"),
        .indeterminate => try self.writeError("compaction history changed and recording is uncertain"),
        .not_attempted, .synchronized, .unrecorded => {},
    }
    if (result.issue.activity_failed) {
        try self.writeError("compaction finished but terminal activity cleanup failed");
        return error.ActivityCleanupFailed;
    }
    return if (result.mutation == .seed_committed) .history_changed else .handled;
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

const FakeResumeRunner = struct {
    outcome: ResumeConversation.Outcome,
    calls: usize = 0,
    replay_calls: usize = 0,
    replay_writer: ?*std.Io.Writer = null,

    pub fn run(self: *FakeResumeRunner) ResumeConversation.Outcome {
        self.calls += 1;
        return self.outcome;
    }

    pub fn replay(self: *FakeResumeRunner) void {
        self.replay_calls += 1;
        if (self.replay_writer) |writer| writer.writeAll("replay\n") catch unreachable;
    }
};

const FakeUndoRunner = struct {
    outcome: UndoConversation.Outcome,
    calls: usize = 0,
    replay_calls: usize = 0,
    argument: ?[]const u8 = null,
    replay_writer: ?*std.Io.Writer = null,

    pub fn run(self: *FakeUndoRunner, argument: ?[]const u8) UndoConversation.Outcome {
        self.calls += 1;
        self.argument = argument;
        return self.outcome;
    }

    pub fn replay(self: *FakeUndoRunner) void {
        self.replay_calls += 1;
        if (self.replay_writer) |writer| writer.writeAll("replay\n") catch unreachable;
    }
};

const FakeNewRunner = struct {
    outcome: NewConversation.Outcome,
    calls: usize = 0,
    argument: ?[]const u8 = null,

    pub fn run(self: *FakeNewRunner, argument: ?[]const u8) NewConversation.Outcome {
        self.calls += 1;
        self.argument = argument;
        return self.outcome;
    }
};

const FakeCompactRunner = struct {
    result: CompactConversation.Result,
    calls: usize = 0,
    focus: ?[]const u8 = null,

    pub fn run(self: *FakeCompactRunner, focus: ?[]const u8) CompactConversation.Result {
        self.calls += 1;
        self.focus = focus;
        return self.result;
    }
};

fn compactResult(outcome: CompactConversation.Outcome) CompactConversation.Result {
    return .{ .allocator = std.testing.allocator, .outcome = outcome };
}

test "resume rejects arguments and cooked mode never invokes its runner" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);
    var runner: FakeResumeRunner = .{ .outcome = .{ .unchanged = .canceled } };
    owner.setResumeConversation(ResumeConversation.Runner.from(&runner));

    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/resume extra"));
    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/resume"));
    try std.testing.expectEqual(@as(usize, 0), runner.calls);
    try std.testing.expectEqualStrings(
        "/resume takes no arguments.\n/resume requires an interactive terminal\n",
        output.written(),
    );
}

test "resume writes selection and recording warnings before advisory replay" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame = render.Frame.init(&output.writer);
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);
    owner.setFrame(&frame);
    var runner: FakeResumeRunner = .{
        .outcome = .{ .changed = .{
            .result = .{
                .selection = .{ .core_restored = .missing_preset },
                .recording = .unrecorded_unavailable,
            },
            .old_branch_incomplete = false,
        } },
        .replay_writer = &output.writer,
    };
    owner.setResumeConversation(ResumeConversation.Runner.from(&runner));

    try std.testing.expectEqual(.history_changed, try executeTestCommand(&owner, "/resume"));
    try std.testing.expectEqual(@as(usize, 1), runner.calls);
    try std.testing.expectEqual(@as(usize, 1), runner.replay_calls);
    try std.testing.expectEqualStrings(
        "\nthe recorded preset is missing; restored provider, model, and effort\n" ++
            "could not append to the selected session; resumed history will not be recorded\n" ++
            "replay\n",
        output.written(),
    );
}

test "undo forwards optional numbers and maps only committed cuts to history changes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);
    var runner: FakeUndoRunner = .{ .outcome = .{ .unchanged = .needs_number } };
    owner.setUndoConversation(UndoConversation.Runner.from(&runner));

    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/undo"));
    try std.testing.expectEqualStrings(
        "/undo needs a number of turns when not interactive\n",
        output.written(),
    );
    output.clearRetainingCapacity();
    runner.outcome = .{ .unchanged = .{ .invalid_range = 3 } };
    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/undo  2x"));
    try std.testing.expectEqualStrings("2x", runner.argument.?);
    try std.testing.expectEqualStrings(
        "/undo takes a number of turns between 1 and 3\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    runner.outcome = .{ .changed = .{
        .result = .{ .removed_turns = 2, .effect = .{
            .old_context_floor = 0,
            .new_context_floor = 0,
            .invalidates_context = true,
        } },
        .sync_failed = false,
    } };
    runner.replay_writer = &output.writer;
    try std.testing.expectEqual(.history_changed, try executeTestCommand(&owner, "/undo 2"));
    try std.testing.expectEqualStrings("2", runner.argument.?);
    try std.testing.expectEqualStrings("replay\n", output.written());
    try std.testing.expectEqual(@as(usize, 1), runner.replay_calls);

    output.clearRetainingCapacity();
    runner.outcome.changed.sync_failed = true;
    try std.testing.expectEqual(.history_changed, try executeTestCommand(&owner, "/undo 1"));
    try std.testing.expectEqualStrings(
        "the session file was truncated but could not be synchronized; recording is uncertain\n" ++
            "replay\n",
        output.written(),
    );
}

test "undo reports disk failure before any advisory replay" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);
    var runner: FakeUndoRunner = .{
        .outcome = .{ .unchanged = .{ .disk_indeterminate = .changed } },
        .replay_writer = &output.writer,
    };
    owner.setUndoConversation(UndoConversation.Runner.from(&runner));

    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/undo 1"));
    try std.testing.expectEqualStrings(UndoConversation.disk_failure ++ "\n", output.written());
    try std.testing.expectEqual(@as(usize, 0), runner.replay_calls);
}

test "compact forwards optional focus and renders one exact product outcome" {
    const cases = [_]struct { CompactConversation.Outcome, []const u8 }{
        .{ .no_provider, "── " ++ CompactConversation.no_provider ++ " ──\n" },
        .{ .no_model, "── " ++ CompactConversation.no_model ++ " ──\n" },
        .{ .empty, "── " ++ CompactConversation.nothing ++ " ──\n" },
        .{ .compacted, "── conversation compacted ──\n" },
        .{ .cancelled, "── compaction cancelled ──\n" },
        .{ .provider_failure, "── compaction failed: stream failed ──\n" },
        .{ .no_summary, "── compaction produced no summary ──\n" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var owner = Owner.init(&output.writer, try testTheme(), false, 100);
        var runner: FakeCompactRunner = .{ .result = compactResult(case[0]) };
        owner.setCompactConversation(CompactConversation.Runner.from(&runner));

        const expected_outcome: Interactive.CommandOutcome = if (case[0] == .compacted) blk: {
            runner.result.mutation = .seed_committed;
            break :blk .history_changed;
        } else .handled;
        try std.testing.expectEqual(expected_outcome, try executeTestCommand(&owner, "/compact keep paths"));
        try std.testing.expectEqualStrings("keep paths", runner.focus.?);
        try std.testing.expectEqualStrings(case[1], output.written());
    }
}

test "compact bounds oversized escaped provider diagnostics" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 100);
    var diagnostic: [5000]u8 = undefined;
    @memset(&diagnostic, 0);
    var runner: FakeCompactRunner = .{ .result = compactResult(.provider_failure) };
    runner.result.diagnostic = &diagnostic;
    owner.setCompactConversation(CompactConversation.Runner.from(&runner));

    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/compact"));
    try std.testing.expectEqualStrings(
        "── compaction failed: stream failed ──\n",
        output.written(),
    );
}

test "compact keeps seed success while rendering observer and durability warnings" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 100);
    var runner: FakeCompactRunner = .{ .result = compactResult(.compacted) };
    runner.result.mutation = .seed_committed;
    runner.result.issue = .{ .usage_observer_failed = true, .durability = .indeterminate };
    owner.setCompactConversation(CompactConversation.Runner.from(&runner));

    try std.testing.expectEqual(.history_changed, try executeTestCommand(&owner, "/compact"));
    try std.testing.expectEqualStrings(
        "── conversation compacted ──\n" ++
            "compaction usage was recorded in history but could not be added to usage totals\n" ++
            "compaction history changed and recording is uncertain\n",
        output.written(),
    );
}

test "new and clear forward optional presets and map only changed history" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);
    var runner: FakeNewRunner = .{ .outcome = .{ .changed = .{} } };
    owner.setNewConversation(NewConversation.Runner.from(&runner));

    try std.testing.expectEqual(.history_changed, try executeTestCommand(&owner, "/clear review"));
    try std.testing.expectEqualStrings("review", runner.argument.?);
    runner.outcome = .{ .unchanged = .{ .preparation = error.OutOfMemory } };
    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/new"));
    try std.testing.expect(runner.argument == null);
    try std.testing.expectEqual(@as(usize, 2), runner.calls);
}

test "new preset diagnostics escape names and report committed partial state" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);
    var runner: FakeNewRunner = .{ .outcome = .{ .unchanged = .{ .preset = .missing } } };
    owner.setNewConversation(NewConversation.Runner.from(&runner));

    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/new bad\x1b[2J"));
    try std.testing.expectEqualStrings("unknown preset 'bad\\x1b[2J'\n", output.written());
    output.clearRetainingCapacity();
    runner.outcome = .{ .partial = .{
        .cause = .unexpected_preset_publication,
        .preset_committed = true,
        .preset_persistence = .run_only,
        .selection_restore = .{ .retryable = .io_retryable },
    } };
    try std.testing.expectEqual(.handled, try executeTestCommand(&owner, "/new review"));
    try std.testing.expectEqualStrings(
        "couldn't save to state.json — this choice applies to this run only\n" ++
            "preset 'review' was applied, but the current conversation was not cleared\n" ++
            "the preset is active, but recording its metadata is still pending; " ++
            "retry /new before exiting\n",
        output.written(),
    );
}

test "fresh banner uses current selection and synchronizes the bound frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame = render.Frame.init(&output.writer);
    var owner = Owner.init(&output.writer, try testTheme(), true, 80);
    owner.setFrame(&frame);
    const empty_efforts = try ai.Effort.Set.init(&.{});

    try owner.renderNewBanner(.{
        .provider = "provider-id",
        .provider_label = "Provider",
        .model = "model-id",
        .model_label = "Model",
        .effort = "high",
        .preset = "review",
        .provider_efforts = empty_efforts,
        .efforts = empty_efforts,
        .model_metadata = .{},
    });

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "[review]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "› Provider · Model · high") != null);
    try std.testing.expectEqual(@as(u2, 1), frame.trailing_newlines);
}

test "help lists only implemented commands and supported shortcuts" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);

    try std.testing.expectEqual(Interactive.CommandOutcome.handled, try executeTestCommand(&owner, "/help"));
    try std.testing.expectEqualStrings(
        "commands\n" ++
            "  /new         start a fresh conversation (optional: preset)\n" ++
            "  /clear       alias for /new\n" ++
            "  /resume      resume a previous conversation\n" ++
            "  /undo        revert conversation to before an earlier message (optional: turns\n" ++
            "               back)\n" ++
            "  /provider    switch provider, then model and effort\n" ++
            "  /model       switch model, then effort\n" ++
            "  /effort      set reasoning effort\n" ++
            "  /compact     summarize history to free up context (optional: focus\n" ++
            "               instructions)\n" ++
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
    try owner.writeDiagnosticError("failure\x1b[2J\rhidden");
    try std.testing.expectEqualStrings(
        "provider\\x1b[31m\\nmodel\nfailure\\x1b[2J\\rhidden\n",
        output.written(),
    );
}

test "singleton provenance distinguishes reconciled discoveries" {
    try std.testing.expectEqual(
        RunSelection.ModelProvenance.concrete,
        singletonModelProvenance(false),
    );
    try std.testing.expectEqual(
        RunSelection.ModelProvenance.discovered,
        singletonModelProvenance(true),
    );
}

test "run-only persistence warning uses hax text once per process owner" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var owner = Owner.init(&output.writer, try testTheme(), false, 80);

    try writePersistenceWarning(&owner, .written);
    try writePersistenceWarning(&owner, .run_only);
    try writePersistenceWarning(&owner, .run_only);
    try std.testing.expectEqualStrings(
        "couldn't save to state.json — this choice applies to this run only\n",
        output.written(),
    );
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

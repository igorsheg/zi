const std = @import("std");

pub const HelpSection = enum {
    run_options,
    actions,

    pub fn title(self: HelpSection) []const u8 {
        return switch (self) {
            .run_options => "Run options",
            .actions => "Actions",
        };
    }
};

pub const FlagId = enum {
    print_mode,
    mode,
    continue_session,
    resume_picker,
    session_ref,
    model_id,
    api_key,
    no_session,
    tools_filter,
    append_system_prompt,
    list_models,
    docs,
    man,
    help,
    version,
};

pub const ValueKind = enum {
    none,
    required,
};

pub const FlagSpec = struct {
    id: FlagId,
    long: []const u8,
    short: ?u8 = null,
    value_kind: ValueKind = .none,
    help_suffix: []const u8 = "",
    description: []const u8,
    actions: ActionSet,
    section: ?HelpSection = null,

    pub fn matches(self: FlagSpec, arg: []const u8) bool {
        if (arg.len == self.long.len + 2 and std.mem.eql(u8, arg[0..2], "--") and std.mem.eql(u8, arg[2..], self.long)) {
            return true;
        }
        if (self.short) |short| {
            return arg.len == 2 and arg[0] == '-' and arg[1] == short;
        }
        return false;
    }

    pub fn labelLen(self: FlagSpec) usize {
        const base_len = if (self.short != null)
            @as(usize, 2 + 4 + self.long.len)
        else
            @as(usize, 2 + self.long.len);
        return base_len + self.help_suffix.len;
    }

    pub fn writeLabel(self: FlagSpec, writer: anytype) !void {
        if (self.short) |short| {
            try writer.print("-{c}, --{s}{s}", .{ short, self.long, self.help_suffix });
            return;
        }
        try writer.print("--{s}{s}", .{ self.long, self.help_suffix });
    }
};

const ActionSet = struct {
    run: bool = false,
    help: bool = false,
    version: bool = false,
    list_models: bool = false,
    docs: bool = false,
    man: bool = false,

    fn contains(self: ActionSet, action: ActionScope) bool {
        return switch (action) {
            .run => self.run,
            .help => self.help,
            .version => self.version,
            .list_models => self.list_models,
            .docs => self.docs,
            .man => self.man,
        };
    }
};

pub const ActionScope = enum {
    run,
    help,
    version,
    list_models,
    docs,
    man,
};

pub const UtilityAction = enum {
    help,
    version,
    list_models,
    docs,
    man,
};

pub const all_flags = [_]FlagSpec{
    .{
        .id = .print_mode,
        .long = "print",
        .short = 'p',
        .description = "Select batch text mode; prints the final assistant text only",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .mode,
        .long = "mode",
        .value_kind = .required,
        .help_suffix = " <text|json>",
        .description = "Select batch output mode; JSON emits a session header then event lines",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .continue_session,
        .long = "continue",
        .short = 'c',
        .description = "Resume the most recent session for this project",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .resume_picker,
        .long = "resume",
        .short = 'r',
        .description = "Open the interactive session picker",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .session_ref,
        .long = "session",
        .value_kind = .required,
        .help_suffix = " <path|id>",
        .description = "Resume a specific session by path or ID prefix",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .model_id,
        .long = "model",
        .value_kind = .required,
        .help_suffix = " <id>",
        .description = "Model ID or pattern",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .api_key,
        .long = "api-key",
        .value_kind = .required,
        .help_suffix = " <key>",
        .description = "API key override",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .no_session,
        .long = "no-session",
        .description = "Disable session persistence for the startup session",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .tools_filter,
        .long = "tools",
        .value_kind = .required,
        .help_suffix = " <filter>",
        .description = "Comma-separated list of allowed tools",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .append_system_prompt,
        .long = "append-system-prompt",
        .value_kind = .required,
        .help_suffix = " <text|path>",
        .description = "Append literal text or file contents to the system prompt",
        .actions = .{ .run = true },
        .section = .run_options,
    },
    .{
        .id = .docs,
        .long = "docs",
        .value_kind = .required,
        .help_suffix = " <query>",
        .description = "Search embedded zi documentation",
        .actions = .{ .docs = true },
        .section = .actions,
    },
    .{
        .id = .man,
        .long = "man",
        .help_suffix = " [topic]",
        .description = "Print embedded zi documentation topics",
        .actions = .{ .man = true },
        .section = .actions,
    },
    .{
        .id = .list_models,
        .long = "list-models",
        .help_suffix = " [search]",
        .description = "List available models (optional fuzzy search)",
        .actions = .{ .list_models = true },
        .section = .actions,
    },
    .{
        .id = .help,
        .long = "help",
        .short = 'h',
        .description = "Show help",
        .actions = .{ .help = true, .list_models = true },
        .section = .actions,
    },
    .{
        .id = .version,
        .long = "version",
        .short = 'v',
        .description = "Show version",
        .actions = .{ .version = true },
        .section = .actions,
    },
};

pub fn findForAction(action: ActionScope, arg: []const u8) ?*const FlagSpec {
    for (&all_flags) |*flag| {
        if (flag.actions.contains(action) and flag.matches(arg)) return flag;
    }
    return null;
}

pub fn utilityActionForArg(arg: []const u8) ?UtilityAction {
    if (findForAction(.version, arg) != null) return .version;
    if (findForAction(.list_models, arg)) |flag| {
        if (flag.id == .list_models) return .list_models;
    }
    if (findForAction(.docs, arg)) |flag| {
        if (flag.id == .docs) return .docs;
    }
    if (findForAction(.man, arg)) |flag| {
        if (flag.id == .man) return .man;
    }
    if (findForAction(.help, arg) != null) return .help;
    return null;
}

pub fn writeHelpSection(writer: anytype, section: HelpSection) !void {
    try writer.print("{s}:\n", .{section.title()});

    const width = maxLabelLen(section);
    for (all_flags) |flag| {
        if (flag.section != section) continue;

        try writer.writeAll("  ");
        try flag.writeLabel(writer);

        var lines = std.mem.splitScalar(u8, flag.description, '\n');
        if (lines.next()) |first_line| {
            try writePadding(writer, width - flag.labelLen() + 2);
            try writer.writeAll(first_line);
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("\n");
        }

        while (lines.next()) |line| {
            try writer.writeAll("  ");
            try writePadding(writer, width + 2);
            try writer.writeAll(line);
            try writer.writeAll("\n");
        }
    }

    try writer.writeAll("\n");
}

fn maxLabelLen(section: HelpSection) usize {
    var max_len: usize = 0;
    for (all_flags) |flag| {
        if (flag.section != section) continue;
        max_len = @max(max_len, flag.labelLen());
    }
    return max_len;
}

fn writePadding(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

test "flag lookup is action-scoped and help rendering stays aligned" {
    const print_flag = findForAction(.run, "-p") orelse return error.MissingFlag;
    try std.testing.expectEqual(FlagId.print_mode, print_flag.id);
    try std.testing.expect(findForAction(.run, "--list-models") == null);
    try std.testing.expectEqual(FlagId.list_models, (findForAction(.list_models, "--list-models") orelse return error.MissingFlag).id);
    try std.testing.expectEqual(UtilityAction.help, utilityActionForArg("--help").?);
    try std.testing.expectEqual(UtilityAction.list_models, utilityActionForArg("--list-models").?);
    try std.testing.expectEqual(UtilityAction.version, utilityActionForArg("-v").?);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeHelpSection(&out.writer, .run_options);
    try writeHelpSection(&out.writer, .actions);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "--append-system-prompt <text|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--list-models [search]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-h, --help") != null);
}

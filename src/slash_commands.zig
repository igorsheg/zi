const std = @import("std");

/// What happens when a slash command is executed.
pub const CommandAction = union(enum) {
    /// Built-in command: direct function call on main thread.
    builtin: *const fn (args: []const u8, ctx: *CommandContext) anyerror!void,
    /// Extension-registered command: function + user context.
    extension: struct {
        handler: *const fn (args: []const u8, ctx: *CommandContext, user_ctx: ?*anyopaque) anyerror!void,
        user_ctx: ?*anyopaque = null,
    },
    /// Prompt template: text expanded and sent to LLM.
    prompt_template,
    /// Skill: expanded with skill: prefix.
    skill,
};

/// Opaque context passed to command handlers.
/// Will be filled in when we wire up interactive mode.
pub const CommandContext = struct {
    /// Placeholder — will hold references to session, agent, UI, etc.
    _reserved: ?*anyopaque = null,
};

pub const Source = enum {
    builtin,
    extension,
    prompt,
    skill,
};

/// A slash command entry in the registry.
pub const SlashCommand = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    source: Source,
    action: CommandAction,
};

fn stubHandler(_: []const u8, _: *CommandContext) anyerror!void {}

/// Matches pi-mono's BUILTIN_SLASH_COMMANDS (packages/coding-agent/src/core/slash-commands.ts)
pub const BUILTIN_COMMANDS = [_]SlashCommand{
    .{ .name = "model", .description = "Select model", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "compact", .description = "Compact session context", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "new", .description = "Start a new session", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "clear", .description = "Clear conversation", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "quit", .description = "Quit zi", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "resume", .description = "Resume a different session", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "fork", .description = "Create a new fork from a previous message", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "tree", .description = "Navigate session tree", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "export", .description = "Export session", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "import", .description = "Import and resume a session from a JSONL file", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "copy", .description = "Copy last agent message to clipboard", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "name", .description = "Set session display name", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "session", .description = "Show session info and stats", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "mem", .description = "Write memory diagnostics to disk", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "hotkeys", .description = "Show all keyboard shortcuts", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "settings", .description = "Open settings menu", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "login", .description = "Login with OAuth provider", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "logout", .description = "Logout from OAuth provider", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "reload", .description = "Reload keybindings, extensions, skills, prompts, and themes", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "share", .description = "Share session as a secret GitHub gist", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "changelog", .description = "Show changelog entries", .source = .builtin, .action = .{ .builtin = &stubHandler } },
    .{ .name = "scoped-models", .description = "Enable/disable models for Ctrl+P cycling", .source = .builtin, .action = .{ .builtin = &stubHandler } },
};

/// Owns the dynamic set of slash commands.
/// Main-thread owned — no synchronization needed.
/// Built-in commands are static (comptime). Dynamic commands come from
/// extensions, prompts, and skills at runtime.
pub const CommandRegistry = struct {
    builtins: []const SlashCommand,
    dynamic: std.ArrayListUnmanaged(SlashCommand) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return .{
            .builtins = &BUILTIN_COMMANDS,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.dynamic.deinit(self.allocator);
    }

    /// Register a dynamic command (extension/prompt/skill).
    pub fn register(self: *CommandRegistry, cmd: SlashCommand) void {
        self.dynamic.append(self.allocator, cmd) catch return;
    }

    /// Unregister a dynamic command by name. Returns true if found and removed.
    pub fn unregister(self: *CommandRegistry, name: []const u8) bool {
        for (self.dynamic.items, 0..) |_, i| {
            if (std.mem.eql(u8, self.dynamic.items[i].name, name)) {
                _ = self.dynamic.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Total command count (builtins + dynamic).
    pub fn count(self: *const CommandRegistry) usize {
        return self.builtins.len + self.dynamic.items.len;
    }

    /// Find a command by name. Checks builtins first, then dynamic.
    pub fn findCommand(self: *const CommandRegistry, name: []const u8) ?*const SlashCommand {
        for (self.builtins) |*cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
        }
        for (self.dynamic.items) |*cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
        }
        return null;
    }
};

test "CommandRegistry finds builtin commands" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const quit = reg.findCommand("quit");
    try std.testing.expect(quit != null);
    try std.testing.expectEqualStrings("quit", quit.?.name);
    try std.testing.expectEqualStrings("Quit zi", quit.?.description.?);

    try std.testing.expect(reg.findCommand("nonexistent") == null);
}

test "CommandRegistry register and unregister dynamic" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    reg.register(.{
        .name = "myplugin",
        .description = "A test plugin",
        .source = .extension,
        .action = .prompt_template,
    });

    const found = reg.findCommand("myplugin");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("myplugin", found.?.name);

    try std.testing.expect(reg.unregister("myplugin"));
    try std.testing.expect(reg.findCommand("myplugin") == null);
    try std.testing.expect(!reg.unregister("myplugin"));
}

test "CommandRegistry count includes both" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, BUILTIN_COMMANDS.len), reg.count());

    reg.register(.{ .name = "extra", .source = .skill, .action = .skill });
    try std.testing.expectEqual(@as(usize, BUILTIN_COMMANDS.len + 1), reg.count());
}

test "CommandRegistry builtin takes precedence" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    reg.register(.{
        .name = "quit",
        .description = "Shadow quit",
        .source = .extension,
        .action = .prompt_template,
    });

    const found = reg.findCommand("quit").?;
    try std.testing.expectEqual(Source.builtin, found.source);
    try std.testing.expectEqualStrings("Quit zi", found.description.?);
}

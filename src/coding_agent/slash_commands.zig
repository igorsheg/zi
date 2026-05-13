const std = @import("std");

pub const CommandAction = union(enum) {
    builtin: *const fn (args: []const u8, ctx: *CommandContext) anyerror!void,

    extension: void,

    prompt_template,

    skill,
};

pub const CommandContext = struct {
    _reserved: ?*anyopaque = null,
};

pub const Source = enum {
    builtin,
    extension,
    prompt,
    skill,
};

pub const SlashCommand = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    source: Source,
    action: CommandAction,
};

fn builtinMarker(_: []const u8, _: *CommandContext) anyerror!void {}

pub const BUILTIN_COMMANDS = [_]SlashCommand{
    .{ .name = "model", .description = "Select model", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "compact", .description = "Compact session context", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "new", .description = "Start a new session", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "clear", .description = "Clear conversation", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "quit", .description = "Quit zi", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "resume", .description = "Resume a different session", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "fork", .description = "Create a new fork from a previous message", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "tree", .description = "Navigate session tree", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "export", .description = "Export session", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "import", .description = "Import and resume a session from a JSONL file", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "copy", .description = "Copy last agent message to clipboard", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "name", .description = "Set session display name", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "session", .description = "Show session info and stats", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "hotkeys", .description = "Show all keyboard shortcuts", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "memory", .description = "Show memory telemetry", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "logs", .description = "Show log path or write a log snapshot", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "settings", .description = "Open settings menu", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "login", .description = "Login with OAuth provider", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "logout", .description = "Logout from OAuth provider", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "reload", .description = "Reload keybindings, extensions, skills, prompts, and themes", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "share", .description = "Share session as a secret GitHub gist", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "changelog", .description = "Show changelog entries", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
    .{ .name = "scoped-models", .description = "Enable/disable models for Ctrl+P cycling", .source = .builtin, .action = .{ .builtin = &builtinMarker } },
};

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
        for (self.dynamic.items) |*cmd| {
            self.allocator.free(cmd.name);
            if (cmd.description) |d| self.allocator.free(d);
        }
        self.dynamic.deinit(self.allocator);
    }

    pub fn register(self: *CommandRegistry, cmd: SlashCommand) void {
        self.dynamic.append(self.allocator, cmd) catch {
            self.allocator.free(cmd.name);
            if (cmd.description) |d| self.allocator.free(d);
            return;
        };
    }

    pub fn unregister(self: *CommandRegistry, name: []const u8) bool {
        for (self.dynamic.items, 0..) |_, i| {
            if (std.mem.eql(u8, self.dynamic.items[i].name, name)) {
                const cmd = self.dynamic.orderedRemove(i);
                self.allocator.free(cmd.name);
                if (cmd.description) |d| self.allocator.free(d);
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const CommandRegistry) usize {
        return self.builtins.len + self.dynamic.items.len;
    }

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

    try std.testing.expect(reg.count() > 0);
    const quit = reg.findCommand("quit").?;
    try std.testing.expectEqualStrings("quit", quit.name);
    try std.testing.expectEqualStrings("Quit zi", quit.description.?);
    try std.testing.expect(reg.findCommand("model") != null);
    try std.testing.expect(reg.findCommand("settings") != null);
    try std.testing.expect(reg.findCommand("nonexistent") == null);
}

test "CommandRegistry register and unregister dynamic" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    reg.register(.{
        .name = try std.testing.allocator.dupe(u8, "myplugin"),
        .description = try std.testing.allocator.dupe(u8, "A test plugin"),
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

test "CommandRegistry dynamic commands provide command names" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    reg.register(.{
        .name = try std.testing.allocator.dupe(u8, "quit"),
        .description = try std.testing.allocator.dupe(u8, "Extension quit"),
        .source = .extension,
        .action = .prompt_template,
    });

    const found = reg.findCommand("quit").?;
    try std.testing.expectEqual(Source.builtin, found.source);
    try std.testing.expectEqualStrings("Quit zi", found.description.?);
}

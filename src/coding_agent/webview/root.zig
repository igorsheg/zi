const std = @import("std");
const builtin = @import("builtin");
const lua_runtime = @import("../extensions/lua_runtime.zig");
const resource_types = @import("../resources/types.zig");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const host_process = @import("host_process.zig");
const log = @import("log.zig");

const c = lua_runtime.c;
const default_io = std.Options.debug_io;

pub const max_request_bytes = types.max_request_bytes;
pub const max_response_bytes = types.max_response_bytes;
pub const max_html_bytes = types.max_html_bytes;
pub const max_window_id_bytes = types.max_window_id_bytes;
pub const max_command_name_bytes = types.max_command_name_bytes;
pub const max_host_line_bytes = types.max_host_line_bytes;
pub const EventDispatcher = types.EventDispatcher;
pub const Options = types.Options;
pub const Command = types.Command;
pub const HostEvent = protocol.HostEvent;

pub const Window = struct {
    id: []const u8,
    title: []const u8,
    width: u32,
    height: u32,
    floating: bool,
    asset_root: ?[]const u8,
    entry: []const u8,
    html: ?[]const u8,
    commands: []Command,
    provenance: ?resource_types.ExtensionProvenance,
    host: ?*host_process.Host = null,

    pub fn findCommand(self: Window, name: []const u8) ?Command {
        for (self.commands) |command| {
            if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io = default_io,
    windows: std.ArrayListUnmanaged(Window) = .empty,
    event_dispatcher: ?EventDispatcher = null,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn setIo(self: *Manager, new_io: std.Io) void {
        self.io = new_io;
    }

    pub fn deinit(self: *Manager, L: ?*c.lua_State) void {
        for (self.windows.items) |*window| self.freeWindow(window, L);
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Manager, options: Options, L: ?*c.lua_State) !void {
        try validateOptions(options);
        if (self.indexOf(options.id)) |idx| {
            var old = self.windows.orderedRemove(idx);
            self.freeWindow(&old, L);
        }
        var window = try self.cloneWindow(options);
        errdefer self.freeWindow(&window, null);
        try self.windows.append(self.allocator, window);
    }

    pub fn openHost(self: *Manager, id: []const u8) !void {
        log.coreLog("manager.openHost begin id={s} is_test={} os={s}", .{ id, builtin.is_test, @tagName(builtin.os.tag) });
        if (builtin.is_test) return;
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
        const window = self.findMut(id) orelse return error.WindowNotFound;
        if (window.host != null) return;
        const host = host_process.Host.create(self.allocator, self.io, self.event_dispatcher, .{
            .id = window.id,
            .title = window.title,
            .width = window.width,
            .height = window.height,
            .floating = window.floating,
        }) catch |err| {
            log.coreLog("manager.openHost spawn failed id={s} err={s}", .{ id, @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.HostSpawnFailed,
            };
        };
        errdefer host.destroy();
        window.host = host;
        self.sendInitialDocument(window) catch |err| {
            log.coreLog("manager.openHost sendInitialDocument failed id={s} err={s}", .{ id, @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.HtmlTooLarge => error.HtmlTooLarge,
                error.InvalidAssetRoot => error.InvalidAssetRoot,
                error.InvalidEntry => error.InvalidEntry,
                error.FileNotFound => error.AssetEntryNotFound,
                else => error.InitialDocumentSendFailed,
            };
        };
        log.coreLog("manager.openHost done id={s}", .{id});
    }

    pub fn setEventDispatcher(self: *Manager, dispatcher: ?EventDispatcher) void {
        if (eventDispatcherEql(self.event_dispatcher, dispatcher)) return;
        self.event_dispatcher = dispatcher;
        for (self.windows.items) |*window| {
            if (window.host) |host| host.event_dispatcher = dispatcher;
        }
    }

    pub fn close(self: *Manager, id: []const u8, L: ?*c.lua_State) bool {
        if (self.indexOf(id)) |idx| {
            var old = self.windows.orderedRemove(idx);
            self.freeWindow(&old, L);
            return true;
        }
        return false;
    }

    pub fn find(self: *const Manager, id: []const u8) ?*const Window {
        if (self.indexOf(id)) |idx| return &self.windows.items[idx];
        return null;
    }

    pub fn popEvent(self: *Manager) ?HostEvent {
        for (self.windows.items) |*window| {
            if (window.host) |host| {
                if (host.popEvent()) |event| return event;
            }
        }
        return null;
    }

    pub fn enqueueBridgeEventForTest(self: *Manager, window_id: []const u8, bridge_id: []const u8, command: []const u8, payload_json: []const u8) !void {
        if (self.findMut(window_id)) |window| {
            if (window.host == null) {
                window.host = try host_process.Host.createTest(self.allocator, self.io, self.event_dispatcher, window.id);
            }
            try window.host.?.pushEvent(.{ .bridge = .{
                .window_id = try self.allocator.dupe(u8, window_id),
                .id = try self.allocator.dupe(u8, bridge_id),
                .command = try self.allocator.dupe(u8, command),
                .payload_json = try self.allocator.dupe(u8, payload_json),
            } });
        }
    }

    pub fn sendBridgeResponse(self: *Manager, window_id: []const u8, bridge_id: []const u8, ok: bool, result_json: []const u8) !void {
        if (result_json.len > types.max_response_bytes) return error.ResponseTooLarge;
        const window = self.findMut(window_id) orelse return error.WindowNotFound;
        const host = window.host orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"bridge_response\",\"id\":");
        try std.json.Stringify.value(bridge_id, .{}, w);
        try w.writeAll(",\"ok\":");
        try w.writeAll(if (ok) "true" else "false");
        try w.writeAll(if (ok) ",\"result\":" else ",\"error\":");
        try w.writeAll(result_json);
        try w.writeByte('}');
        try host.sendRaw(out.written());
    }

    pub fn sendBridgeError(self: *Manager, window_id: []const u8, bridge_id: []const u8, message: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"message\":");
        try std.json.Stringify.value(message, .{}, w);
        try w.writeByte('}');
        try self.sendBridgeResponse(window_id, bridge_id, false, out.written());
    }

    fn sendInitialDocument(self: *Manager, window: *Window) !void {
        log.coreLog("sendInitialDocument begin id={s} html={} asset_root={}", .{ window.id, window.html != null, window.asset_root != null });
        if (window.html) |html| {
            if (html.len > types.max_html_bytes) return error.HtmlTooLarge;
            const encoded = try protocol.encodeBase64(self.allocator, html);
            defer self.allocator.free(encoded);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            const w = &out.writer;
            try w.writeAll("{\"type\":\"html\",\"html_base64\":");
            try std.json.Stringify.value(encoded, .{}, w);
            try w.writeByte('}');
            try window.host.?.sendRaw(out.written());
            log.coreLog("sendInitialDocument sent html id={s} raw_len={d} encoded_len={d}", .{ window.id, html.len, encoded.len });
            return;
        }
        if (window.asset_root) |root| {
            try validateAssetSpec(root, window.entry);
            const path = try std.fs.path.join(self.allocator, &.{ root, window.entry });
            defer self.allocator.free(path);
            try std.Io.Dir.accessAbsolute(self.io, path, .{});
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            const w = &out.writer;
            try w.writeAll("{\"type\":\"file\",\"path\":");
            try std.json.Stringify.value(path, .{}, w);
            try w.writeAll(",\"read_root\":");
            try std.json.Stringify.value(root, .{}, w);
            try w.writeByte('}');
            try window.host.?.sendRaw(out.written());
            log.coreLog("sendInitialDocument sent file id={s} path={s}", .{ window.id, path });
            return;
        }
        const blank = "<!doctype html><meta charset=\"utf-8\"><body></body>";
        const encoded = try protocol.encodeBase64(self.allocator, blank);
        defer self.allocator.free(encoded);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"html\",\"html_base64\":");
        try std.json.Stringify.value(encoded, .{}, w);
        try w.writeByte('}');
        try window.host.?.sendRaw(out.written());
        log.coreLog("sendInitialDocument sent blank id={s}", .{window.id});
    }

    fn indexOf(self: *const Manager, id: []const u8) ?usize {
        for (self.windows.items, 0..) |window, idx| {
            if (std.mem.eql(u8, window.id, id)) return idx;
        }
        return null;
    }

    fn findMut(self: *Manager, id: []const u8) ?*Window {
        if (self.indexOf(id)) |idx| return &self.windows.items[idx];
        return null;
    }

    fn cloneWindow(self: *Manager, options: Options) !Window {
        const id = try self.allocator.dupe(u8, options.id);
        errdefer self.allocator.free(id);
        const title = try self.allocator.dupe(u8, options.title);
        errdefer self.allocator.free(title);
        const entry = try self.allocator.dupe(u8, options.entry);
        errdefer self.allocator.free(entry);
        const asset_root = if (options.asset_root) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (asset_root) |v| self.allocator.free(v);
        const html = if (options.html) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (html) |v| self.allocator.free(v);

        const commands = try self.allocator.alloc(Command, options.commands.len);
        var command_count: usize = 0;
        errdefer {
            for (commands[0..command_count]) |*command| self.freeCommand(command, null);
            self.allocator.free(commands);
        }
        for (options.commands, 0..) |command, i| {
            commands[i] = try self.cloneCommand(command);
            command_count += 1;
        }

        return .{
            .id = id,
            .title = title,
            .width = options.width,
            .height = options.height,
            .floating = options.floating,
            .asset_root = asset_root,
            .entry = entry,
            .html = html,
            .commands = commands,
            .provenance = options.provenance,
        };
    }

    fn cloneCommand(self: *Manager, command: Command) !Command {
        const name = try self.allocator.dupe(u8, command.name);
        errdefer self.allocator.free(name);
        const permissions = try self.allocator.alloc([]const u8, command.permissions.len);
        var permission_count: usize = 0;
        errdefer {
            for (permissions[0..permission_count]) |permission| self.allocator.free(permission);
            self.allocator.free(permissions);
        }
        for (command.permissions, 0..) |permission, i| {
            permissions[i] = try self.allocator.dupe(u8, permission);
            permission_count += 1;
        }
        return .{ .name = name, .permissions = permissions, .handler_ref = command.handler_ref };
    }

    fn freeWindow(self: *Manager, window: *Window, L: ?*c.lua_State) void {
        if (window.host) |host| host.destroy();
        self.allocator.free(window.id);
        self.allocator.free(window.title);
        self.allocator.free(window.entry);
        if (window.asset_root) |v| self.allocator.free(v);
        if (window.html) |v| self.allocator.free(v);
        for (window.commands) |*command| self.freeCommand(command, L);
        self.allocator.free(window.commands);
        window.* = undefined;
    }

    fn freeCommand(self: *Manager, command: *Command, L: ?*c.lua_State) void {
        self.allocator.free(command.name);
        for (command.permissions) |permission| self.allocator.free(permission);
        self.allocator.free(command.permissions);
        if (L) |state| c.luaL_unref(state, c.LUA_REGISTRYINDEX, command.handler_ref);
        command.* = undefined;
    }
};

fn eventDispatcherEql(a: ?EventDispatcher, b: ?EventDispatcher) bool {
    if (a) |left| {
        if (b) |right| return left.eql(right);
        return false;
    }
    return b == null;
}

fn validateOptions(options: Options) !void {
    if (options.html) |html| {
        if (html.len > types.max_html_bytes) return error.HtmlTooLarge;
    }
    if (options.asset_root) |root| try validateAssetSpec(root, options.entry);
}

pub fn validateAssetSpec(asset_root: []const u8, entry: []const u8) !void {
    if (asset_root.len == 0) return error.InvalidAssetRoot;
    if (entry.len == 0) return error.InvalidEntry;
    if (std.fs.path.isAbsolute(entry)) return error.InvalidEntry;
    var it = std.fs.path.componentIterator(entry);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.InvalidEntry;
    }
}

test "webview validates asset specs" {
    try validateAssetSpec("/tmp/assets", "index.html");
    try validateAssetSpec("/tmp/assets", "nested/index.html");
    try std.testing.expectError(error.InvalidAssetRoot, validateAssetSpec("", "index.html"));
    try std.testing.expectError(error.InvalidEntry, validateAssetSpec("/tmp/assets", ""));
    try std.testing.expectError(error.InvalidEntry, validateAssetSpec("/tmp/assets", "/index.html"));
    try std.testing.expectError(error.InvalidEntry, validateAssetSpec("/tmp/assets", "../index.html"));
    try std.testing.expectError(error.InvalidEntry, validateAssetSpec("/tmp/assets", "nested/../index.html"));
}

test "webview manager rejects oversized html" {
    const html = try std.testing.allocator.alloc(u8, types.max_html_bytes + 1);
    defer std.testing.allocator.free(html);
    @memset(html, 'x');
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit(null);
    try std.testing.expectError(error.HtmlTooLarge, manager.register(.{ .id = "too-big", .html = html }, null));
}

test "webview manager stores commands by window" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit(null);
    var commands = [_]Command{.{ .name = "submit", .handler_ref = 42 }};
    try manager.register(.{
        .id = "diff-review",
        .title = "Diff Review",
        .commands = commands[0..],
    }, null);
    const win = manager.find("diff-review") orelse return error.MissingWindow;
    try std.testing.expectEqualStrings("Diff Review", win.title);
    try std.testing.expect(win.findCommand("submit") != null);
    try std.testing.expect(win.findCommand("missing") == null);
}

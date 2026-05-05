const std = @import("std");

const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const request_mod = @import("../../coding_agent/request.zig");
const keys_mod = @import("../terminal/keys.zig");
const keybindings = @import("../keybindings.zig");

const Key = keys_mod.Key;

/// Small focus/input bridge for extension-owned surfaces.
///
/// The TUI owns focus and emergency escape. Extensions opt into keyboard input
/// when opening a surface, and receive only scoped `surface_input` events for the
/// active focused surface. This mirrors OpenTUI's useful lesson that renderables
/// handle input only when focused, without importing a global key listener model.
pub fn handle(self: anytype, key: Key) bool {
    const surface_id = self.extension_ui_state.keyboardSurfaceId() orelse return false;
    const surface_component = self.extension_ui_state.surfaceComponent();
    if (self.tui.focus.current) |focused| {
        const Component = @import("../component.zig").Component;
        if (!Component.eql(focused, surface_component)) {
            if (Component.eql(focused, self.active_editor.component())) return false;
            if (self.extension_surface_overlay == null) return false;
        }
    } else if (self.extension_surface_overlay == null) return false;

    if (keybindings.matches(.select_cancel, key) or key.code == .escape) {
        self.tui.setFocus(self.active_editor.component());
        self.tui.dirty = true;
        return true;
    }

    var input = buildSurfaceInput(self.msg_allocator, surface_id, key) catch return true;
    errdefer input.deinit(self.msg_allocator);
    writeSurfaceInputJob(self, input);
    switch (self.request_queue.trySend(.{ .extension_surface_input = input })) {
        .ok => return true,
        .dropped => unreachable,
        .full, .closed, .oom => |rejected| {
            var failed = rejected;
            failed.deinit(self.msg_allocator);
            return true;
        },
    }
}

fn writeSurfaceInputJob(self: anytype, input: extension_ui.SurfaceInput) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "KEY {s} {s} {d} {d} {d} \"\"\n", .{
        input.action,
        input.key,
        @intFromBool(input.ctrl),
        @intFromBool(input.alt),
        @intFromBool(input.shift),
    }) catch return;
    _ = self.job_manager.writeSurfaceInput(input.id, line);
}

fn buildSurfaceInput(allocator: std.mem.Allocator, surface_id: []const u8, key: Key) !extension_ui.SurfaceInput {
    const id = try allocator.dupe(u8, surface_id);
    errdefer allocator.free(id);
    const key_name = try keyName(allocator, key);
    errdefer allocator.free(key_name);
    const text = try keyText(allocator, key);
    errdefer if (text) |value| allocator.free(value);
    const kind = try allocator.dupe(u8, "key");
    errdefer allocator.free(kind);
    const action = try allocator.dupe(u8, "press");
    errdefer allocator.free(action);
    return .{
        .id = id,
        .kind = kind,
        .action = action,
        .key = key_name,
        .text = text,
        .ctrl = key.ctrl,
        .alt = key.alt,
        .shift = key.shift,
    };
}

fn keyName(allocator: std.mem.Allocator, key: Key) ![]const u8 {
    if (key.code == .char) {
        if (key.char) |ch| {
            if (ch == ' ') return try allocator.dupe(u8, "space");
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(ch, &buf) catch 0;
            if (len > 0) return try allocator.dupe(u8, buf[0..len]);
        }
        return try allocator.dupe(u8, "char");
    }
    return try allocator.dupe(u8, switch (key.code) {
        .char => unreachable,
        .enter => "enter",
        .escape => "escape",
        .tab => "tab",
        .backspace => "backspace",
        .up => "up",
        .down => "down",
        .left => "left",
        .right => "right",
        .home => "home",
        .end => "end",
        .page_up => "page_up",
        .page_down => "page_down",
        .delete => "delete",
        .insert => "insert",
        .f1 => "f1",
        .f2 => "f2",
        .f3 => "f3",
        .f4 => "f4",
        .f5 => "f5",
        .f6 => "f6",
        .f7 => "f7",
        .f8 => "f8",
        .f9 => "f9",
        .f10 => "f10",
        .f11 => "f11",
        .f12 => "f12",
    });
}

fn keyText(allocator: std.mem.Allocator, key: Key) !?[]const u8 {
    if (key.code != .char or key.ctrl or key.alt) return null;
    const ch = key.char orelse return null;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(ch, &buf) catch return null;
    return try allocator.dupe(u8, buf[0..len]);
}

const std = @import("std");
const theme_json = @import("json.zig");
const theme_mod = @import("../tui/theme.zig");
const cell_mod = @import("../tui/cell.zig");

const Theme = theme_mod.Theme;
const Color = cell_mod.Color;

var builtin_once = std.once(initBuiltins);
var dark_theme: Theme = undefined;
var light_theme: Theme = undefined;

pub fn dark() *const Theme {
    builtin_once.call();
    return &dark_theme;
}

pub fn light() *const Theme {
    builtin_once.call();
    return &light_theme;
}

pub fn defaultForTerminal() *const Theme {
    return switch (Theme.detectTerminalBackground()) {
        .dark => dark(),
        .light => light(),
    };
}

fn initBuiltins() void {
    dark_theme = loadBuiltin(@embedFile("builtin/dark.json"));
    light_theme = loadBuiltin(@embedFile("builtin/light.json"));
}

fn loadBuiltin(bytes: []const u8) Theme {
    // One-time bootstrap parse for process-lifetime builtin themes.
    const loaded = theme_json.loadFromSlice(std.heap.page_allocator, bytes) catch |err| {
        @panic(@errorName(err));
    };
    defer loaded.deinit(std.heap.page_allocator);
    return loaded.theme;
}

test "builtins load through the canonical json parser" {
    const dark_theme_value = dark();
    const light_theme_value = light();

    try std.testing.expect(dark_theme_value.fg(.accent).eql(Color.rgb(0x8A, 0xBE, 0xB7)));
    try std.testing.expect(light_theme_value.bg(.tool_pending_bg).eql(Color.rgb(0xE8, 0xE8, 0xF0)));
}

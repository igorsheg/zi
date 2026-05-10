const std = @import("std");

extern fn zi_webview_host_main() c_int;

pub fn main() u8 {
    if (@import("builtin").os.tag != .macos) {
        std.debug.print("zi-webview-host is only available on macOS\n", .{});
        return 1;
    }
    return @intCast(zi_webview_host_main());
}

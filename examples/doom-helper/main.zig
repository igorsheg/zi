const std = @import("std");

const WIDTH: u32 = 96;
const HEIGHT: u32 = 54;

const Player = struct {
    x_num: i32 = 50,
    y_num: i32 = 62,
    flash: i32 = 0,
    mutex: std.Io.Mutex = .init,

    fn snapshot(self: *Player, io: std.Io) PlayerState {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.flash > 0) self.flash -= 1;
        return .{ .x_num = self.x_num, .y_num = self.y_num, .flash = self.flash };
    }

    fn applyKey(self: *Player, io: std.Io, key: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (std.mem.eql(u8, key, "left") or std.mem.eql(u8, key, "a")) self.x_num = @max(5, self.x_num - 4);
        if (std.mem.eql(u8, key, "right") or std.mem.eql(u8, key, "d")) self.x_num = @min(95, self.x_num + 4);
        if (std.mem.eql(u8, key, "up") or std.mem.eql(u8, key, "w")) self.y_num = @max(45, self.y_num - 4);
        if (std.mem.eql(u8, key, "down") or std.mem.eql(u8, key, "s")) self.y_num = @min(90, self.y_num + 4);
        if (std.mem.eql(u8, key, "space") or std.mem.eql(u8, key, "enter")) self.flash = 8;
    }
};

const PlayerState = struct { x_num: i32, y_num: i32, flash: i32 };

pub fn main() !void {
    const io = std.Options.debug_io;
    var player = Player{};
    const input_thread = try std.Thread.spawn(.{}, inputLoop, .{ &player, io });
    input_thread.detach();

    var frame_buf: [WIDTH * HEIGHT * 4]u8 = undefined;
    var out_file = std.Io.File{ .handle = 1, .flags = .{ .nonblocking = false } };
    var out_buf: [8192]u8 = undefined;
    var out = out_file.writer(io, &out_buf);

    var frame: u32 = 0;
    while (true) : (frame += 1) {
        const state = player.snapshot(io);
        renderFrame(&frame_buf, WIDTH, HEIGHT, frame, state);
        try out.interface.print("FRAME {d} {d} {d}\n", .{ WIDTH, HEIGHT, frame_buf.len });
        try out.interface.writeAll(&frame_buf);
        try out.flush();
        io.sleep(.fromMilliseconds(250), .awake) catch {};
    }
}

fn inputLoop(player: *Player, io: std.Io) void {
    var in_file = std.Io.File{ .handle = 0, .flags = .{ .nonblocking = false } };
    var buf: [256]u8 = undefined;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.heap.smp_allocator);
    while (true) {
        const n = in_file.readStreaming(io, &.{&buf}) catch return;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                handleLine(player, io, line.items);
                line.clearRetainingCapacity();
            } else {
                line.append(std.heap.smp_allocator, byte) catch return;
            }
        }
    }
}

fn handleLine(player: *Player, io: std.Io, line: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return;
    if (!std.mem.eql(u8, cmd, "KEY")) return;
    const key = it.next() orelse return;
    player.applyKey(io, key);
}

fn renderFrame(out: []u8, width: u32, height: u32, frame: u32, player: PlayerState) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx: usize = (@as(usize, y) * width + x) * 4;
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            if (y * 100 < height * 42) {
                const shade: u32 = 20 + (50 * y / height);
                r = @intCast(shade);
                g = @intCast(shade);
                b = @intCast(70 + (70 * y / height));
            } else {
                const heat: u32 = @intCast(@max(0, @as(i32, @intCast(height - y))));
                const wave: u32 = ((x + frame * 2) % 17) + ((x + 31 - (frame % 31)) % 31);
                const flame: u32 = @min(255, 35 + heat * 5 + wave * 3);
                r = @intCast(@min(255, 50 + flame));
                g = @intCast(@min(255, 12 + flame / 3));
                b = @intCast(@min(255, 8 + flame / 12));
            }

            const mx: i32 = @divTrunc(@as(i32, @intCast(width)) * player.x_num, 100);
            const my: i32 = @divTrunc(@as(i32, @intCast(height)) * player.y_num, 100);
            const dx = @abs(@as(i32, @intCast(x)) - mx);
            const dy = @abs(@as(i32, @intCast(y)) - my);
            if (dx < 3 and dy < 3) {
                if (player.flash > 0) {
                    r = 255; g = 240; b = 80;
                } else {
                    r = 80; g = 220; b = 80;
                }
            }
            out[idx] = r;
            out[idx + 1] = g;
            out[idx + 2] = b;
            out[idx + 3] = 255;
        }
    }
}

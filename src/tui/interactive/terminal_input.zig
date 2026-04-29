const keys_mod = @import("../keys.zig");

const Interactive = @import("../interactive.zig").Interactive;

pub const onSequence = onInputSequence;
pub const onPaste = onInputPaste;

pub fn process(self: *Interactive) bool {
    var input_raw: [4096]u8 = undefined;
    const n = self.tui.terminal.readInput(&input_raw) catch 0;
    if (n == 0) return false;

    if (self.kitty_deadline_ns != null) {
        self.input.buf.appendSlice(self.allocator, input_raw[0..n]) catch {};
        if (self.input.consumeKittyResponse()) {
            self.tui.terminal.enableKittyProtocol();
            self.kitty_deadline_ns = null;
            self.input.drain(&onInputSequence, &onInputPaste, @ptrCast(self));
            return false;
        }
        return true;
    }

    self.input.feed(input_raw[0..n], &onInputSequence, &onInputPaste, @ptrCast(self));
    return false;
}

pub fn finishKittyNegotiationIfDue(self: *Interactive) void {
    if (self.kitty_deadline_ns) |deadline| {
        if (@import("std").time.nanoTimestamp() >= deadline) {
            self.tui.terminal.enableModifyOtherKeys();
            self.kitty_deadline_ns = null;
            if (self.input.buf.items.len > 0) {
                self.input.drain(&onInputSequence, &onInputPaste, @ptrCast(self));
            }
        }
    }
}

fn onInputSequence(seq: []const u8, raw_ctx: *anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(raw_ctx));

    if (seq.len == 1 and seq[0] == '\n') {
        self.active_editor.insertText("\n");
        self.refreshHeaderVisibility();
        self.tui.dirty = true;
        return;
    }

    const result = keys_mod.parseInput(seq, self.tui.terminal.kitty_active) orelse return;
    switch (result) {
        .key => |k| self.handleKey(k.key),
        .mouse => |m| self.handleMouse(m.event),
    }
}

fn onInputPaste(content: []const u8, raw_ctx: *anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(raw_ctx));
    self.active_editor.handlePaste(content);
    self.refreshHeaderVisibility();
    self.tui.dirty = true;
}

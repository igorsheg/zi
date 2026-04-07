const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const select_list_mod = @import("components/select_list.zig");
const SelectItem = select_list_mod.SelectItem;

pub const RequestSnapshot = struct {
    text: []const u8,
    cursor_byte: u32,
};

pub const ApplyResult = struct {
    new_text: []const u8,
    new_cursor: u32,
};

pub const Suggestions = struct {
    items: []const SelectItem,
    prefix: []const u8,
};

/// Callback sink for delivering suggestions from provider to editor.
/// For sync providers (slash commands), call publish() immediately in request().
/// For async providers (@file, future), publish results when ready.
pub const SuggestionSink = struct {
    ptr: *anyopaque,
    publish_fn: *const fn (ptr: *anyopaque, suggestions: ?Suggestions) void,

    pub fn publish(self: SuggestionSink, suggestions: ?Suggestions) void {
        self.publish_fn(self.ptr, suggestions);
    }
};

/// Vtable-based autocomplete provider interface.
pub const AutocompleteProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, snapshot: RequestSnapshot, sink: SuggestionSink) void,
        cancel: ?*const fn (ptr: *anyopaque) void,
        apply: *const fn (ptr: *anyopaque, text: []const u8, cursor: u32, item: *const SelectItem, prefix: []const u8) ?ApplyResult,
    };

    pub fn request(self: AutocompleteProvider, snapshot: RequestSnapshot, sink: SuggestionSink) void {
        self.vtable.request(self.ptr, snapshot, sink);
    }

    pub fn cancel(self: AutocompleteProvider) void {
        if (self.vtable.cancel) |c| c(self.ptr);
    }

    pub fn apply(self: AutocompleteProvider, text: []const u8, cursor: u32, item: *const SelectItem, prefix: []const u8) ?ApplyResult {
        return self.vtable.apply(self.ptr, text, cursor, item, prefix);
    }
};

// --- SlashCommandProvider ---
//
// zi-wub.19: this provider runs on the TUI thread on every keystroke.
// Today the registry it reads is TUI-owned and its `dynamic` arm is
// empty (no extension registers a slash command yet), so the read is
// structurally safe. When extension commands land, this provider must
// NOT reach into `ExtensionRunner.command_registry` directly and must
// NOT call into lua. Instead, swap `registry` for a TUI-owned
// `*const CommandSnapshot` that the agent thread publishes after each
// mutation. See .zi/design-notes/command-snapshot.md.

const slash_commands_mod = @import("../slash_commands.zig");
const CommandRegistry = slash_commands_mod.CommandRegistry;
const SlashCommand = slash_commands_mod.SlashCommand;

pub const SlashCommandProvider = struct {
    registry: *const CommandRegistry,

    text_buf: [256][]const u8 = undefined,
    index_buf: [256]usize = undefined,
    item_buf: [256]SelectItem = undefined,
    apply_buf: [4096]u8 = undefined,

    const vtable = AutocompleteProvider.VTable{
        .request = @ptrCast(&requestImpl),
        .cancel = null,
        .apply = @ptrCast(&applyImpl),
    };

    pub fn init(registry: *const CommandRegistry) SlashCommandProvider {
        return .{ .registry = registry };
    }

    pub fn provider(self: *SlashCommandProvider) AutocompleteProvider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn requestImpl(self: *SlashCommandProvider, snapshot: RequestSnapshot, sink: SuggestionSink) void {
        const text = snapshot.text;
        const cursor = snapshot.cursor_byte;

        if (text.len == 0 or text[0] != '/') {
            sink.publish(null);
            return;
        }
        if (cursor > text.len) {
            sink.publish(null);
            return;
        }
        if (std.mem.indexOfScalar(u8, text[0..cursor], '\n') != null) {
            sink.publish(null);
            return;
        }

        const prefix_after_slash = if (cursor > 1) text[1..cursor] else "";

        var n: usize = 0;
        for (self.registry.builtins) |cmd| {
            if (n >= self.text_buf.len) break;
            self.text_buf[n] = cmd.name;
            n += 1;
        }
        for (self.registry.dynamic.items) |cmd| {
            if (n >= self.text_buf.len) break;
            self.text_buf[n] = cmd.name;
            n += 1;
        }

        const matched = fuzzy.fuzzyFilter(
            prefix_after_slash,
            self.text_buf[0..n],
            &self.index_buf,
        );

        for (0..matched) |i| {
            const idx = self.index_buf[i];
            const cmd = self.getCommand(idx);
            self.item_buf[i] = .{
                .value = cmd.name,
                .label = cmd.name,
                .description = cmd.description,
            };
        }

        const prefix = text[0..cursor];

        if (matched > 0) {
            sink.publish(.{
                .items = self.item_buf[0..matched],
                .prefix = prefix,
            });
        } else {
            sink.publish(null);
        }
    }

    fn getCommand(self: *const SlashCommandProvider, idx: usize) *const SlashCommand {
        if (idx < self.registry.builtins.len) {
            return &self.registry.builtins[idx];
        }
        return &self.registry.dynamic.items[idx - self.registry.builtins.len];
    }

    fn applyImpl(self: *SlashCommandProvider, text: []const u8, _: u32, item: *const SelectItem, prefix: []const u8) ?ApplyResult {
        const suffix = if (prefix.len <= text.len) text[prefix.len..] else "";

        var pos: usize = 0;

        self.apply_buf[pos] = '/';
        pos += 1;

        if (pos + item.value.len > self.apply_buf.len) return null;
        @memcpy(self.apply_buf[pos..][0..item.value.len], item.value);
        pos += item.value.len;

        self.apply_buf[pos] = ' ';
        pos += 1;

        const new_cursor: u32 = @intCast(pos);

        if (pos + suffix.len > self.apply_buf.len) return null;
        @memcpy(self.apply_buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;

        return .{
            .new_text = self.apply_buf[0..pos],
            .new_cursor = new_cursor,
        };
    }
};

// --- Tests ---

const TestSink = struct {
    result: ?Suggestions = null,

    fn callback(ptr: *anyopaque, suggestions: ?Suggestions) void {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        self.result = suggestions;
    }

    fn sink(self: *TestSink) SuggestionSink {
        return .{ .ptr = @ptrCast(self), .publish_fn = &callback };
    }
};

fn hasItem(items: []const SelectItem, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.value, value)) return true;
    }
    return false;
}

test "SlashCommandProvider suggests commands on slash prefix" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var p = SlashCommandProvider.init(&reg);
    var ts = TestSink{};

    p.requestImpl(.{ .text = "/mo", .cursor_byte = 3 }, ts.sink());

    try std.testing.expect(ts.result != null);
    try std.testing.expect(hasItem(ts.result.?.items, "model"));
}

test "SlashCommandProvider empty prefix returns all commands" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var p = SlashCommandProvider.init(&reg);
    var ts = TestSink{};

    p.requestImpl(.{ .text = "/", .cursor_byte = 1 }, ts.sink());

    try std.testing.expect(ts.result != null);
    try std.testing.expectEqual(reg.count(), ts.result.?.items.len);
}

test "SlashCommandProvider no suggestions without slash" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var p = SlashCommandProvider.init(&reg);
    var ts = TestSink{};

    p.requestImpl(.{ .text = "hello", .cursor_byte = 5 }, ts.sink());

    try std.testing.expect(ts.result == null);
}

test "SlashCommandProvider apply inserts command" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var p = SlashCommandProvider.init(&reg);

    const item = SelectItem{ .value = "model", .label = "model" };
    const result = p.applyImpl("/mo", 3, &item, "/mo");

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/model ", result.?.new_text);
    try std.testing.expectEqual(@as(u32, 7), result.?.new_cursor);
}

test "SlashCommandProvider no suggestions on second line" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var p = SlashCommandProvider.init(&reg);
    var ts = TestSink{};

    p.requestImpl(.{ .text = "hello\n/mo", .cursor_byte = 9 }, ts.sink());

    try std.testing.expect(ts.result == null);
}

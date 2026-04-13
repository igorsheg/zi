const std = @import("std");
const search = @import("../search/root.zig");
const select_list_mod = @import("components/select_list.zig");
const slash_commands_mod = @import("../slash_commands.zig");

const SelectItem = select_list_mod.SelectItem;
const CommandRegistry = slash_commands_mod.CommandRegistry;
const SlashCommand = slash_commands_mod.SlashCommand;

pub const RequestMode = enum {
    regular,
    force,
};

pub const RequestSnapshot = struct {
    text: []const u8,
    cursor_byte: u32,
    mode: RequestMode = .regular,
};

pub const ReplaceRange = struct {
    start_byte: u32,
    end_byte: u32,
};

pub const ApplyResult = struct {
    replacement_text: []const u8,
    cursor_in_replacement: u32,
    replace_range: ?ReplaceRange = null,
};

pub const Suggestions = struct {
    items: []const SelectItem,
    replace_range: ReplaceRange,
    submit_on_confirm: bool = false,
    refresh_mode: RequestMode = .regular,
    auto_accept_single_on_tab: bool = false,
};

/// Callback sink for delivering suggestions from provider to editor.
/// For sync providers (slash commands, local path completion), call publish()
/// immediately in request(). Async providers can publish later.
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
        apply: *const fn (ptr: *anyopaque, text: []const u8, cursor: u32, item: *const SelectItem, replace_range: ReplaceRange) ?ApplyResult,
    };

    pub fn request(self: AutocompleteProvider, snapshot: RequestSnapshot, sink: SuggestionSink) void {
        self.vtable.request(self.ptr, snapshot, sink);
    }

    pub fn cancel(self: AutocompleteProvider) void {
        if (self.vtable.cancel) |c| c(self.ptr);
    }

    pub fn apply(self: AutocompleteProvider, text: []const u8, cursor: u32, item: *const SelectItem, replace_range: ReplaceRange) ?ApplyResult {
        return self.vtable.apply(self.ptr, text, cursor, item, replace_range);
    }
};

const max_command_candidates = 256;
const max_path_candidates = 64;
const max_path_bytes = 512;
const path_delimiters = [_]u8{ ' ', '\t', '"', '\'', '=' };

const TokenRange = struct {
    start_offset: u32,
    prefix: []const u8,
};

const ParsedPathPrefix = struct {
    raw_prefix: []const u8,
    is_at_prefix: bool,
    is_quoted_prefix: bool,
};

const SearchPlan = struct {
    search_dir: []const u8,
    search_prefix: []const u8,
    display_prefix: []const u8,
    is_at_prefix: bool,
    is_quoted_prefix: bool,
};

const FixedBuilder = struct {
    buf: []u8,
    len: usize = 0,

    fn append(self: *FixedBuilder, text: []const u8) bool {
        if (self.len + text.len > self.buf.len) return false;
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
        return true;
    }

    fn appendByte(self: *FixedBuilder, byte: u8) bool {
        if (self.len >= self.buf.len) return false;
        self.buf[self.len] = byte;
        self.len += 1;
        return true;
    }

    fn written(self: *const FixedBuilder) []const u8 {
        return self.buf[0..self.len];
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

pub const SlashCommandProvider = struct {
    registry: *const CommandRegistry,

    text_buf: [max_command_candidates][]const u8 = undefined,
    index_buf: [max_command_candidates]usize = undefined,
    item_buf: [max_command_candidates]SelectItem = undefined,
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
        const cursor = @min(snapshot.cursor_byte, @as(u32, @intCast(text.len)));

        if (text.len == 0 or text[0] != '/') {
            sink.publish(null);
            return;
        }
        if (std.mem.indexOfScalar(u8, text[0..cursor], '\n') != null) {
            sink.publish(null);
            return;
        }

        const prefix_after_slash = if (cursor > 1) text[1..cursor] else "";
        const matched = self.buildCommandItems(prefix_after_slash);
        if (matched == 0) {
            sink.publish(null);
            return;
        }

        sink.publish(.{
            .items = self.item_buf[0..matched],
            .replace_range = .{ .start_byte = 0, .end_byte = cursor },
            .submit_on_confirm = true,
        });
    }

    fn buildCommandItems(self: *SlashCommandProvider, prefix_after_slash: []const u8) usize {
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

        const matched = search.plain.filter(
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
        return matched;
    }

    fn getCommand(self: *const SlashCommandProvider, idx: usize) *const SlashCommand {
        if (idx < self.registry.builtins.len) {
            return &self.registry.builtins[idx];
        }
        return &self.registry.dynamic.items[idx - self.registry.builtins.len];
    }

    fn applyImpl(self: *SlashCommandProvider, _: []const u8, _: u32, item: *const SelectItem, _: ReplaceRange) ?ApplyResult {
        return slashApply(self.apply_buf[0..], item.value);
    }
};

pub const CombinedAutocompleteProvider = struct {
    registry: *const CommandRegistry,
    cwd: []const u8,

    command_names: [max_command_candidates][]const u8 = undefined,
    command_indices: [max_command_candidates]usize = undefined,
    item_buf: [max_path_candidates]SelectItem = undefined,
    item_is_directory: [max_path_candidates]bool = .{false} ** max_path_candidates,
    value_storage: [max_path_candidates][max_path_bytes]u8 = undefined,
    label_storage: [max_path_candidates][max_path_bytes]u8 = undefined,
    description_storage: [max_path_candidates][max_path_bytes]u8 = undefined,
    temp_path_buf: [max_path_bytes]u8 = undefined,
    temp_dir_buf: [max_path_bytes]u8 = undefined,
    apply_buf: [max_path_bytes]u8 = undefined,

    const vtable = AutocompleteProvider.VTable{
        .request = @ptrCast(&requestImpl),
        .cancel = null,
        .apply = @ptrCast(&applyImpl),
    };

    pub fn init(registry: *const CommandRegistry, cwd: []const u8) CombinedAutocompleteProvider {
        return .{
            .registry = registry,
            .cwd = cwd,
        };
    }

    pub fn provider(self: *CombinedAutocompleteProvider) AutocompleteProvider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn requestImpl(self: *CombinedAutocompleteProvider, snapshot: RequestSnapshot, sink: SuggestionSink) void {
        const text = snapshot.text;
        const cursor = @min(snapshot.cursor_byte, @as(u32, @intCast(text.len)));
        const line_start = currentLineStart(text, cursor);
        const before_cursor = text[line_start..cursor];

        if (extractAtPrefix(before_cursor)) |token| {
            const count = self.buildPathSuggestions(token.prefix);
            if (count == 0) {
                sink.publish(null);
                return;
            }
            sink.publish(.{
                .items = self.item_buf[0..count],
                .replace_range = .{
                    .start_byte = line_start + token.start_offset,
                    .end_byte = cursor,
                },
                .submit_on_confirm = false,
                .refresh_mode = if (snapshot.mode == .force) .force else .regular,
                .auto_accept_single_on_tab = snapshot.mode == .force,
            });
            return;
        }

        if (line_start == 0 and isSlashCommandNameContext(before_cursor)) {
            const prefix_after_slash = if (before_cursor.len > 1) before_cursor[1..] else "";
            const matched = self.buildCommandItems(prefix_after_slash);
            if (matched == 0) {
                sink.publish(null);
                return;
            }
            sink.publish(.{
                .items = self.item_buf[0..matched],
                .replace_range = .{ .start_byte = 0, .end_byte = cursor },
                .submit_on_confirm = true,
                .refresh_mode = .regular,
                .auto_accept_single_on_tab = false,
            });
            return;
        }

        if (snapshot.mode == .regular and before_cursor.len > 0 and before_cursor[0] == '/') {
            sink.publish(null);
            return;
        }

        const token = extractPathPrefix(before_cursor, snapshot.mode == .force) orelse {
            sink.publish(null);
            return;
        };
        const count = self.buildPathSuggestions(token.prefix);
        if (count == 0) {
            sink.publish(null);
            return;
        }

        sink.publish(.{
            .items = self.item_buf[0..count],
            .replace_range = .{
                .start_byte = line_start + token.start_offset,
                .end_byte = cursor,
            },
            .submit_on_confirm = false,
            .refresh_mode = if (snapshot.mode == .force) .force else .regular,
            .auto_accept_single_on_tab = snapshot.mode == .force,
        });
    }

    fn buildCommandItems(self: *CombinedAutocompleteProvider, prefix_after_slash: []const u8) usize {
        var n: usize = 0;
        for (self.registry.builtins) |cmd| {
            if (n >= self.command_names.len) break;
            self.command_names[n] = cmd.name;
            n += 1;
        }
        for (self.registry.dynamic.items) |cmd| {
            if (n >= self.command_names.len) break;
            self.command_names[n] = cmd.name;
            n += 1;
        }

        const matched = search.plain.filter(prefix_after_slash, self.command_names[0..n], &self.command_indices);
        const clamped = @min(matched, self.item_buf.len);
        for (0..clamped) |i| {
            const idx = self.command_indices[i];
            const cmd = self.getCommand(idx);
            self.item_buf[i] = .{
                .value = cmd.name,
                .label = cmd.name,
                .description = cmd.description,
            };
            self.item_is_directory[i] = false;
        }
        return clamped;
    }

    fn buildPathSuggestions(self: *CombinedAutocompleteProvider, prefix: []const u8) usize {
        const plan = self.resolveSearchPlan(prefix) orelse return 0;

        var dir = std.fs.openDirAbsolute(plan.search_dir, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next() catch null) |entry| {
            if (count >= self.item_buf.len) break;
            if (!startsWithIgnoreCase(entry.name, plan.search_prefix)) continue;

            var is_directory = entry.kind == .directory;
            if (!is_directory and entry.kind == .sym_link) {
                const stat: ?std.fs.File.Stat = dir.statFile(entry.name) catch null;
                if (stat) |value| {
                    is_directory = value.kind == .directory;
                }
            }

            const display_path = self.buildDisplayPath(count, plan.display_prefix, entry.name) orelse continue;
            const completion_value = self.buildCompletionValue(count, display_path, is_directory, plan.is_at_prefix, plan.is_quoted_prefix) orelse continue;
            const label = self.buildLabel(count, entry.name, is_directory) orelse continue;

            self.item_buf[count] = .{
                .value = completion_value,
                .label = label,
            };
            self.item_is_directory[count] = is_directory;
            count += 1;
        }

        sortItems(self.item_buf[0..count], self.item_is_directory[0..count]);
        return count;
    }

    fn resolveSearchPlan(self: *CombinedAutocompleteProvider, prefix: []const u8) ?SearchPlan {
        const parsed = parsePathPrefix(prefix);
        const raw_prefix = parsed.raw_prefix;
        const expanded_prefix = self.expandHomePath(raw_prefix) orelse raw_prefix;
        const is_root_prefix = raw_prefix.len == 0 or
            std.mem.eql(u8, raw_prefix, "./") or
            std.mem.eql(u8, raw_prefix, "../") or
            std.mem.eql(u8, raw_prefix, "~") or
            std.mem.eql(u8, raw_prefix, "~/") or
            std.mem.eql(u8, raw_prefix, "/") or
            (parsed.is_at_prefix and raw_prefix.len == 0);

        var builder = FixedBuilder{ .buf = self.temp_dir_buf[0..] };
        if (is_root_prefix or std.mem.endsWith(u8, raw_prefix, "/")) {
            const target = if (raw_prefix.len == 0)
                self.cwd
            else if (raw_prefix[0] == '/' or std.mem.startsWith(u8, raw_prefix, "~/") or std.mem.eql(u8, raw_prefix, "~"))
                expanded_prefix
            else
                self.joinSearchDir(&builder, self.cwd, raw_prefix) orelse return null;

            return .{
                .search_dir = target,
                .search_prefix = "",
                .display_prefix = raw_prefix,
                .is_at_prefix = parsed.is_at_prefix,
                .is_quoted_prefix = parsed.is_quoted_prefix,
            };
        }

        const search_prefix = std.fs.path.basename(raw_prefix);
        const expanded_dir = std.fs.path.dirname(expanded_prefix) orelse ".";
        const search_dir = if (raw_prefix[0] == '/' or std.mem.startsWith(u8, raw_prefix, "~/"))
            expanded_dir
        else
            self.joinSearchDir(&builder, self.cwd, expanded_dir) orelse return null;

        return .{
            .search_dir = search_dir,
            .search_prefix = search_prefix,
            .display_prefix = raw_prefix,
            .is_at_prefix = parsed.is_at_prefix,
            .is_quoted_prefix = parsed.is_quoted_prefix,
        };
    }

    fn joinSearchDir(self: *CombinedAutocompleteProvider, builder: *FixedBuilder, base: []const u8, suffix: []const u8) ?[]const u8 {
        _ = self;
        builder.len = 0;
        if (!builder.append(base)) return null;
        if (suffix.len == 0 or std.mem.eql(u8, suffix, ".")) {
            return builder.written();
        }
        if (!std.mem.endsWith(u8, builder.written(), "/")) {
            if (!builder.appendByte('/')) return null;
        }
        if (!builder.append(suffix)) return null;
        return builder.written();
    }

    fn buildDisplayPath(self: *CombinedAutocompleteProvider, idx: usize, display_prefix: []const u8, entry_name: []const u8) ?[]const u8 {
        var builder = FixedBuilder{ .buf = self.description_storage[idx][0..] };
        if (display_prefix.len == 0) {
            if (!builder.append(entry_name)) return null;
            return builder.written();
        }

        if (std.mem.endsWith(u8, display_prefix, "/")) {
            if (!builder.append(display_prefix)) return null;
            if (!builder.append(entry_name)) return null;
            return builder.written();
        }

        if (std.mem.indexOfScalar(u8, display_prefix, '/')) |_| {
            if (std.mem.startsWith(u8, display_prefix, "~/")) {
                const home_relative = display_prefix[2..];
                const dir_part = std.fs.path.dirname(home_relative) orelse ".";
                if (!builder.append("~/")) return null;
                if (!std.mem.eql(u8, dir_part, ".")) {
                    if (!builder.append(dir_part)) return null;
                    if (!builder.appendByte('/')) return null;
                }
                if (!builder.append(entry_name)) return null;
                return builder.written();
            }

            if (display_prefix[0] == '/') {
                const dir_part = std.fs.path.dirname(display_prefix) orelse "/";
                if (!builder.append(dir_part)) return null;
                if (!std.mem.endsWith(u8, dir_part, "/")) {
                    if (!builder.appendByte('/')) return null;
                }
                if (!builder.append(entry_name)) return null;
                return builder.written();
            }

            const dir_part = std.fs.path.dirname(display_prefix) orelse ".";
            if (std.mem.eql(u8, dir_part, ".")) {
                if (std.mem.startsWith(u8, display_prefix, "./")) {
                    if (!builder.append("./")) return null;
                }
                if (!builder.append(entry_name)) return null;
                return builder.written();
            }

            if (!builder.append(dir_part)) return null;
            if (!builder.appendByte('/')) return null;
            if (!builder.append(entry_name)) return null;
            return builder.written();
        }

        if (std.mem.startsWith(u8, display_prefix, "~")) {
            if (!builder.append("~/")) return null;
            if (!builder.append(entry_name)) return null;
            return builder.written();
        }

        if (!builder.append(entry_name)) return null;
        return builder.written();
    }

    fn buildCompletionValue(self: *CombinedAutocompleteProvider, idx: usize, path: []const u8, is_directory: bool, is_at_prefix: bool, is_quoted_prefix: bool) ?[]const u8 {
        var builder = FixedBuilder{ .buf = self.value_storage[idx][0..] };
        const path_has_spaces = std.mem.indexOfScalar(u8, path, ' ') != null;
        const needs_quotes = is_quoted_prefix or path_has_spaces;

        if (is_at_prefix and !builder.appendByte('@')) return null;
        if (needs_quotes and !builder.appendByte('"')) return null;
        if (!builder.append(path)) return null;
        if (is_directory and !builder.appendByte('/')) return null;
        if (needs_quotes and !builder.appendByte('"')) return null;
        return builder.written();
    }

    fn buildLabel(self: *CombinedAutocompleteProvider, idx: usize, name: []const u8, is_directory: bool) ?[]const u8 {
        var builder = FixedBuilder{ .buf = self.label_storage[idx][0..] };
        if (!builder.append(name)) return null;
        if (is_directory and !builder.appendByte('/')) return null;
        return builder.written();
    }

    fn getCommand(self: *const CombinedAutocompleteProvider, idx: usize) *const SlashCommand {
        if (idx < self.registry.builtins.len) {
            return &self.registry.builtins[idx];
        }
        return &self.registry.dynamic.items[idx - self.registry.builtins.len];
    }

    fn expandHomePath(self: *CombinedAutocompleteProvider, path: []const u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        if (std.mem.eql(u8, path, "~")) return home;
        if (!std.mem.startsWith(u8, path, "~/")) return null;

        var builder = FixedBuilder{ .buf = self.temp_path_buf[0..] };
        if (!builder.append(home)) return null;
        if (!std.mem.endsWith(u8, home, "/")) {
            if (!builder.appendByte('/')) return null;
        }
        if (!builder.append(path[2..])) return null;
        return builder.written();
    }

    fn applyImpl(self: *CombinedAutocompleteProvider, text: []const u8, cursor: u32, item: *const SelectItem, replace_range: ReplaceRange) ?ApplyResult {
        const clamped_cursor = @min(cursor, @as(u32, @intCast(text.len)));
        const start: usize = @intCast(@min(replace_range.start_byte, @as(u32, @intCast(text.len))));
        const end: usize = @intCast(@min(replace_range.end_byte, clamped_cursor));
        const after_start: usize = @intCast(@min(replace_range.end_byte, @as(u32, @intCast(text.len))));
        const prefix = text[start..end];
        const after_range = text[after_start..];
        const is_quoted_prefix = std.mem.startsWith(u8, prefix, "\"") or std.mem.startsWith(u8, prefix, "@\"");
        const has_leading_quote_after_range = after_range.len > 0 and after_range[0] == '"';
        const has_trailing_quote_in_item = std.mem.endsWith(u8, item.value, "\"");

        var applied_range = replace_range;
        if (is_quoted_prefix and has_trailing_quote_in_item and has_leading_quote_after_range) {
            applied_range.end_byte = @min(applied_range.end_byte + 1, @as(u32, @intCast(text.len)));
        }

        if (isSlashCommandPrefix(prefix)) {
            const slash = slashApply(self.apply_buf[0..], item.value) orelse return null;
            return .{
                .replacement_text = slash.replacement_text,
                .cursor_in_replacement = slash.cursor_in_replacement,
                .replace_range = applied_range,
            };
        }

        const is_directory = std.mem.endsWith(u8, item.label, "/");
        const has_trailing_quote = std.mem.endsWith(u8, item.value, "\"");
        if (std.mem.startsWith(u8, prefix, "@")) {
            var builder = FixedBuilder{ .buf = self.apply_buf[0..] };
            if (!builder.append(item.value)) return null;
            if (!is_directory) {
                if (!builder.appendByte(' ')) return null;
            }
            const cursor_in_replacement: u32 = if (is_directory and has_trailing_quote)
                @intCast(item.value.len - 1)
            else
                @intCast(item.value.len + if (is_directory) @as(usize, 0) else @as(usize, 1));
            return .{
                .replacement_text = builder.written(),
                .cursor_in_replacement = cursor_in_replacement,
                .replace_range = applied_range,
            };
        }

        const cursor_in_replacement: u32 = if (is_directory and has_trailing_quote)
            @intCast(item.value.len - 1)
        else
            @intCast(item.value.len);
        return .{
            .replacement_text = item.value,
            .cursor_in_replacement = cursor_in_replacement,
            .replace_range = applied_range,
        };
    }
};

fn slashApply(apply_buf: []u8, value: []const u8) ?ApplyResult {
    var builder = FixedBuilder{ .buf = apply_buf };
    if (!builder.appendByte('/')) return null;
    if (!builder.append(value)) return null;
    if (!builder.appendByte(' ')) return null;
    return .{
        .replacement_text = builder.written(),
        .cursor_in_replacement = @intCast(builder.len),
    };
}

fn currentLineStart(text: []const u8, cursor: u32) u32 {
    const clamped = @min(cursor, @as(u32, @intCast(text.len)));
    if (clamped == 0) return 0;
    if (std.mem.lastIndexOfScalar(u8, text[0..clamped], '\n')) |idx| {
        return @intCast(idx + 1);
    }
    return 0;
}

fn isSlashCommandNameContext(before_cursor: []const u8) bool {
    if (before_cursor.len == 0 or before_cursor[0] != '/') return false;
    return std.mem.indexOfScalar(u8, before_cursor, ' ') == null;
}

fn isSlashCommandPrefix(prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, prefix, "/")) return false;
    return std.mem.indexOfScalar(u8, prefix[1..], '/') == null;
}

fn extractAtPrefix(before_cursor: []const u8) ?TokenRange {
    if (extractQuotedPrefix(before_cursor)) |token| {
        if (std.mem.startsWith(u8, token.prefix, "@\"")) return token;
    }

    const last_delimiter = findLastDelimiter(before_cursor);
    const token_start: usize = if (last_delimiter) |idx| idx + 1 else 0;
    if (token_start >= before_cursor.len) return null;
    if (before_cursor[token_start] != '@') return null;
    return .{
        .start_offset = @intCast(token_start),
        .prefix = before_cursor[token_start..],
    };
}

fn extractPathPrefix(before_cursor: []const u8, force_extract: bool) ?TokenRange {
    if (extractQuotedPrefix(before_cursor)) |token| return token;

    const last_delimiter = findLastDelimiter(before_cursor);
    const token_start: usize = if (last_delimiter) |idx| idx + 1 else 0;
    const path_prefix = before_cursor[token_start..];

    if (force_extract) {
        return .{
            .start_offset = @intCast(token_start),
            .prefix = path_prefix,
        };
    }

    if (std.mem.indexOfScalar(u8, path_prefix, '/')) |_| {
        return .{
            .start_offset = @intCast(token_start),
            .prefix = path_prefix,
        };
    }
    if (std.mem.startsWith(u8, path_prefix, ".") or std.mem.startsWith(u8, path_prefix, "~/")) {
        return .{
            .start_offset = @intCast(token_start),
            .prefix = path_prefix,
        };
    }
    if (path_prefix.len == 0 and before_cursor.len > 0 and before_cursor[before_cursor.len - 1] == ' ') {
        return .{
            .start_offset = @intCast(token_start),
            .prefix = path_prefix,
        };
    }
    return null;
}

fn extractQuotedPrefix(before_cursor: []const u8) ?TokenRange {
    const quote_start = findUnclosedQuoteStart(before_cursor) orelse return null;

    if (quote_start > 0 and before_cursor[quote_start - 1] == '@') {
        if (!isTokenStart(before_cursor, quote_start - 1)) return null;
        return .{
            .start_offset = @intCast(quote_start - 1),
            .prefix = before_cursor[quote_start - 1 ..],
        };
    }

    if (!isTokenStart(before_cursor, quote_start)) return null;
    return .{
        .start_offset = @intCast(quote_start),
        .prefix = before_cursor[quote_start..],
    };
}

fn parsePathPrefix(prefix: []const u8) ParsedPathPrefix {
    if (std.mem.startsWith(u8, prefix, "@\"")) {
        return .{ .raw_prefix = prefix[2..], .is_at_prefix = true, .is_quoted_prefix = true };
    }
    if (std.mem.startsWith(u8, prefix, "\"")) {
        return .{ .raw_prefix = prefix[1..], .is_at_prefix = false, .is_quoted_prefix = true };
    }
    if (std.mem.startsWith(u8, prefix, "@")) {
        return .{ .raw_prefix = prefix[1..], .is_at_prefix = true, .is_quoted_prefix = false };
    }
    return .{ .raw_prefix = prefix, .is_at_prefix = false, .is_quoted_prefix = false };
}

fn findLastDelimiter(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        for (path_delimiters) |delimiter| {
            if (text[i] == delimiter) return i;
        }
    }
    return null;
}

fn findUnclosedQuoteStart(text: []const u8) ?usize {
    var in_quotes = false;
    var quote_start: usize = 0;
    for (text, 0..) |byte, idx| {
        if (byte != '"') continue;
        in_quotes = !in_quotes;
        if (in_quotes) {
            quote_start = idx;
        }
    }
    return if (in_quotes) quote_start else null;
}

fn isTokenStart(text: []const u8, index: usize) bool {
    if (index == 0) return true;
    for (path_delimiters) |delimiter| {
        if (text[index - 1] == delimiter) return true;
    }
    return false;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (prefix, text[0..prefix.len]) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn sortItems(items: []SelectItem, is_directory: []bool) void {
    if (items.len <= 1) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and shouldSwap(items[j - 1], is_directory[j - 1], items[j], is_directory[j])) : (j -= 1) {
            std.mem.swap(SelectItem, &items[j - 1], &items[j]);
            std.mem.swap(bool, &is_directory[j - 1], &is_directory[j]);
        }
    }
}

fn shouldSwap(left: SelectItem, left_is_dir: bool, right: SelectItem, right_is_dir: bool) bool {
    if (left_is_dir != right_is_dir) return !left_is_dir and right_is_dir;
    return asciiLessThanIgnoreCase(right.label, left.label);
}

fn asciiLessThanIgnoreCase(a: []const u8, b: []const u8) bool {
    const shared = @min(a.len, b.len);
    for (0..shared) |idx| {
        const lhs = std.ascii.toLower(a[idx]);
        const rhs = std.ascii.toLower(b[idx]);
        if (lhs < rhs) return true;
        if (lhs > rhs) return false;
    }
    return a.len < b.len;
}

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
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 0, .end_byte = 3 }, ts.result.?.replace_range);
    try std.testing.expect(ts.result.?.submit_on_confirm);
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
    const result = p.applyImpl("/mo", 3, &item, .{ .start_byte = 0, .end_byte = 3 });

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/model ", result.?.replacement_text);
    try std.testing.expectEqual(@as(u32, 7), result.?.cursor_in_replacement);
}

test "CombinedAutocompleteProvider force tab completes slash command arguments with paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.md", .data = "hello" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(&reg, cwd);
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "/open no", .cursor_byte = 8, .mode = .force }, sink.sink());

    try std.testing.expect(sink.result != null);
    try std.testing.expect(hasItem(sink.result.?.items, "notes.md"));
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 6, .end_byte = 8 }, sink.result.?.replace_range);
    try std.testing.expectEqual(RequestMode.force, sink.result.?.refresh_mode);
    try std.testing.expect(sink.result.?.auto_accept_single_on_tab);
    try std.testing.expect(!sink.result.?.submit_on_confirm);
}

test "CombinedAutocompleteProvider apply consumes trailing quote when completing quoted path" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(&reg, "/tmp");
    const item = SelectItem{ .value = "\"two words.txt\"", .label = "two words.txt" };
    const result = provider.applyImpl("\"tw\"", 3, &item, .{ .start_byte = 0, .end_byte = 3 }).?;

    try std.testing.expectEqualStrings("\"two words.txt\"", result.replacement_text);
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 0, .end_byte = 4 }, result.replace_range.?);
}

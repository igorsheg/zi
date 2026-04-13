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
/// Sync providers publish immediately in request(). Providers that perform
/// incremental background work should defer publication until tick().
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
        next_deadline: ?*const fn (ptr: *anyopaque, now_ns: i128) ?i128 = null,
        tick: ?*const fn (ptr: *anyopaque, now_ns: i128, sink: SuggestionSink) bool = null,
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

    pub fn nextDeadline(self: AutocompleteProvider, now_ns: i128) ?i128 {
        if (self.vtable.next_deadline) |next| return next(self.ptr, now_ns);
        return null;
    }

    pub fn tick(self: AutocompleteProvider, now_ns: i128, sink: SuggestionSink) bool {
        if (self.vtable.tick) |tick_fn| return tick_fn(self.ptr, now_ns, sink);
        return false;
    }
};

const max_command_candidates = 256;
const max_path_candidates = 64;
const max_async_results = 20;
const max_async_scan_results = 100;
const max_async_output_bytes = 256 * 1024;
const max_path_bytes = 512;
const path_delimiters = [_]u8{ ' ', '\t', '"', '\'', '=' };
const attachment_debounce_ns: i128 = 20 * std.time.ns_per_ms;
const async_tick_interval_ns: i128 = 16 * std.time.ns_per_ms;
const async_pipe_poll_ms: i32 = 5;

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

const FuzzySearchPlan = struct {
    base_dir: []const u8,
    query: []const u8,
    display_base: []const u8,
    is_quoted_prefix: bool,
    replace_range: ReplaceRange,
    refresh_mode: RequestMode,
    auto_accept_single_on_tab: bool,
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

        const matched = search.plain.filter(prefix_after_slash, self.text_buf[0..n], &self.index_buf);
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
    allocator: std.mem.Allocator,
    registry: *const CommandRegistry,
    cwd: []const u8,

    command_names: [max_command_candidates][]const u8 = undefined,
    command_indices: [max_command_candidates]usize = undefined,
    path_indices: [max_path_candidates]usize = undefined,
    item_buf: [max_path_candidates]SelectItem = undefined,
    item_is_directory: [max_path_candidates]bool = .{false} ** max_path_candidates,
    value_storage: [max_path_candidates][max_path_bytes]u8 = undefined,
    label_storage: [max_path_candidates][max_path_bytes]u8 = undefined,
    description_storage: [max_path_candidates][max_path_bytes]u8 = undefined,
    temp_path_buf: [max_path_bytes]u8 = undefined,
    temp_dir_buf: [max_path_bytes]u8 = undefined,
    apply_buf: [max_path_bytes]u8 = undefined,
    async_search: AsyncSearch = .{},

    const AsyncCandidate = struct {
        relative_path: []const u8,
        is_directory: bool,
    };

    const AsyncPhase = enum {
        idle,
        debouncing,
        scanning,
    };

    const AsyncSearch = struct {
        arena: ?std.heap.ArenaAllocator = null,
        child: ?std.process.Child = null,
        stdout_buf: std.ArrayList(u8) = .empty,
        stderr_buf: std.ArrayList(u8) = .empty,
        candidates: std.ArrayList(AsyncCandidate) = .empty,
        replace_range: ReplaceRange = .{ .start_byte = 0, .end_byte = 0 },
        base_dir: []const u8 = "",
        display_base: []const u8 = "",
        query: []const u8 = "",
        is_quoted_prefix: bool = false,
        refresh_mode: RequestMode = .regular,
        auto_accept_single_on_tab: bool = false,
        phase: AsyncPhase = .idle,
        debounce_until_ns: i128 = 0,
        stdout_closed: bool = false,
        stderr_closed: bool = false,

        fn reset(self: *AsyncSearch) void {
            if (self.child) |*child| {
                _ = child.kill() catch {};
            }
            self.child = null;
            if (self.arena) |*arena| arena.deinit();
            self.arena = null;
            self.stdout_buf = .empty;
            self.stderr_buf = .empty;
            self.candidates = .empty;
            self.replace_range = .{ .start_byte = 0, .end_byte = 0 };
            self.base_dir = "";
            self.display_base = "";
            self.query = "";
            self.is_quoted_prefix = false;
            self.refresh_mode = .regular;
            self.auto_accept_single_on_tab = false;
            self.phase = .idle;
            self.debounce_until_ns = 0;
            self.stdout_closed = false;
            self.stderr_closed = false;
        }

        fn arenaAllocator(self: *AsyncSearch) std.mem.Allocator {
            return self.arena.?.allocator();
        }
    };

    const vtable = AutocompleteProvider.VTable{
        .request = @ptrCast(&requestImpl),
        .cancel = @ptrCast(&cancelImpl),
        .apply = @ptrCast(&applyImpl),
        .next_deadline = @ptrCast(&nextDeadlineImpl),
        .tick = @ptrCast(&tickImpl),
    };

    pub fn init(allocator: std.mem.Allocator, registry: *const CommandRegistry, cwd: []const u8) CombinedAutocompleteProvider {
        return .{
            .allocator = allocator,
            .registry = registry,
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *CombinedAutocompleteProvider) void {
        self.cancelAsyncSearch();
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
            const plan = self.resolveFuzzySearchPlan(token.prefix, line_start + token.start_offset, cursor, snapshot.mode) orelse {
                self.cancelAsyncSearch();
                sink.publish(null);
                return;
            };
            self.beginAsyncSearch(plan);
            return;
        }

        self.cancelAsyncSearch();

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

    fn cancelImpl(self: *CombinedAutocompleteProvider) void {
        self.cancelAsyncSearch();
    }

    fn nextDeadlineImpl(self: *CombinedAutocompleteProvider, now_ns: i128) ?i128 {
        return switch (self.async_search.phase) {
            .idle => null,
            .debouncing => self.async_search.debounce_until_ns,
            .scanning => now_ns + async_tick_interval_ns,
        };
    }

    fn tickImpl(self: *CombinedAutocompleteProvider, now_ns: i128, sink: SuggestionSink) bool {
        switch (self.async_search.phase) {
            .idle => return false,
            .debouncing => {
                if (now_ns < self.async_search.debounce_until_ns) return false;
                self.async_search.phase = .scanning;
            },
            .scanning => {},
        }

        if (!self.processAsyncSearchTick()) return false;

        const suggestions = self.finishAsyncSearch();
        sink.publish(suggestions);
        return true;
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

    fn resolveFuzzySearchPlan(self: *CombinedAutocompleteProvider, prefix: []const u8, replace_start_byte: u32, replace_end_byte: u32, mode: RequestMode) ?FuzzySearchPlan {
        const parsed = parsePathPrefix(prefix);
        if (!parsed.is_at_prefix) return null;

        var base_dir = self.cwd;
        var query = parsed.raw_prefix;
        var display_base: []const u8 = "";

        if (std.mem.lastIndexOfScalar(u8, parsed.raw_prefix, '/')) |slash_idx| {
            const scoped_display_base = parsed.raw_prefix[0 .. slash_idx + 1];
            const scoped_query = parsed.raw_prefix[slash_idx + 1 ..];
            if (self.resolveAbsolutePath(scoped_display_base)) |absolute_base| {
                if (isDirectoryAbsolute(absolute_base)) {
                    base_dir = absolute_base;
                    query = scoped_query;
                    display_base = scoped_display_base;
                }
            }
        }

        return .{
            .base_dir = base_dir,
            .query = query,
            .display_base = display_base,
            .is_quoted_prefix = parsed.is_quoted_prefix,
            .replace_range = .{ .start_byte = replace_start_byte, .end_byte = replace_end_byte },
            .refresh_mode = if (mode == .force) .force else .regular,
            .auto_accept_single_on_tab = mode == .force,
        };
    }

    fn beginAsyncSearch(self: *CombinedAutocompleteProvider, plan: FuzzySearchPlan) void {
        self.cancelAsyncSearch();

        self.async_search.arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = self.async_search.arenaAllocator();

        self.async_search.base_dir = arena.dupe(u8, plan.base_dir) catch {
            self.cancelAsyncSearch();
            return;
        };
        self.async_search.display_base = arena.dupe(u8, plan.display_base) catch {
            self.cancelAsyncSearch();
            return;
        };
        self.async_search.query = arena.dupe(u8, plan.query) catch {
            self.cancelAsyncSearch();
            return;
        };

        self.async_search.replace_range = plan.replace_range;
        self.async_search.is_quoted_prefix = plan.is_quoted_prefix;
        self.async_search.refresh_mode = plan.refresh_mode;
        self.async_search.auto_accept_single_on_tab = plan.auto_accept_single_on_tab;
        self.async_search.debounce_until_ns = std.time.nanoTimestamp() + if (plan.refresh_mode == .force) @as(i128, 0) else attachment_debounce_ns;
        self.async_search.phase = if (plan.refresh_mode == .force) .scanning else .debouncing;
        if (plan.refresh_mode == .force) {
            _ = self.startAsyncSearchProcess();
        }
    }

    fn processAsyncSearchTick(self: *CombinedAutocompleteProvider) bool {
        if (self.async_search.child == null) {
            if (!self.startAsyncSearchProcess()) return true;
        }

        if (self.async_search.child) |*child| {
            var round: usize = 0;
            while (round < 4) : (round += 1) {
                self.waitForAsyncPipeActivity(child);

                const stdout_len_before = self.async_search.stdout_buf.items.len;
                const stderr_len_before = self.async_search.stderr_buf.items.len;
                const stdout_closed_before = self.async_search.stdout_closed;
                const stderr_closed_before = self.async_search.stderr_closed;

                if (!self.async_search.stdout_closed) {
                    if (child.stdout) |stdout_file| {
                        self.drainAsyncPipe(stdout_file, &self.async_search.stdout_buf, &self.async_search.stdout_closed);
                    } else {
                        self.async_search.stdout_closed = true;
                    }
                }
                if (!self.async_search.stderr_closed) {
                    if (child.stderr) |stderr_file| {
                        self.drainAsyncPipe(stderr_file, &self.async_search.stderr_buf, &self.async_search.stderr_closed);
                    } else {
                        self.async_search.stderr_closed = true;
                    }
                }

                if (self.async_search.stdout_closed and self.async_search.stderr_closed) break;

                const progressed = self.async_search.stdout_buf.items.len != stdout_len_before or
                    self.async_search.stderr_buf.items.len != stderr_len_before or
                    self.async_search.stdout_closed != stdout_closed_before or
                    self.async_search.stderr_closed != stderr_closed_before;
                if (!progressed) break;
            }
        }

        return self.async_search.stdout_closed and self.async_search.stderr_closed;
    }

    fn startAsyncSearchProcess(self: *CombinedAutocompleteProvider) bool {
        if (self.spawnAsyncSearchProcess("fd")) return true;
        if (self.spawnAsyncSearchProcess("fdfind")) return true;
        self.async_search.stdout_closed = true;
        self.async_search.stderr_closed = true;
        return false;
    }

    fn spawnAsyncSearchProcess(self: *CombinedAutocompleteProvider, command: []const u8) bool {
        const arena = self.async_search.arenaAllocator();
        const fd_query = if (self.async_search.query.len > 0)
            buildFdPathQuery(arena, self.async_search.query) catch return false
        else
            null;

        var argv: [18][]const u8 = undefined;
        var argc: usize = 0;
        argv[argc] = command;
        argc += 1;
        argv[argc] = "--base-directory";
        argc += 1;
        argv[argc] = self.async_search.base_dir;
        argc += 1;
        argv[argc] = "--max-results";
        argc += 1;
        argv[argc] = "100";
        argc += 1;
        argv[argc] = "--type";
        argc += 1;
        argv[argc] = "f";
        argc += 1;
        argv[argc] = "--type";
        argc += 1;
        argv[argc] = "d";
        argc += 1;
        argv[argc] = "--full-path";
        argc += 1;
        argv[argc] = "--hidden";
        argc += 1;
        argv[argc] = "--exclude";
        argc += 1;
        argv[argc] = ".git";
        argc += 1;
        argv[argc] = "--exclude";
        argc += 1;
        argv[argc] = ".git/*";
        argc += 1;
        argv[argc] = "--exclude";
        argc += 1;
        argv[argc] = ".git/**";
        argc += 1;
        if (fd_query) |query| {
            argv[argc] = query;
            argc += 1;
        }

        var child = std.process.Child.init(argv[0..argc], self.allocator);
        child.expand_arg0 = .expand;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return false;
        child.waitForSpawn() catch {
            _ = child.wait() catch {};
            return false;
        };

        if (child.stdout) |stdout_file| {
            setNonblocking(stdout_file.handle) catch {
                _ = child.kill() catch {};
                return false;
            };
            self.async_search.stdout_closed = false;
        } else {
            self.async_search.stdout_closed = true;
        }
        if (child.stderr) |stderr_file| {
            setNonblocking(stderr_file.handle) catch {
                _ = child.kill() catch {};
                return false;
            };
            self.async_search.stderr_closed = false;
        } else {
            self.async_search.stderr_closed = true;
        }

        self.async_search.child = child;
        return true;
    }

    fn waitForAsyncPipeActivity(self: *CombinedAutocompleteProvider, child: *const std.process.Child) void {
        var pollfds: [2]std.posix.pollfd = undefined;
        var count: usize = 0;
        if (!self.async_search.stdout_closed) {
            if (child.stdout) |stdout_file| {
                pollfds[count] = .{ .fd = stdout_file.handle, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        if (!self.async_search.stderr_closed) {
            if (child.stderr) |stderr_file| {
                pollfds[count] = .{ .fd = stderr_file.handle, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        if (count == 0) return;

        _ = std.posix.poll(pollfds[0..count], async_pipe_poll_ms) catch {};
    }

    fn drainAsyncPipe(self: *CombinedAutocompleteProvider, file: std.fs.File, buffer: *std.ArrayList(u8), closed: *bool) void {
        const arena = self.async_search.arenaAllocator();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&chunk) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    closed.* = true;
                    return;
                },
            };
            if (n == 0) {
                closed.* = true;
                return;
            }
            if (buffer.items.len + n > max_async_output_bytes) {
                const remaining = max_async_output_bytes - buffer.items.len;
                if (remaining > 0) {
                    buffer.appendSlice(arena, chunk[0..remaining]) catch {};
                }
                closed.* = true;
                return;
            }
            buffer.appendSlice(arena, chunk[0..n]) catch {
                closed.* = true;
                return;
            };
        }
    }

    fn finishAsyncSearch(self: *CombinedAutocompleteProvider) ?Suggestions {
        defer self.cancelAsyncSearch();

        if (self.async_search.child) |*child| {
            _ = child.wait() catch {};
            self.async_search.child = null;
        }
        self.collectAsyncCandidates();
        if (self.async_search.candidates.items.len == 0) return null;

        var selected_indices: [max_async_results]usize = undefined;
        var selected_count: usize = 0;

        if (self.async_search.query.len == 0) {
            selected_count = @min(self.async_search.candidates.items.len, selected_indices.len);
            for (0..selected_count) |idx| selected_indices[idx] = idx;
        } else {
            const arena = self.async_search.arenaAllocator();
            const paths = arena.alloc([]const u8, self.async_search.candidates.items.len) catch return null;
            for (self.async_search.candidates.items, 0..) |candidate, idx| {
                paths[idx] = candidate.relative_path;
            }
            selected_count = search.path.filter(self.async_search.query, paths, &selected_indices);
            if (selected_count == 0) return null;
        }

        for (selected_indices[0..selected_count], 0..) |candidate_idx, out_idx| {
            const candidate = self.async_search.candidates.items[candidate_idx];
            const display_path = self.buildAsyncDisplayPath(out_idx, self.async_search.display_base, candidate.relative_path) orelse continue;
            const completion_value = self.buildCompletionValue(out_idx, display_path, candidate.is_directory, true, self.async_search.is_quoted_prefix) orelse continue;
            const label = self.buildLabel(out_idx, std.fs.path.basename(candidate.relative_path), candidate.is_directory) orelse continue;

            self.item_buf[out_idx] = .{
                .value = completion_value,
                .label = label,
                .description = display_path,
            };
            self.item_is_directory[out_idx] = candidate.is_directory;
        }

        return .{
            .items = self.item_buf[0..selected_count],
            .replace_range = self.async_search.replace_range,
            .submit_on_confirm = false,
            .refresh_mode = self.async_search.refresh_mode,
            .auto_accept_single_on_tab = self.async_search.auto_accept_single_on_tab,
        };
    }

    fn collectAsyncCandidates(self: *CombinedAutocompleteProvider) void {
        if (self.async_search.stdout_buf.items.len == 0) return;
        if (self.async_search.candidates.items.len > 0) return;

        const arena = self.async_search.arenaAllocator();
        var iter = std.mem.splitScalar(u8, self.async_search.stdout_buf.items, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;

            const has_trailing_separator = std.mem.endsWith(u8, line, "/");
            const normalized_path = if (has_trailing_separator) line[0 .. line.len - 1] else line;
            if (std.mem.eql(u8, normalized_path, ".git") or
                std.mem.startsWith(u8, normalized_path, ".git/") or
                std.mem.indexOf(u8, normalized_path, "/.git/") != null)
            {
                continue;
            }

            self.async_search.candidates.append(arena, .{
                .relative_path = normalized_path,
                .is_directory = has_trailing_separator,
            }) catch return;
            if (self.async_search.candidates.items.len >= max_async_scan_results) return;
        }
    }

    fn cancelAsyncSearch(self: *CombinedAutocompleteProvider) void {
        self.async_search.reset();
    }

    fn buildAsyncDisplayPath(self: *CombinedAutocompleteProvider, idx: usize, display_base: []const u8, relative_path: []const u8) ?[]const u8 {
        var builder = FixedBuilder{ .buf = self.description_storage[idx][0..] };
        if (display_base.len > 0) {
            if (!builder.append(display_base)) return null;
        }
        if (!builder.append(relative_path)) return null;
        return builder.written();
    }

    fn resolveAbsolutePath(self: *CombinedAutocompleteProvider, raw_path: []const u8) ?[]const u8 {
        if (raw_path.len == 0) return self.cwd;
        if (raw_path[0] == '/') return raw_path;
        if (std.mem.eql(u8, raw_path, "~") or std.mem.startsWith(u8, raw_path, "~/")) {
            return self.expandHomePath(raw_path);
        }

        var builder = FixedBuilder{ .buf = self.temp_dir_buf[0..] };
        return self.joinSearchDir(&builder, self.cwd, raw_path);
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

fn isDirectoryAbsolute(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    defer dir.close();
    return true;
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
        return .{ .start_offset = @intCast(token_start), .prefix = path_prefix };
    }

    if (std.mem.indexOfScalar(u8, path_prefix, '/')) |_| {
        return .{ .start_offset = @intCast(token_start), .prefix = path_prefix };
    }
    if (std.mem.startsWith(u8, path_prefix, ".") or std.mem.startsWith(u8, path_prefix, "~/")) {
        return .{ .start_offset = @intCast(token_start), .prefix = path_prefix };
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
        if (in_quotes) quote_start = idx;
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

fn buildFdPathQuery(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, query, '/')) |_| {
        const has_trailing_separator = std.mem.endsWith(u8, query, "/");
        const trimmed = std.mem.trim(u8, query, "/");
        if (trimmed.len == 0) return allocator.dupe(u8, query);

        var builder: std.ArrayList(u8) = .empty;
        errdefer builder.deinit(allocator);

        var first = true;
        var iter = std.mem.splitScalar(u8, trimmed, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            if (!first) try builder.appendSlice(allocator, "[\\\\/]");
            try appendEscapedRegex(&builder, allocator, segment);
            first = false;
        }

        if (first) return allocator.dupe(u8, query);
        if (has_trailing_separator) try builder.appendSlice(allocator, "[\\\\/]");
        return builder.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, query);
}

fn appendEscapedRegex(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '.', '*', '+', '?', '^', '$', '{', '}', '(', ')', '|', '[', ']', '\\' => {
                try builder.append(allocator, '\\');
                try builder.append(allocator, byte);
            },
            else => try builder.append(allocator, byte),
        }
    }
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
}

fn hasAsyncSearchBackend() bool {
    return commandExists("fd") or commandExists("fdfind");
}

fn commandExists(command: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ command, "--version" },
        .max_output_bytes = 1024,
    }) catch return false;
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
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

fn drainAsyncProvider(provider: *CombinedAutocompleteProvider, sink: SuggestionSink) bool {
    var now_ns: i128 = 0;
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        if (provider.tickImpl(now_ns, sink)) return true;
        now_ns += async_tick_interval_ns;
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

test "CombinedAutocompleteProvider regular prose does not trigger bare path suggestions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.md", .data = "hello" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, cwd);
    defer provider.deinit();
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "hello ", .cursor_byte = 6, .mode = .regular }, sink.sink());

    try std.testing.expect(sink.result == null);
}

test "CombinedAutocompleteProvider force tab completes slash command arguments with paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.md", .data = "hello" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, cwd);
    defer provider.deinit();
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "/open no", .cursor_byte = 8, .mode = .force }, sink.sink());

    try std.testing.expect(sink.result != null);
    try std.testing.expect(hasItem(sink.result.?.items, "notes.md"));
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 6, .end_byte = 8 }, sink.result.?.replace_range);
    try std.testing.expectEqual(RequestMode.force, sink.result.?.refresh_mode);
    try std.testing.expect(sink.result.?.auto_accept_single_on_tab);
    try std.testing.expect(!sink.result.?.submit_on_confirm);
}

test "CombinedAutocompleteProvider async at-file search publishes on tick" {
    if (!hasAsyncSearchBackend()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.md", .data = "hello" });
    try tmp.dir.makePath("docs");
    try tmp.dir.writeFile(.{ .sub_path = "docs/guide.md", .data = "hi" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, cwd);
    defer provider.deinit();
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "@gui", .cursor_byte = 4, .mode = .force }, sink.sink());
    try std.testing.expect(sink.result == null);
    try std.testing.expect(provider.nextDeadlineImpl(0) != null);

    try std.testing.expect(drainAsyncProvider(&provider, sink.sink()));
    try std.testing.expect(sink.result != null);
    try std.testing.expect(hasItem(sink.result.?.items, "@docs/guide.md"));
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 0, .end_byte = 4 }, sink.result.?.replace_range);
}

test "CombinedAutocompleteProvider replaces stale at-file request before tick publishes" {
    if (!hasAsyncSearchBackend()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "guide.md", .data = "hello" });
    try tmp.dir.writeFile(.{ .sub_path = "notes.md", .data = "world" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, cwd);
    defer provider.deinit();
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "@gu", .cursor_byte = 3, .mode = .force }, sink.sink());
    provider.requestImpl(.{ .text = "@no", .cursor_byte = 3, .mode = .force }, sink.sink());

    try std.testing.expect(drainAsyncProvider(&provider, sink.sink()));
    try std.testing.expect(sink.result != null);
    try std.testing.expect(hasItem(sink.result.?.items, "@notes.md"));
    try std.testing.expect(!hasItem(sink.result.?.items, "@guide.md"));
}

test "CombinedAutocompleteProvider async at-file search respects gitignore while keeping hidden paths except .git" {
    if (!hasAsyncSearchBackend()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "ignored/\n" });
    try tmp.dir.writeFile(.{ .sub_path = "visible.md", .data = "ok" });
    try tmp.dir.makePath("ignored");
    try tmp.dir.writeFile(.{ .sub_path = "ignored/secret.md", .data = "nope" });
    try tmp.dir.makePath(".pi");
    try tmp.dir.writeFile(.{ .sub_path = ".pi/config.json", .data = "{}" });
    try tmp.dir.makePath(".git");
    try tmp.dir.writeFile(.{ .sub_path = ".git/config", .data = "[core]" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, cwd);
    defer provider.deinit();
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "@", .cursor_byte = 1, .mode = .force }, sink.sink());
    try std.testing.expect(drainAsyncProvider(&provider, sink.sink()));
    try std.testing.expect(sink.result != null);
    try std.testing.expect(hasItem(sink.result.?.items, "@visible.md"));
    try std.testing.expect(hasItem(sink.result.?.items, "@.pi/"));
    try std.testing.expect(!hasItem(sink.result.?.items, "@ignored/secret.md"));
    try std.testing.expect(!hasItem(sink.result.?.items, "@.git/"));
}

test "CombinedAutocompleteProvider async at-file search excludes ignored scoped directories" {
    if (!hasAsyncSearchBackend()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "ignored/\n" });
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/keep.md", .data = "ok" });
    try tmp.dir.makePath("ignored/src");
    try tmp.dir.writeFile(.{ .sub_path = "ignored/src/secret.md", .data = "nope" });

    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, cwd);
    defer provider.deinit();
    var sink = TestSink{};

    provider.requestImpl(.{ .text = "@src/", .cursor_byte = 5, .mode = .force }, sink.sink());
    try std.testing.expect(drainAsyncProvider(&provider, sink.sink()));
    try std.testing.expect(sink.result != null);
    try std.testing.expect(hasItem(sink.result.?.items, "@src/keep.md"));
    try std.testing.expect(!hasItem(sink.result.?.items, "@ignored/src/secret.md"));
}

test "CombinedAutocompleteProvider apply consumes trailing quote when completing quoted path" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, &reg, "/tmp");
    defer provider.deinit();
    const item = SelectItem{ .value = "\"two words.txt\"", .label = "two words.txt" };
    const result = provider.applyImpl("\"tw\"", 3, &item, .{ .start_byte = 0, .end_byte = 3 }).?;

    try std.testing.expectEqualStrings("\"two words.txt\"", result.replacement_text);
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 0, .end_byte = 4 }, result.replace_range.?);
}

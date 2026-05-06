const std = @import("std");
const search = @import("../../search/root.zig");
const select_list_mod = @import("../components/select_list.zig");
const slash_commands_mod = @import("../../coding_agent/slash_commands.zig");

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
const max_async_scan_results = 300;
const max_local_path_scan_results = 300;
const max_path_bytes = 512;
const path_delimiters = [_]u8{ ' ', '\t', '"', '\'', '=' };
const attachment_debounce_ns: i128 = 20 * std.time.ns_per_ms;
const async_tick_interval_ns: i128 = 16 * std.time.ns_per_ms;

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

        var field_storage: [max_command_candidates][2]search.plain.Field = undefined;
        var rows: [max_command_candidates][]const search.plain.Field = undefined;
        for (0..n) |i| {
            const cmd = self.getCommand(i);
            field_storage[i][0] = .{ .name = "name", .text = cmd.name, .weight = 24 };
            field_storage[i][1] = .{ .name = "description", .text = cmd.description orelse "", .weight = -8 };
            rows[i] = field_storage[i][0..2];
        }
        const matched = search.plain.filterFields(prefix_after_slash, rows[0..n], &self.index_buf);
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
    io: std.Io,
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
        native_session: ?search.file_search.Session = null,
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
        scan_started: bool = false,

        fn reset(self: *AsyncSearch) void {
            if (self.native_session) |*session| {
                session.deinit();
            }
            self.native_session = null;
            if (self.arena) |*arena| arena.deinit();
            self.arena = null;
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
            self.scan_started = false;
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, registry: *const CommandRegistry, cwd: []const u8) CombinedAutocompleteProvider {
        return .{
            .allocator = allocator,
            .io = io,
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

        var field_storage: [max_command_candidates][2]search.plain.Field = undefined;
        var rows: [max_command_candidates][]const search.plain.Field = undefined;
        for (0..n) |i| {
            const cmd = self.getCommand(i);
            field_storage[i][0] = .{ .name = "name", .text = cmd.name, .weight = 24 };
            field_storage[i][1] = .{ .name = "description", .text = cmd.description orelse "", .weight = -8 };
            rows[i] = field_storage[i][0..2];
        }
        const matched = search.plain.filterFields(prefix_after_slash, rows[0..n], &self.command_indices);
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

        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, plan.search_dir, .{ .iterate = true }) catch return 0;
        defer dir.close(std.Options.debug_io);

        var name_storage: [max_local_path_scan_results][max_path_bytes]u8 = undefined;
        var candidates: [max_local_path_scan_results]search.path.Candidate = undefined;
        var candidate_count: usize = 0;

        var iter = dir.iterate();
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            if (candidate_count >= candidates.len) break;
            if (entry.name.len == 0 or entry.name.len > max_path_bytes) continue;

            var is_directory = entry.kind == .directory;
            if (!is_directory and entry.kind == .sym_link) {
                const stat: ?std.Io.File.Stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch null;
                if (stat) |value| {
                    is_directory = value.kind == .directory;
                }
            }

            @memcpy(name_storage[candidate_count][0..entry.name.len], entry.name);
            const name = name_storage[candidate_count][0..entry.name.len];
            candidates[candidate_count] = .{ .path = name, .is_directory = is_directory };
            candidate_count += 1;
        }

        var selected_indices: [max_path_candidates]usize = undefined;
        var selected_count: usize = 0;
        if (plan.search_prefix.len == 0) {
            selected_count = @min(candidate_count, selected_indices.len);
            for (0..selected_count) |i| selected_indices[i] = i;
            sortLocalPathCandidateIndices(selected_indices[0..selected_count], candidates[0..candidate_count]);
        } else {
            selected_count = search.path.filterCandidates(plan.search_prefix, candidates[0..candidate_count], &selected_indices);
        }

        const count = @min(selected_count, self.item_buf.len);
        for (selected_indices[0..count], 0..) |candidate_idx, out_idx| {
            const candidate = candidates[candidate_idx];
            const display_path = self.buildDisplayPath(out_idx, plan.display_prefix, candidate.path) orelse continue;
            const completion_value = self.buildCompletionValue(out_idx, display_path, candidate.is_directory, plan.is_at_prefix, plan.is_quoted_prefix) orelse continue;
            const label = self.buildLabel(out_idx, candidate.path, candidate.is_directory) orelse continue;

            self.item_buf[out_idx] = .{
                .value = completion_value,
                .label = label,
            };
            self.item_is_directory[out_idx] = candidate.is_directory;
        }

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
        self.async_search.debounce_until_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) + if (plan.refresh_mode == .force) @as(i128, 0) else attachment_debounce_ns;
        self.async_search.phase = if (plan.refresh_mode == .force) .scanning else .debouncing;
        if (plan.refresh_mode == .force) {
            _ = self.startAsyncSearchProcess();
        }
    }

    fn processAsyncSearchTick(self: *CombinedAutocompleteProvider) bool {
        if (!self.async_search.scan_started) {
            if (!self.startAsyncSearchProcess()) return true;
        }

        if (self.async_search.native_session) |*session| {
            const before = self.async_search.candidates.items.len;
            self.drainNativeSearch(session);
            if (session.done()) return true;
            return self.async_search.candidates.items.len != before;
        }

        return true;
    }

    fn startAsyncSearchProcess(self: *CombinedAutocompleteProvider) bool {
        self.async_search.scan_started = true;
        return self.startNativeFileSearch();
    }

    fn startNativeFileSearch(self: *CombinedAutocompleteProvider) bool {
        const arena = self.async_search.arenaAllocator();
        self.async_search.native_session = search.file_search.Session.start(arena, self.io, .{
            .base_dir = self.async_search.base_dir,
            .query = self.async_search.query,
            .max_results = max_async_scan_results,
            .include_files = true,
            .include_dirs = true,
            .include_hidden = true,
            .exclude_git = true,
        }) catch return false;

        return true;
    }

    fn drainNativeSearch(self: *CombinedAutocompleteProvider, session: *search.file_search.Session) void {
        const arena = self.async_search.arenaAllocator();
        var native_candidates = std.ArrayList(search.file_search.Candidate).empty;
        session.drain(arena, &native_candidates) catch return;
        for (native_candidates.items) |candidate| {
            self.async_search.candidates.append(arena, .{
                .relative_path = candidate.relative_path,
                .is_directory = candidate.is_directory,
            }) catch return;
        }
    }

    fn finishAsyncSearch(self: *CombinedAutocompleteProvider) ?Suggestions {
        defer self.cancelAsyncSearch();

        if (self.async_search.candidates.items.len == 0) return null;

        var selected_indices: [max_async_results]usize = undefined;
        var selected_count: usize = 0;

        if (self.async_search.query.len == 0) {
            selected_count = @min(self.async_search.candidates.items.len, selected_indices.len);
            for (0..selected_count) |idx| selected_indices[idx] = idx;
        } else {
            const arena = self.async_search.arenaAllocator();
            const candidates = arena.alloc(search.path.Candidate, self.async_search.candidates.items.len) catch return null;
            for (self.async_search.candidates.items, 0..) |candidate, idx| {
                candidates[idx] = .{ .path = candidate.relative_path, .is_directory = candidate.is_directory };
            }
            selected_count = search.path.filterCandidates(self.async_search.query, candidates, &selected_indices);
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
        const home = @import("env").get("HOME") orelse return null;
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
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch return false;
    defer dir.close(std.Options.debug_io);
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

fn sortLocalPathCandidateIndices(indices: []usize, candidates: []const search.path.Candidate) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const idx = indices[i];
        var j = i;
        while (j > 0 and localPathCandidateLessThan(idx, indices[j - 1], candidates)) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = idx;
    }
}

fn localPathCandidateLessThan(a_idx: usize, b_idx: usize, candidates: []const search.path.Candidate) bool {
    const a = candidates[a_idx];
    const b = candidates[b_idx];
    if (a.is_directory != b.is_directory) return a.is_directory;
    return asciiLessThanIgnoreCase(a.path, b.path);
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
    while (attempts < 10000) : (attempts += 1) {
        if (provider.tickImpl(now_ns, sink)) return true;
        std.Thread.yield() catch {};
        now_ns += async_tick_interval_ns;
    }
    return false;
}

test "SlashCommandProvider covers activation, filtering, and apply" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var provider = SlashCommandProvider.init(&reg);

    var filtered = TestSink{};
    provider.requestImpl(.{ .text = "/mo", .cursor_byte = 3 }, filtered.sink());
    try std.testing.expect(filtered.result != null);
    try std.testing.expect(hasItem(filtered.result.?.items, "model"));
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 0, .end_byte = 3 }, filtered.result.?.replace_range);
    try std.testing.expect(filtered.result.?.submit_on_confirm);

    var all = TestSink{};
    provider.requestImpl(.{ .text = "/", .cursor_byte = 1 }, all.sink());
    try std.testing.expect(all.result != null);
    try std.testing.expectEqual(reg.count(), all.result.?.items.len);

    var inactive = TestSink{};
    provider.requestImpl(.{ .text = "hello", .cursor_byte = 5 }, inactive.sink());
    try std.testing.expect(inactive.result == null);

    var multiline = TestSink{};
    provider.requestImpl(.{ .text = "/model\n/", .cursor_byte = 8 }, multiline.sink());
    try std.testing.expect(multiline.result == null);

    const item = SelectItem{ .value = "model", .label = "model" };
    const result = provider.applyImpl("/mo", 3, &item, .{ .start_byte = 0, .end_byte = 3 });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/model ", result.?.replacement_text);
    try std.testing.expectEqual(@as(u32, 7), result.?.cursor_in_replacement);
}

test "CombinedAutocompleteProvider covers path activation and forced slash arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "notes.md", .data = "hello" });
    try tmp.dir.createDirPath(std.Options.debug_io, "docs");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "docs/guide.md", .data = "hi" });

    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, std.Options.debug_io, &reg, cwd);
    defer provider.deinit();

    var prose = TestSink{};
    provider.requestImpl(.{ .text = "hello ", .cursor_byte = 6, .mode = .regular }, prose.sink());
    try std.testing.expect(prose.result == null);

    var slash_args = TestSink{};
    provider.requestImpl(.{ .text = "/open no", .cursor_byte = 8, .mode = .force }, slash_args.sink());
    try std.testing.expect(slash_args.result != null);
    try std.testing.expect(hasItem(slash_args.result.?.items, "notes.md"));
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 6, .end_byte = 8 }, slash_args.result.?.replace_range);
    try std.testing.expectEqual(RequestMode.force, slash_args.result.?.refresh_mode);
    try std.testing.expect(slash_args.result.?.auto_accept_single_on_tab);
    try std.testing.expect(!slash_args.result.?.submit_on_confirm);

    var regular_path = TestSink{};
    provider.requestImpl(.{ .text = "see ./do", .cursor_byte = 8, .mode = .regular }, regular_path.sink());
    try std.testing.expect(regular_path.result != null);
    try std.testing.expect(hasItem(regular_path.result.?.items, "./docs/"));
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 4, .end_byte = 8 }, regular_path.result.?.replace_range);
}

test "CombinedAutocompleteProvider async at-file search respects ignore and hidden path boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".gitignore", .data = "ignored/\n" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "visible.md", .data = "ok" });
    try tmp.dir.createDirPath(std.Options.debug_io, "ignored");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "ignored/secret.md", .data = "nope" });
    try tmp.dir.createDirPath(std.Options.debug_io, ".pi");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".pi/config.json", .data = "{}" });
    try tmp.dir.createDirPath(std.Options.debug_io, ".git");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".git/config", .data = "[core]" });

    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, std.Options.debug_io, &reg, cwd);
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

test "CombinedAutocompleteProvider apply consumes trailing quote when completing quoted path" {
    var reg = CommandRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var provider = CombinedAutocompleteProvider.init(std.testing.allocator, std.Options.debug_io, &reg, "/tmp");
    defer provider.deinit();
    const item = SelectItem{ .value = "\"two words.txt\"", .label = "two words.txt" };
    const result = provider.applyImpl("\"tw\"", 3, &item, .{ .start_byte = 0, .end_byte = 3 }).?;

    try std.testing.expectEqualStrings("\"two words.txt\"", result.replacement_text);
    try std.testing.expectEqual(ReplaceRange{ .start_byte = 0, .end_byte = 4 }, result.replace_range.?);
}

const std = @import("std");

pub const TextSpan = struct {
    text: []const u8,
    fg: ?[]const u8 = null,
    dim: bool = false,
};

pub const PromptKind = enum {
    confirm,
    select,
    input,
    editor,
};

pub const SelectOption = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    search: ?[]const u8 = null,
    preview: ?[]const u8 = null,
};

pub const PromptRequest = struct {
    state_owner_id: []const u8,
    generation: u64,
    id: []const u8,
    kind: PromptKind,
    title: []const u8,
    message: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    empty_text: ?[]const u8 = null,
    prefill: ?[]const u8 = null,
    options: []const SelectOption = &.{},
    timeout_ms: ?u64 = null,

    pub fn clone(allocator: std.mem.Allocator, prompt: PromptRequest) !PromptRequest {
        const state_owner_id = try allocator.dupe(u8, prompt.state_owner_id);
        errdefer allocator.free(state_owner_id);
        const id = try allocator.dupe(u8, prompt.id);
        errdefer allocator.free(id);
        const title = try allocator.dupe(u8, prompt.title);
        errdefer allocator.free(title);
        const message = if (prompt.message) |value| try allocator.dupe(u8, value) else null;
        errdefer if (message) |value| allocator.free(value);
        const placeholder = if (prompt.placeholder) |value| try allocator.dupe(u8, value) else null;
        errdefer if (placeholder) |value| allocator.free(value);
        const empty_text = if (prompt.empty_text) |value| try allocator.dupe(u8, value) else null;
        errdefer if (empty_text) |value| allocator.free(value);
        const prefill = if (prompt.prefill) |value| try allocator.dupe(u8, value) else null;
        errdefer if (prefill) |value| allocator.free(value);

        const options = try allocator.alloc(SelectOption, prompt.options.len);
        var initialized_options: usize = 0;
        errdefer freeOptions(allocator, options, initialized_options);
        for (prompt.options, 0..) |option, i| {
            options[i] = .{
                .id = try allocator.dupe(u8, option.id),
                .label = try allocator.dupe(u8, option.label),
                .description = if (option.description) |value| try allocator.dupe(u8, value) else null,
                .search = if (option.search) |value| try allocator.dupe(u8, value) else null,
                .preview = if (option.preview) |value| try allocator.dupe(u8, value) else null,
            };
            initialized_options += 1;
        }

        return .{
            .state_owner_id = state_owner_id,
            .generation = prompt.generation,
            .id = id,
            .kind = prompt.kind,
            .title = title,
            .message = message,
            .placeholder = placeholder,
            .empty_text = empty_text,
            .prefill = prefill,
            .options = options,
            .timeout_ms = prompt.timeout_ms,
        };
    }

    pub fn deinit(self: *PromptRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id);
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.message) |value| allocator.free(value);
        if (self.placeholder) |value| allocator.free(value);
        if (self.empty_text) |value| allocator.free(value);
        if (self.prefill) |value| allocator.free(value);
        freeOptions(allocator, self.options, self.options.len);
        self.* = undefined;
    }
};

pub const EditorActionKind = enum {
    set_text,
    paste_text,
    clear_text,
    get_text,
};

pub const EditorAction = struct {
    state_owner_id: []const u8,
    generation: u64,
    kind: EditorActionKind,
    text: ?[]const u8 = null,

    pub fn clone(allocator: std.mem.Allocator, action: EditorAction) !EditorAction {
        const state_owner_id = try allocator.dupe(u8, action.state_owner_id);
        errdefer allocator.free(state_owner_id);
        return .{
            .state_owner_id = state_owner_id,
            .generation = action.generation,
            .kind = action.kind,
            .text = if (action.text) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *EditorAction, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id);
        if (self.text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const UiPublicationKind = enum {
    message,
    status,
    progress,
};

pub const ProgressStatus = enum {
    running,
    done,
    @"error",
    cancelled,
};

pub const UiLifetime = enum {
    session,
    until_input,
};

pub const UiPublication = struct {
    state_owner_id: []const u8,
    generation: u64,
    kind: UiPublicationKind,
    id: []const u8,
    text: ?[]const u8 = null,
    classification: ?[]const u8 = null,
    progress_status: ?ProgressStatus = null,
    title: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    current: ?i64 = null,
    total: ?i64 = null,
    indeterminate: bool = false,
    lifetime: UiLifetime = .session,

    pub fn clone(allocator: std.mem.Allocator, update: UiPublication) !UiPublication {
        const state_owner_id = try allocator.dupe(u8, update.state_owner_id);
        errdefer allocator.free(state_owner_id);
        const id = try allocator.dupe(u8, update.id);
        errdefer allocator.free(id);
        const text = if (update.text) |value| try allocator.dupe(u8, value) else null;
        errdefer if (text) |value| allocator.free(value);
        const classification = if (update.classification) |value| try allocator.dupe(u8, value) else null;
        errdefer if (classification) |value| allocator.free(value);
        const title = if (update.title) |value| try allocator.dupe(u8, value) else null;
        errdefer if (title) |value| allocator.free(value);
        const detail = if (update.detail) |value| try allocator.dupe(u8, value) else null;
        return .{
            .state_owner_id = state_owner_id,
            .generation = update.generation,
            .kind = update.kind,
            .id = id,
            .text = text,
            .classification = classification,
            .progress_status = update.progress_status,
            .title = title,
            .detail = detail,
            .current = update.current,
            .total = update.total,
            .indeterminate = update.indeterminate,
            .lifetime = update.lifetime,
        };
    }

    pub fn deinit(self: *UiPublication, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id);
        allocator.free(self.id);
        if (self.text) |value| allocator.free(value);
        if (self.classification) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        if (self.detail) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Report = struct {
    state_owner_id: []const u8,
    generation: u64,
    id: []const u8,
    title: []const u8,
    lines: []const []const TextSpan,
    transient: bool = false,

    pub fn clone(allocator: std.mem.Allocator, report: Report) !Report {
        const state_owner_id = try allocator.dupe(u8, report.state_owner_id);
        errdefer allocator.free(state_owner_id);
        const id = try allocator.dupe(u8, report.id);
        errdefer allocator.free(id);
        const title = try allocator.dupe(u8, report.title);
        errdefer allocator.free(title);

        const lines = try allocator.alloc([]const TextSpan, report.lines.len);
        var initialized_lines: usize = 0;
        errdefer freeLines(allocator, lines, initialized_lines);

        for (report.lines, 0..) |line, i| {
            lines[i] = try cloneLine(allocator, line);
            initialized_lines += 1;
        }

        return .{
            .state_owner_id = state_owner_id,
            .generation = report.generation,
            .id = id,
            .title = title,
            .lines = lines,
            .transient = report.transient,
        };
    }

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id);
        allocator.free(self.id);
        allocator.free(self.title);
        freeLines(allocator, self.lines, self.lines.len);
        self.* = undefined;
    }

    pub fn flattenText(self: Report, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (self.title.len > 0) {
            try out.appendSlice(allocator, self.title);
            try out.append(allocator, '\n');
        }

        try appendLines(&out, allocator, self.lines);
        return try out.toOwnedSlice(allocator);
    }
};

fn flattenLines(allocator: std.mem.Allocator, lines: []const []const TextSpan) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendLines(&out, allocator, lines);
    return try out.toOwnedSlice(allocator);
}

fn appendLines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lines: []const []const TextSpan) !void {
    for (lines, 0..) |line, line_i| {
        for (line) |span| try out.appendSlice(allocator, span.text);
        if (line_i + 1 < lines.len) try out.append(allocator, '\n');
    }
}

fn freeOptions(allocator: std.mem.Allocator, options: []const SelectOption, count: usize) void {
    for (options[0..count]) |option| {
        allocator.free(option.id);
        allocator.free(option.label);
        if (option.description) |value| allocator.free(value);
        if (option.search) |value| allocator.free(value);
        if (option.preview) |value| allocator.free(value);
    }
    allocator.free(options);
}

fn cloneLine(allocator: std.mem.Allocator, line: []const TextSpan) ![]const TextSpan {
    const spans = try allocator.alloc(TextSpan, line.len);
    var initialized_spans: usize = 0;
    errdefer freeSpans(allocator, spans, initialized_spans);

    for (line, 0..) |span, i| {
        spans[i] = try cloneSpan(allocator, span);
        initialized_spans += 1;
    }
    return spans;
}

fn cloneSpan(allocator: std.mem.Allocator, span: TextSpan) !TextSpan {
    const text = try allocator.dupe(u8, span.text);
    errdefer allocator.free(text);
    const fg = if (span.fg) |fg_value| try allocator.dupe(u8, fg_value) else null;
    return .{ .text = text, .fg = fg, .dim = span.dim };
}

fn freeLines(allocator: std.mem.Allocator, lines: []const []const TextSpan, count: usize) void {
    for (lines[0..count]) |line| freeSpans(allocator, line, line.len);
    allocator.free(lines);
}

fn freeSpans(allocator: std.mem.Allocator, spans: []const TextSpan, count: usize) void {
    for (spans[0..count]) |span| {
        allocator.free(span.text);
        if (span.fg) |fg| allocator.free(fg);
    }
    allocator.free(spans);
}

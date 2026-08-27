const std = @import("std");
const Item = @import("Item.zig").Item;
const Provider = @import("Provider.zig");
const Retry = @import("Retry.zig");
const StreamEvent = @import("StreamEvent.zig").StreamEvent;
const Usage = @import("Usage.zig");

const text_chunk_bytes: usize = 16;
const fgets_buffer_bytes: usize = 8192;
const line_fragment_bytes: usize = fgets_buffer_bytes - 1;
const cwd_token = "{{CWD}}";
const DeltaKind = enum { text, reasoning };

// Script diagnostics go to stderr exactly like hax's mock provider, but the
// Zig 0.16 test runner (zig build test --listen) flags any stderr write as a
// dirty run even when every test passes. Under tests the warnings stay silent;
// they still appear when the provider runs against a live session.
fn warnScript(comptime format: []const u8, args: anytype) void {
    if (@import("builtin").is_test) return;
    std.debug.print(format, args);
}

pub const Config = struct {
    /// Borrowed; must outlive the adapter. Null selects interactive mode.
    script_path: ?[]const u8 = null,
};

/// Mutable cross-request state owned by the caller (ProviderFactory.Owner).
pub const State = struct {
    next_script_turn: usize = 0,
};

pub const Mock = struct {
    config: Config,
    state: *State,

    pub fn init(config: Config, state: *State) Mock {
        return .{ .config = config, .state = state };
    }

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Mock,
        request: Provider.Request,
        sink: Provider.EventSink,
    ) Provider.StreamError!void {
        const script_path = self.config.script_path orelse {
            return interactiveResponse(allocator, io, request, sink);
        };

        var script = std.Io.Dir.cwd().openFile(io, script_path, .{}) catch |err| {
            const message = try std.fmt.allocPrint(
                allocator,
                "mock: cannot open '{s}': {s}",
                .{ script_path, @errorName(err) },
            );
            defer allocator.free(message);
            try sink.emit(.{ .failure = .{ .message = message } });
            return;
        };
        defer script.close(io);

        var reader_buffer: [fgets_buffer_bytes]u8 = undefined;
        var file_reader = script.reader(io, &reader_buffer);
        if (!try skipScriptTurns(&file_reader.interface, self.state.next_script_turn, request.tick)) {
            try emitScriptExhausted(io, request.tick, sink);
            return;
        }

        switch (try playScriptTurn(allocator, io, &file_reader.interface, request.tick, sink)) {
            .complete => self.state.next_script_turn +|= 1,
            .exhausted => try emitScriptExhausted(io, request.tick, sink),
        }
    }
};

const OwnedBytes = struct {
    allocation: []u8,
    bytes: []const u8,

    fn deinit(self: *OwnedBytes, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
        self.* = undefined;
    }
};

const ScriptResult = enum {
    complete,
    exhausted,
};

fn pollTick(tick: ?Provider.Tick) Provider.StreamError!void {
    if (tick) |value| value.poll() catch return error.Cancelled;
}

fn cancellableSleep(io: std.Io, tick: ?Provider.Tick, delay_ms: u64) Provider.StreamError!void {
    var plan = Retry.SleepPlan.init(delay_ms);
    while (plan.needsPoll()) {
        try pollTick(tick);
        const slice = plan.next() orelse break;
        io.sleep(.fromMilliseconds(@intCast(slice)), .awake) catch return error.Cancelled;
    }
}

fn emitChunked(
    io: std.Io,
    tick: ?Provider.Tick,
    sink: Provider.EventSink,
    text: []const u8,
    delay_ms: u64,
    comptime kind: DeltaKind,
) Provider.StreamError!void {
    var offset: usize = 0;
    var chunk: [text_chunk_bytes]u8 = undefined;
    while (offset < text.len) {
        try pollTick(tick);

        var chunk_len = @min(text_chunk_bytes, text.len - offset);
        if (offset + chunk_len < text.len) {
            while (chunk_len > 0 and isUtf8Continuation(text[offset + chunk_len])) {
                chunk_len -= 1;
            }
            // A full window of continuation bytes is malformed; preserve progress.
            if (chunk_len == 0) chunk_len = @min(text_chunk_bytes, text.len - offset);
        }

        @memcpy(chunk[0..chunk_len], text[offset .. offset + chunk_len]);
        switch (kind) {
            .text => try sink.emit(.{ .text_delta = chunk[0..chunk_len] }),
            .reasoning => try sink.emit(.{ .reasoning_delta = chunk[0..chunk_len] }),
        }
        offset += chunk_len;
        if (offset < text.len) try cancellableSleep(io, tick, delay_ms);
    }
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn emitScriptText(
    allocator: std.mem.Allocator,
    io: std.Io,
    tick: ?Provider.Tick,
    sink: Provider.EventSink,
    raw: []const u8,
    delay_ms: u64,
    comptime kind: DeltaKind,
) Provider.StreamError!void {
    try cancellableSleep(io, tick, delay_ms);
    var decoded = try decodeEscapes(allocator, raw);
    defer decoded.deinit(allocator);
    var expanded = try expandCwd(allocator, io, decoded.bytes);
    defer expanded.deinit(allocator);
    try emitChunked(io, tick, sink, expanded.bytes, delay_ms, kind);
}

fn emitToolCall(
    io: std.Io,
    tick: ?Provider.Tick,
    sink: Provider.EventSink,
    name: []const u8,
    arguments: []const u8,
    delay_ms: u64,
    delay_before_start: bool,
) Provider.StreamError!void {
    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    var id_storage: [36]u8 = undefined;
    const id = formatUuid(&id_storage, random_bytes);

    if (delay_before_start) try cancellableSleep(io, tick, delay_ms);
    try sink.emit(.{ .tool_call_start = .{ .id = id, .name = name } });
    try cancellableSleep(io, tick, delay_ms);
    try sink.emit(.{ .tool_call_delta = .{ .id = id, .arguments_delta = arguments } });
    try sink.emit(.{ .tool_call_end = id });
}

fn formatUuid(output: *[36]u8, bytes: [16]u8) []const u8 {
    const hex = "0123456789abcdef";
    var output_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            output[output_index] = '-';
            output_index += 1;
        }
        output[output_index] = hex[byte >> 4];
        output[output_index + 1] = hex[byte & 0x0f];
        output_index += 2;
    }
    std.debug.assert(output_index == output.len);
    return output[0..];
}

fn emitDone(sink: Provider.EventSink, usage: Usage.StreamUsage) Provider.StreamError!void {
    try sink.emit(.{ .done = .{ .stop_reason = "end_turn", .usage = usage } });
}

fn emitScriptExhausted(io: std.Io, tick: ?Provider.Tick, sink: Provider.EventSink) Provider.StreamError!void {
    try emitChunked(io, tick, sink, "Script exhausted — no more turns.", 0, .text);
    try emitDone(sink, .{});
}

fn skipScriptTurns(
    reader: *std.Io.Reader,
    count: usize,
    tick: ?Provider.Tick,
) Provider.StreamError!bool {
    var line_storage: [line_fragment_bytes]u8 = undefined;
    var skipped: usize = 0;
    while (skipped < count) {
        const line = try nextScriptLine(reader, &line_storage) orelse return false;
        try pollTick(tick);
        if (matchDirective(skipWhitespace(line), "end-turn", null)) skipped += 1;
    }
    return true;
}

fn playScriptTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    tick: ?Provider.Tick,
    sink: Provider.EventSink,
) Provider.StreamError!ScriptResult {
    var line_storage: [line_fragment_bytes]u8 = undefined;
    var delay_ms: u64 = 0;
    var usage: Usage.StreamUsage = .{};
    var saw_directive = false;

    while (true) {
        const line = try nextScriptLine(reader, &line_storage) orelse break;
        try pollTick(tick);
        if (lineIsBlankOrComment(line)) continue;

        const directive = skipWhitespace(line);
        if (matchDirective(directive, "end-turn", null)) {
            try emitDone(sink, usage);
            return .complete;
        }

        saw_directive = true;
        var argument: []const u8 = "";
        if (matchDirective(directive, "delay", &argument)) {
            delay_ms = parseDelay(argument);
        } else if (matchDirective(directive, "text", &argument)) {
            try emitScriptText(allocator, io, tick, sink, argument, delay_ms, .text);
        } else if (matchDirective(directive, "reasoning", &argument)) {
            try emitScriptText(allocator, io, tick, sink, argument, delay_ms, .reasoning);
        } else if (matchDirective(directive, "space", null)) {
            try cancellableSleep(io, tick, delay_ms);
            try sink.emit(.{ .text_delta = " " });
        } else if (matchDirective(directive, "tool", &argument)) {
            try emitScriptToolWithAllocator(allocator, io, tick, sink, argument, line, delay_ms);
        } else if (matchDirective(directive, "usage", &argument)) {
            usage = parseUsage(argument);
        } else {
            warnScript("zi mock: unknown directive: {s}\n", .{line});
        }
    }

    if (!saw_directive) return .exhausted;
    try emitDone(sink, usage);
    return .complete;
}

fn nextScriptLine(reader: *std.Io.Reader, fragment_storage: *[line_fragment_bytes]u8) Provider.StreamError!?[]const u8 {
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return nextLongScriptLine(reader, fragment_storage),
        error.ReadFailed => return error.InvalidProviderResponse,
    };
    if (line) |value| {
        // `takeDelimiter` can return a final unterminated buffer whose length
        // equals the reader capacity. Split that edge case just as fgets does.
        if (value.len > fragment_storage.len) {
            const remainder = value.len - fragment_storage.len;
            std.debug.assert(remainder <= reader.seek);
            @memcpy(fragment_storage, value[0..fragment_storage.len]);
            reader.seek -= remainder;
            return stripTrailingEol(fragment_storage);
        }
        return stripTrailingEol(value);
    }
    return null;
}

fn nextLongScriptLine(
    reader: *std.Io.Reader,
    fragment_storage: *[line_fragment_bytes]u8,
) Provider.StreamError!?[]const u8 {
    var writer = std.Io.Writer.fixed(fragment_storage);
    _ = reader.streamDelimiterLimit(&writer, '\n', .limited(fragment_storage.len)) catch |err| switch (err) {
        error.StreamTooLong => return stripTrailingEol(writer.buffered()),
        error.ReadFailed, error.WriteFailed => return error.InvalidProviderResponse,
    };
    if (reader.bufferedLen() > 0 and reader.buffered()[0] == '\n') reader.toss(1);
    return stripTrailingEol(writer.buffered());
}

fn stripTrailingEol(line: []const u8) []const u8 {
    var length = line.len;
    while (length > 0 and (line[length - 1] == '\n' or line[length - 1] == '\r')) length -= 1;
    return line[0..length];
}

fn skipWhitespace(line: []const u8) []const u8 {
    return line[skipWhitespaceIndex(line, 0)..];
}

fn skipWhitespaceIndex(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    return index;
}

fn lineIsBlankOrComment(line: []const u8) bool {
    const trimmed = skipWhitespace(line);
    return trimmed.len == 0 or trimmed[0] == '#';
}

fn matchDirective(line: []const u8, name: []const u8, argument: ?*[]const u8) bool {
    if (line.len < name.len or !std.mem.eql(u8, line[0..name.len], name)) return false;
    if (line.len != name.len and line[name.len] != ' ' and line[name.len] != '\t') return false;
    if (argument) |value| value.* = skipWhitespace(line[name.len..]);
    return true;
}

fn parseDelay(spec: []const u8) u64 {
    const token = firstToken(spec);
    const value = parseDecimal(i64, token) orelse return 0;
    if (value < 0) return 0;
    return @intCast(value);
}

fn parseDecimal(comptime Int: type, token: []const u8) ?Int {
    if (token.len == 0) return null;
    var first_digit: usize = 0;
    if (token[0] == '+' or token[0] == '-') first_digit = 1;
    if (first_digit == token.len) return null;
    for (token[first_digit..]) |byte| {
        if (byte < '0' or byte > '9') return null;
    }
    return std.fmt.parseInt(Int, token, 10) catch null;
}

fn parseUsage(spec: []const u8) Usage.StreamUsage {
    var usage: Usage.StreamUsage = .{};
    var cursor: usize = 0;
    while (cursor < spec.len) {
        cursor = skipWhitespaceIndex(spec, cursor);
        if (cursor == spec.len) break;
        const token_start = cursor;
        while (cursor < spec.len and spec[cursor] != ' ' and spec[cursor] != '\t') cursor += 1;
        const token = spec[token_start..cursor];
        const separator = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..separator];
        const value = token[separator + 1 ..];

        if (std.mem.eql(u8, key, "in") or std.mem.eql(u8, key, "input")) {
            if (parseDecimal(u64, value)) |parsed| usage.input_tokens = parsed else usage.input_tokens = null;
        } else if (std.mem.eql(u8, key, "out") or std.mem.eql(u8, key, "output")) {
            if (parseDecimal(u64, value)) |parsed| usage.output_tokens = parsed else usage.output_tokens = null;
        } else if (std.mem.eql(u8, key, "cached")) {
            if (parseDecimal(u64, value)) |parsed| usage.cached_tokens = parsed else usage.cached_tokens = null;
        } else if (std.mem.eql(u8, key, "cache_write")) {
            if (parseDecimal(u64, value)) |parsed| usage.cache_write_tokens = parsed else usage.cache_write_tokens = null;
        } else if (std.mem.eql(u8, key, "cache_write_1h")) {
            if (parseDecimal(u64, value)) |parsed| usage.cache_write_1h_tokens = parsed else usage.cache_write_1h_tokens = null;
        } else if (std.mem.eql(u8, key, "cost")) {
            if (std.mem.indexOfScalar(u8, value, '_') == null) {
                if (std.fmt.parseFloat(f64, value)) |parsed| usage.cost_usd = parsed else |_| {}
            }
        }
    }
    return usage;
}

fn firstToken(spec: []const u8) []const u8 {
    const start = skipWhitespaceIndex(spec, 0);
    var end = start;
    while (end < spec.len and spec[end] != ' ' and spec[end] != '\t') end += 1;
    return spec[start..end];
}

fn decodeEscapes(allocator: std.mem.Allocator, text: []const u8) Provider.StreamError!OwnedBytes {
    const allocation = try allocator.alloc(u8, text.len);
    var output: usize = 0;
    var input: usize = 0;
    while (input < text.len) {
        if (text[input] == '\\' and input + 1 < text.len) {
            switch (text[input + 1]) {
                'n' => {
                    allocation[output] = '\n';
                    output += 1;
                    input += 2;
                    continue;
                },
                't' => {
                    allocation[output] = '\t';
                    output += 1;
                    input += 2;
                    continue;
                },
                '\\' => {
                    allocation[output] = '\\';
                    output += 1;
                    input += 2;
                    continue;
                },
                else => {},
            }
        }
        allocation[output] = text[input];
        output += 1;
        input += 1;
    }
    return .{ .allocation = allocation, .bytes = allocation[0..output] };
}

fn duplicateOwned(allocator: std.mem.Allocator, text: []const u8) Provider.StreamError!OwnedBytes {
    const allocation = try allocator.dupe(u8, text);
    return .{ .allocation = allocation, .bytes = allocation };
}

fn expandCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
) Provider.StreamError!OwnedBytes {
    if (std.mem.indexOf(u8, text, cwd_token) == null) return duplicateOwned(allocator, text);

    var cwd_storage: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = std.process.currentPath(io, &cwd_storage) catch return duplicateOwned(allocator, text);
    const cwd = cwd_storage[0..cwd_length];

    var output_length: usize = text.len;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, cwd_token)) |index| {
        output_length = std.math.sub(usize, output_length, cwd_token.len) catch return error.OutOfMemory;
        output_length = std.math.add(usize, output_length, cwd.len) catch return error.OutOfMemory;
        search_from = index + cwd_token.len;
    }

    const allocation = try allocator.alloc(u8, output_length);
    var output: usize = 0;
    var input: usize = 0;
    while (std.mem.indexOfPos(u8, text, input, cwd_token)) |index| {
        const prefix = text[input..index];
        @memcpy(allocation[output .. output + prefix.len], prefix);
        output += prefix.len;
        @memcpy(allocation[output .. output + cwd.len], cwd);
        output += cwd.len;
        input = index + cwd_token.len;
    }
    const suffix = text[input..];
    @memcpy(allocation[output .. output + suffix.len], suffix);
    output += suffix.len;
    std.debug.assert(output == allocation.len);
    return .{ .allocation = allocation, .bytes = allocation };
}

fn lastContentItem(items: []const Item) ?*const Item {
    var index = items.len;
    while (index > 0) {
        index -= 1;
        switch (items[index]) {
            .turn_boundary, .turn_usage => {},
            else => return &items[index],
        }
    }
    return null;
}

fn lastUserText(items: []const Item) ?[]const u8 {
    var index = items.len;
    while (index > 0) {
        index -= 1;
        switch (items[index]) {
            .user_message => |message| return message.text,
            else => {},
        }
    }
    return null;
}

fn messageStartsWith(message: []const u8, verb: []const u8) bool {
    const trimmed = skipWhitespace(message);
    if (trimmed.len < verb.len or !std.ascii.eqlIgnoreCase(trimmed[0..verb.len], verb)) return false;
    if (trimmed.len == verb.len) return true;
    return trimmed[verb.len] == ' ' or trimmed[verb.len] == '\t' or trimmed[verb.len] == '`';
}

fn extractBacktickText(message: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, message, '`') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, message, open + 1, '`') orelse return null;
    return message[open + 1 .. close];
}

fn contextHasTool(context: Provider.Context, name: []const u8) bool {
    for (context.tools) |tool| if (std.mem.eql(u8, tool.name, name)) return true;
    return false;
}

fn escapeJsonString(allocator: std.mem.Allocator, text: []const u8) Provider.StreamError!OwnedBytes {
    const hex = "0123456789abcdef";
    var output_length: usize = 0;
    for (text) |byte| {
        const addition: usize = switch (byte) {
            '"', '\\' => 2,
            '\n', '\r', '\t', '\x08', '\x0c' => 2,
            0...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        };
        output_length = std.math.add(usize, output_length, addition) catch return error.OutOfMemory;
    }

    const allocation = try allocator.alloc(u8, output_length);
    var output: usize = 0;
    for (text) |byte| {
        switch (byte) {
            '"' => {
                allocation[output] = '\\';
                allocation[output + 1] = '"';
                output += 2;
            },
            '\\' => {
                allocation[output] = '\\';
                allocation[output + 1] = '\\';
                output += 2;
            },
            '\n' => {
                allocation[output] = '\\';
                allocation[output + 1] = 'n';
                output += 2;
            },
            '\r' => {
                allocation[output] = '\\';
                allocation[output + 1] = 'r';
                output += 2;
            },
            '\t' => {
                allocation[output] = '\\';
                allocation[output + 1] = 't';
                output += 2;
            },
            '\x08' => {
                allocation[output] = '\\';
                allocation[output + 1] = 'b';
                output += 2;
            },
            '\x0c' => {
                allocation[output] = '\\';
                allocation[output + 1] = 'f';
                output += 2;
            },
            0...0x07, 0x0b, 0x0e...0x1f => {
                allocation[output] = '\\';
                allocation[output + 1] = 'u';
                allocation[output + 2] = '0';
                allocation[output + 3] = '0';
                allocation[output + 4] = hex[byte >> 4];
                allocation[output + 5] = hex[byte & 0x0f];
                output += 6;
            },
            else => {
                allocation[output] = byte;
                output += 1;
            },
        }
    }
    std.debug.assert(output == allocation.len);
    return .{ .allocation = allocation, .bytes = allocation };
}

fn makeJsonArguments(
    allocator: std.mem.Allocator,
    key: []const u8,
    escaped: []const u8,
) Provider.StreamError!OwnedBytes {
    const prefix_len = std.math.add(usize, 5, key.len) catch return error.OutOfMemory;
    const with_escaped = std.math.add(usize, prefix_len, escaped.len) catch return error.OutOfMemory;
    const output_length = std.math.add(usize, with_escaped, 2) catch return error.OutOfMemory;
    const allocation = try allocator.alloc(u8, output_length);
    var output: usize = 0;
    allocation[output] = '{';
    allocation[output + 1] = '"';
    output += 2;
    @memcpy(allocation[output .. output + key.len], key);
    output += key.len;
    allocation[output] = '"';
    allocation[output + 1] = ':';
    allocation[output + 2] = '"';
    output += 3;
    @memcpy(allocation[output .. output + escaped.len], escaped);
    output += escaped.len;
    allocation[output] = '"';
    allocation[output + 1] = '}';
    output += 2;
    std.debug.assert(output == allocation.len);
    return .{ .allocation = allocation, .bytes = allocation };
}

fn interactiveResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Provider.Request,
    sink: Provider.EventSink,
) Provider.StreamError!void {
    const last = lastContentItem(request.context.items) orelse {
        try emitDone(sink, .{});
        return;
    };

    switch (last.*) {
        .tool_result => {
            try emitChunked(io, request.tick, sink, "Tool finished — awaiting next instruction.", 0, .text);
            try emitDone(sink, .{});
            return;
        },
        else => {},
    }

    const message = lastUserText(request.context.items) orelse {
        try emitChunked(io, request.tick, sink, "Hello.", 0, .text);
        try emitDone(sink, .{});
        return;
    };
    if (message.len == 0) {
        try emitChunked(io, request.tick, sink, "Hello.", 0, .text);
        try emitDone(sink, .{});
        return;
    }

    const tool_name: []const u8 = if (messageStartsWith(message, "read")) "read" else "bash";
    const argument_key: []const u8 = if (std.mem.eql(u8, tool_name, "read")) "path" else "command";
    const quoted = extractBacktickText(message);
    if (quoted != null and contextHasTool(request.context, tool_name)) {
        var escaped = try escapeJsonString(allocator, quoted.?);
        defer escaped.deinit(allocator);
        var arguments = try makeJsonArguments(allocator, argument_key, escaped.bytes);
        defer arguments.deinit(allocator);
        try emitChunked(io, request.tick, sink, "Sure, on it.", 0, .text);
        try emitToolCall(io, request.tick, sink, tool_name, arguments.bytes, 0, false);
        try emitDone(sink, .{});
        return;
    }

    const echo = try std.fmt.allocPrint(allocator, "You said: {s}", .{message});
    defer allocator.free(echo);
    try emitChunked(io, request.tick, sink, echo, 0, .text);
    try emitDone(sink, .{});
}

// Keep scripted tools allocator-aware while retaining the exact directive parser above.
fn emitScriptToolWithAllocator(
    allocator: std.mem.Allocator,
    io: std.Io,
    tick: ?Provider.Tick,
    sink: Provider.EventSink,
    spec: []const u8,
    line: []const u8,
    delay_ms: u64,
) Provider.StreamError!void {
    var name_end: usize = 0;
    while (name_end < spec.len and spec[name_end] != ' ' and spec[name_end] != '\t') name_end += 1;
    if (name_end == spec.len) {
        warnScript("zi mock: 'tool' needs name and JSON args: {s}\n", .{line});
        return;
    }
    const args_start = skipWhitespaceIndex(spec, name_end);
    if (args_start == spec.len) {
        warnScript("zi mock: 'tool' needs name and JSON args: {s}\n", .{line});
        return;
    }

    const name_allocation = try allocator.dupe(u8, spec[0..name_end]);
    defer allocator.free(name_allocation);
    var expanded = try expandCwd(allocator, io, spec[args_start..]);
    defer expanded.deinit(allocator);
    try emitToolCall(io, tick, sink, name_allocation, expanded.bytes, delay_ms, true);
}

const TestCapture = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_args: std.ArrayList(u8) = .empty,
    failure_message: std.ArrayList(u8) = .empty,
    tool_name: [64]u8 = undefined,
    tool_name_len: usize = 0,
    tool_call_count: usize = 0,
    text_delta_count: usize = 0,
    done_event_count: usize = 0,
    failure_event_count: usize = 0,
    saw_continuation: bool = false,
    cancel_after_first_text: bool = false,
    usage: Usage.StreamUsage = .{},

    fn init(allocator: std.mem.Allocator) TestCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestCapture) void {
        self.text.deinit(self.allocator);
        self.reasoning.deinit(self.allocator);
        self.tool_args.deinit(self.allocator);
        self.failure_message.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *TestCapture) void {
        self.text.clearRetainingCapacity();
        self.reasoning.clearRetainingCapacity();
        self.tool_args.clearRetainingCapacity();
        self.failure_message.clearRetainingCapacity();
        self.tool_name_len = 0;
        self.tool_call_count = 0;
        self.text_delta_count = 0;
        self.done_event_count = 0;
        self.failure_event_count = 0;
        self.saw_continuation = false;
        self.cancel_after_first_text = false;
        self.usage = .{};
    }

    pub fn emit(self: *TestCapture, event: StreamEvent) Provider.DeliveryError!void {
        switch (event) {
            .text_delta => |delta| {
                if (delta.len != 0 and isUtf8Continuation(delta[0])) self.saw_continuation = true;
                self.text.appendSlice(self.allocator, delta) catch unreachable;
                self.text_delta_count += 1;
                if (self.cancel_after_first_text) return error.Cancelled;
            },
            .reasoning_delta => |delta| if (delta) |value| {
                self.reasoning.appendSlice(self.allocator, value) catch unreachable;
            },
            .tool_call_start => |start| {
                std.debug.assert(start.name.len <= self.tool_name.len);
                @memcpy(self.tool_name[0..start.name.len], start.name);
                self.tool_name_len = start.name.len;
                self.tool_call_count += 1;
            },
            .tool_call_delta => |delta| {
                self.tool_args.appendSlice(self.allocator, delta.arguments_delta) catch unreachable;
            },
            .done => |done| {
                self.done_event_count += 1;
                self.usage = done.usage;
            },
            .failure => |failure| {
                self.failure_event_count += 1;
                self.failure_message.appendSlice(self.allocator, failure.message) catch unreachable;
            },
            else => {},
        }
    }

    fn toolName(self: *const TestCapture) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }
};

const AlwaysCancel = struct {
    pub fn poll(_: *AlwaysCancel) Provider.DeliveryError!void {
        return error.Cancelled;
    }
};

const NullSink = struct {
    pub fn emit(_: *NullSink, _: StreamEvent) Provider.DeliveryError!void {}
};

fn writeTestScript(tmp: *std.testing.TmpDir, content: []const u8) ![:0]u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "script.txt", .data = content });
    return tmp.dir.realPathFileAlloc(std.testing.io, "script.txt", std.testing.allocator);
}

fn missingTestPath(tmp: *std.testing.TmpDir) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    return std.fmt.allocPrint(std.testing.allocator, "{s}/missing.txt", .{root});
}

fn emptyRequest() Provider.Request {
    return .{
        .model = "mock-model",
        .context = .{ .system_prompt = "", .items = &.{}, .tools = &.{} },
    };
}

const script_fixture = "# comment\n" ++
    "text Hello\\nworld\n" ++
    "space\n" ++
    "text again\n" ++
    "reasoning think\\ting\n" ++
    "usage future=99 in=10 out=20 cached=3 cache_write=4 cache_write_1h=2 cost=0.5\n" ++
    "end-turn\n" ++
    "\n" ++
    "tool bash {\"command\":\"ls {{CWD}}\"}\n" ++
    "end-turn\n" ++
    "text ——————————\n" ++
    "end-turn\n";

test "scripted turns, usage, tools, UTF-8 chunks, and exhaustion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(&tmp, script_fixture);
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const sink = Provider.EventSink.from(&capture);
    const request = emptyRequest();

    try Mock.stream(std.testing.allocator, std.testing.io, &mock, request, sink);
    try std.testing.expectEqualStrings("Hello\nworld again", capture.text.items);
    try std.testing.expectEqualStrings("think\ting", capture.reasoning.items);
    try std.testing.expectEqual(@as(usize, 0), capture.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
    try std.testing.expectEqual(@as(?u64, 10), capture.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 20), capture.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 3), capture.usage.cached_tokens);
    try std.testing.expectEqual(@as(?u64, 4), capture.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 2), capture.usage.cache_write_1h_tokens);
    try std.testing.expectEqual(@as(?f64, 0.5), capture.usage.cost_usd);

    capture.reset();
    try Mock.stream(std.testing.allocator, std.testing.io, &mock, request, sink);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const expected_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"command\":\"ls {s}\"}}",
        .{cwd_buffer[0..cwd_length]},
    );
    defer std.testing.allocator.free(expected_args);
    try std.testing.expectEqualStrings("bash", capture.toolName());
    try std.testing.expectEqualStrings(expected_args, capture.tool_args.items);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
    try std.testing.expect(capture.usage.input_tokens == null);
    try std.testing.expect(capture.usage.output_tokens == null);
    try std.testing.expect(capture.usage.cost_usd == null);

    capture.reset();
    try Mock.stream(std.testing.allocator, std.testing.io, &mock, request, sink);
    try std.testing.expectEqualStrings("——————————", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
    try std.testing.expect(!capture.saw_continuation);

    capture.reset();
    try Mock.stream(std.testing.allocator, std.testing.io, &mock, request, sink);
    try std.testing.expectEqualStrings("Script exhausted — no more turns.", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
    try std.testing.expectEqual(@as(usize, 3), state.next_script_turn);
}

test "scripted cancellation preserves the next turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(&tmp, script_fixture);
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    var cancel = AlwaysCancel{};
    var request = emptyRequest();
    request.tick = Provider.Tick.from(&cancel);
    try std.testing.expectError(
        error.Cancelled,
        Mock.stream(std.testing.allocator, std.testing.io, &mock, request, Provider.EventSink.from(&capture)),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.done_event_count);
    try std.testing.expectEqual(@as(usize, 0), capture.failure_event_count);
    try std.testing.expectEqual(@as(usize, 0), state.next_script_turn);

    capture.reset();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("Hello\nworld again", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
    try std.testing.expectEqual(@as(usize, 1), state.next_script_turn);
}

test "sink cancellation preserves a partial scripted turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(&tmp, script_fixture);
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    capture.cancel_after_first_text = true;
    try std.testing.expectError(
        error.Cancelled,
        Mock.stream(
            std.testing.allocator,
            std.testing.io,
            &mock,
            emptyRequest(),
            Provider.EventSink.from(&capture),
        ),
    );
    try std.testing.expect(capture.text.items.len != 0);
    try std.testing.expectEqual(@as(usize, 0), capture.done_event_count);
    try std.testing.expectEqual(@as(usize, 0), capture.failure_event_count);
    try std.testing.expectEqual(@as(usize, 0), state.next_script_turn);

    capture.reset();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("Hello\nworld again", capture.text.items);
}

test "a final scripted turn may end at EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(&tmp, "text final turn\n");
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("final turn", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
    try std.testing.expectEqual(@as(usize, 1), state.next_script_turn);

    capture.reset();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("Script exhausted — no more turns.", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

test "a missing script emits one terminal failure event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try missingTestPath(&tmp);
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.failure_event_count);
    try std.testing.expectEqual(@as(usize, 0), capture.done_event_count);
    try std.testing.expect(std.mem.indexOf(u8, capture.failure_message.items, "cannot open") != null);
}

fn bashTool() []const Provider.ToolDefinition {
    return &.{.{ .name = "bash", .description = "", .parameters = &.{} }};
}

fn readTool() []const Provider.ToolDefinition {
    return &.{.{ .name = "read", .description = "", .parameters = &.{} }};
}

test "interactive bash call escapes JSON strings" {
    const message = @constCast("run `echo \"hi\" C:\\tmp\n\t\x01`");
    const items = [_]Item{.{ .user_message = .{ .text = message } }};
    const context = Provider.Context{
        .system_prompt = "",
        .items = &items,
        .tools = bashTool(),
    };
    var state: State = .{};
    var mock = Mock.init(.{}, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        .{ .model = "mock-model", .context = context },
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("Sure, on it.", capture.text.items);
    try std.testing.expectEqualStrings("bash", capture.toolName());
    try std.testing.expectEqualStrings(
        "{\"command\":\"echo \\\"hi\\\" C:\\\\tmp\\n\\t\\u0001\"}",
        capture.tool_args.items,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

test "interactive read call uses the path argument" {
    const message = @constCast("read `docs/notes.md`");
    const items = [_]Item{.{ .user_message = .{ .text = message } }};
    const context = Provider.Context{
        .system_prompt = "",
        .items = &items,
        .tools = readTool(),
    };
    var state: State = .{};
    var mock = Mock.init(.{}, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        .{ .model = "mock-model", .context = context },
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("read", capture.toolName());
    try std.testing.expectEqualStrings("{\"path\":\"docs/notes.md\"}", capture.tool_args.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

test "interactive mode echoes when tools are unavailable" {
    const message = @constCast("run `ls`");
    const items = [_]Item{.{ .user_message = .{ .text = message } }};
    const context = Provider.Context{
        .system_prompt = "",
        .items = &items,
        .tools = &.{},
    };
    var state: State = .{};
    var mock = Mock.init(.{}, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        .{ .model = "mock-model", .context = context },
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("You said: run `ls`", capture.text.items);
    try std.testing.expectEqual(@as(usize, 0), capture.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

test "interactive read echoes without a matching read tool" {
    const message = @constCast("read `notes.md`");
    const items = [_]Item{.{ .user_message = .{ .text = message } }};
    const context = Provider.Context{
        .system_prompt = "",
        .items = &items,
        .tools = bashTool(),
    };
    var state: State = .{};
    var mock = Mock.init(.{}, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        .{ .model = "mock-model", .context = context },
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("You said: read `notes.md`", capture.text.items);
    try std.testing.expectEqual(@as(usize, 0), capture.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

test "interactive tool result after a boundary gets a follow-up message" {
    const items = [_]Item{
        .{ .user_message = .{ .text = @constCast("run `ls`") } },
        .{ .tool_result = .{
            .call_id = @constCast("call"),
            .output = @constCast("file.c"),
        } },
        .turn_boundary,
    };
    const context = Provider.Context{
        .system_prompt = "",
        .items = &items,
        .tools = bashTool(),
    };
    var state: State = .{};
    var mock = Mock.init(.{}, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        .{ .model = "mock-model", .context = context },
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("Tool finished — awaiting next instruction.", capture.text.items);
    try std.testing.expectEqual(@as(usize, 0), capture.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

test "delay directives pace subsequent scripted emissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(&tmp, "delay 1\ntext first\ntext second\nend-turn\n");
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqualStrings("firstsecond", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

fn exerciseMockAllocations(allocator: std.mem.Allocator, path: []const u8) !void {
    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var sink: NullSink = .{};
    try Mock.stream(allocator, std.testing.io, &mock, emptyRequest(), Provider.EventSink.from(&sink));
}

test "scripted temporary payloads release every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(
        &tmp,
        "text hello\\nworld\n" ++
            "tool bash {\"command\":\"{{CWD}}\"}\n" ++
            "end-turn\n",
    );
    defer std.testing.allocator.free(path);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMockAllocations,
        .{path},
    );
}

comptime {
    // This assertion keeps the line fragment size tied to the fgets-compatible
    // 8192-byte reader buffer rather than an unrelated protocol limit.
    std.debug.assert(line_fragment_bytes + 1 == fgets_buffer_bytes);
}

test "script lines retain fgets-sized fragments at the buffer boundary" {
    var script = std.ArrayList(u8).empty;
    defer script.deinit(std.testing.allocator);
    try script.appendSlice(std.testing.allocator, "text ");
    try script.appendNTimes(std.testing.allocator, 'a', 8187);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTestScript(&tmp, script.items);
    defer std.testing.allocator.free(path);

    var state: State = .{};
    var mock = Mock.init(.{ .script_path = path }, &state);
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    try Mock.stream(
        std.testing.allocator,
        std.testing.io,
        &mock,
        emptyRequest(),
        Provider.EventSink.from(&capture),
    );
    try std.testing.expectEqual(@as(usize, 8186), capture.text.items.len);
    try std.testing.expectEqual(@as(usize, 1), capture.done_event_count);
}

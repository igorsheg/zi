const std = @import("std");
const JsonTransport = @import("JsonTransport.zig");
const Provider = @import("Provider.zig");
const SecureAllocator = @import("SecureAllocator.zig");

pub const maximum_response_bytes: usize = 1024 * 1024;
pub const maximum_base_url_bytes: usize = JsonTransport.maximum_url_bytes - "/models".len;
pub const maximum_headers: usize = JsonTransport.maximum_headers;
pub const maximum_header_bytes: usize = 16 * 1024;
pub const maximum_models: usize = 4096;
pub const maximum_id_bytes: usize = 4096;
pub const maximum_aliases: usize = 16 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_tokens: usize = 128 * 1024;
pub const connect_timeout_ms: u64 = 2000;
pub const total_timeout_ms: u64 = 2000;

pub const PrepareError = error{ OutOfMemory, InvalidRequest };

pub const ProbeOptions = struct {
    base_url: []const u8,
    bearer_token: ?[]const u8 = null,
    extra_headers: []const JsonTransport.Header = &.{},
    tick: ?Provider.Tick = null,
};

/// Owned immutable input for a local `/models` probe. The tick remains borrowed.
/// Header values are wiped when the snapshot is released because custom headers
/// can carry credentials even when they are not marked privileged.
pub const PreparedProbe = struct {
    allocator: std.mem.Allocator,
    base_url: []u8,
    url: []u8,
    headers: []JsonTransport.Header,
    tick: ?Provider.Tick,

    pub fn init(allocator: std.mem.Allocator, options: ProbeOptions) PrepareError!PreparedProbe {
        const base_url = trimBaseUrl(options.base_url);
        if (base_url.len == 0 or base_url.len > maximum_base_url_bytes) return error.InvalidRequest;
        const has_bearer = options.bearer_token != null and options.bearer_token.?.len != 0;
        const header_count = std.math.add(
            usize,
            options.extra_headers.len,
            @intFromBool(has_bearer),
        ) catch return error.InvalidRequest;
        if (header_count > maximum_headers) return error.InvalidRequest;

        var bytes: usize = 0;
        if (has_bearer) {
            bytes = std.math.add(usize, "Authorization".len + "Bearer ".len, options.bearer_token.?.len) catch
                return error.InvalidRequest;
        }
        for (options.extra_headers) |header| {
            bytes = std.math.add(usize, bytes, header.name.len) catch return error.InvalidRequest;
            bytes = std.math.add(usize, bytes, header.value.len) catch return error.InvalidRequest;
        }
        if (bytes > maximum_header_bytes) return error.InvalidRequest;

        const owned_base = allocator.dupe(u8, base_url) catch return error.OutOfMemory;
        errdefer allocator.free(owned_base);
        const url = std.mem.concat(allocator, u8, &.{ base_url, "/models" }) catch
            return error.OutOfMemory;
        errdefer allocator.free(url);
        const headers = allocator.alloc(JsonTransport.Header, header_count) catch
            return error.OutOfMemory;
        errdefer allocator.free(headers);
        var initialized: usize = 0;
        errdefer deinitHeaders(allocator, headers[0..initialized]);

        if (has_bearer) {
            const name = allocator.dupe(u8, "Authorization") catch return error.OutOfMemory;
            errdefer allocator.free(name);
            const value = std.mem.concat(allocator, u8, &.{ "Bearer ", options.bearer_token.? }) catch
                return error.OutOfMemory;
            headers[initialized] = .{ .name = name, .value = value, .privileged = true };
            initialized += 1;
        }
        for (options.extra_headers) |header| {
            const name = allocator.dupe(u8, header.name) catch return error.OutOfMemory;
            errdefer allocator.free(name);
            const value = allocator.dupe(u8, header.value) catch return error.OutOfMemory;
            headers[initialized] = .{
                .name = name,
                .value = value,
                .privileged = header.privileged,
            };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .base_url = owned_base,
            .url = url,
            .headers = headers,
            .tick = options.tick,
        };
    }

    pub fn deinit(self: *PreparedProbe) void {
        deinitHeaders(self.allocator, self.headers);
        self.allocator.free(self.headers);
        self.allocator.free(self.url);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    pub fn request(self: *const PreparedProbe) JsonTransport.Request {
        return .{
            .method = .get,
            .url = self.url,
            .headers = self.headers,
            .tick = self.tick,
            .privileged_header_policy = .https_or_loopback_http,
            .limits = .{
                .max_request_body_bytes = 1,
                .max_response_body_bytes = maximum_response_bytes,
                .max_header_bytes = maximum_header_bytes,
                .header_buffer_bytes = maximum_header_bytes,
                .connect_timeout_ms = connect_timeout_ms,
                .idle_timeout_ms = 0,
                .total_timeout_ms = total_timeout_ms,
            },
        };
    }
};

fn trimBaseUrl(value: []const u8) []const u8 {
    var result = std.mem.trim(u8, value, " \t\r\n");
    while (result.len != 0 and result[result.len - 1] == '/') result.len -= 1;
    return result;
}

fn deinitHeaders(allocator: std.mem.Allocator, headers: []JsonTransport.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        SecureAllocator.wipeFree(allocator, header.value);
    }
}

pub const Unreachable = union(enum) {
    non_success: u16,
    empty_body,
    transport: JsonTransport.Error,
};

/// Probe bodies are owned by the result and wiped by `deinit`.
pub const ProbeResult = union(enum) {
    @"unreachable": struct {
        reason: Unreachable,
        body: ?[]u8 = null,
    },
    body: []u8,

    pub fn deinit(self: *ProbeResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .body => |body| wipeBody(allocator, body),
            .@"unreachable" => |value| if (value.body) |body| wipeBody(allocator, body),
        }
        self.* = undefined;
    }
};

fn wipeBody(allocator: std.mem.Allocator, body: []u8) void {
    if (body.len == 0) allocator.free(body) else SecureAllocator.wipeFree(allocator, body);
}

/// Executes only the reachability probe. In particular, Ollama callers must not
/// interpret the response as model discovery.
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: JsonTransport.Transport,
    prepared: *const PreparedProbe,
) ProbeResult {
    var response = transport.request(allocator, io, prepared.request()) catch |err| {
        return .{ .@"unreachable" = .{ .reason = .{ .transport = err } } };
    };
    if (response.status < 200 or response.status >= 300) {
        const body = response.body;
        response.body = &.{};
        return .{ .@"unreachable" = .{ .reason = .{ .non_success = response.status }, .body = body } };
    }
    if (response.body.len == 0) {
        const body = response.body;
        response.body = &.{};
        return .{ .@"unreachable" = .{ .reason = .empty_body, .body = body } };
    }
    const body = response.body;
    response.body = &.{};
    return .{ .body = body };
}

pub const ParseError = error{ OutOfMemory, InvalidResponse, ResponseTooLarge };

pub const ParseLimits = struct {
    max_input_bytes: usize = maximum_response_bytes,
    max_models: usize = maximum_models,
    max_id_bytes: usize = maximum_id_bytes,
    max_aliases: usize = maximum_aliases,
    max_json_depth: usize = maximum_json_depth,
    max_json_tokens: usize = maximum_json_tokens,
};

pub const Warning = struct {
    configured_label: []u8,
    served_label: []u8,

    fn deinit(self: *Warning, allocator: std.mem.Allocator) void {
        allocator.free(self.configured_label);
        allocator.free(self.served_label);
        self.* = undefined;
    }

    /// Formats the exact hax warning text. The returned message is owned.
    pub fn format(self: Warning, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        if (std.mem.eql(u8, self.configured_label, self.served_label)) {
            return std.fmt.allocPrint(
                allocator,
                "llama.cpp: configured model is not served — using '{s}'",
                .{self.served_label},
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "llama.cpp: model '{s}' is not served — using '{s}'",
            .{ self.configured_label, self.served_label },
        );
    }
};

pub const Replacement = struct {
    model: []u8,
    warning: ?Warning = null,
};

/// Pure reconciliation outcome for llama.cpp's `/v1/models` document.
pub const Reconcile = union(enum) {
    unchanged,
    no_models,
    replacement: Replacement,
    canonical: []u8,
    clear_configured,

    pub fn deinit(self: *Reconcile, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .replacement => |*value| {
                allocator.free(value.model);
                if (value.warning) |*warning| warning.deinit(allocator);
            },
            .canonical => |model| allocator.free(model),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn reconcileLlama(
    allocator: std.mem.Allocator,
    body: []const u8,
    configured_model: ?[]const u8,
    limits: ParseLimits,
) ParseError!Reconcile {
    try validateParseInput(body, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data != .array) return error.InvalidResponse;
    if (data.array.items.len > limits.max_models) return error.ResponseTooLarge;

    const configured = if (configured_model) |value| if (value.len == 0) null else value else null;
    var first_model: ?[]const u8 = null;
    var running_model: ?[]const u8 = null;
    var configured_id: ?[]const u8 = null;
    var running_count: usize = 0;
    var alias_count: usize = 0;
    var router = false;

    for (data.array.items) |entry_value| {
        if (entry_value != .object) continue;
        const entry = entry_value.object;
        const id_value = entry.get("id") orelse continue;
        if (id_value != .string) continue;
        const id = id_value.string;
        if (id.len > limits.max_id_bytes) return error.ResponseTooLarge;
        if (first_model == null) first_model = id;

        if (entry.get("status")) |status| {
            router = router or status == .object;
            if (status == .object) {
                if (status.object.get("value")) |state| {
                    if (state == .string and isRunning(state.string)) {
                        running_model = id;
                        running_count += 1;
                    }
                }
            }
        }
        if (configured != null and configured_id == null) {
            if (std.mem.eql(u8, id, configured.?)) {
                configured_id = id;
            } else if (entry.get("aliases")) |aliases| {
                if (aliases == .array) {
                    alias_count = std.math.add(usize, alias_count, aliases.array.items.len) catch
                        return error.ResponseTooLarge;
                    if (alias_count > limits.max_aliases) return error.ResponseTooLarge;
                    for (aliases.array.items) |alias| {
                        if (alias != .string) continue;
                        if (alias.string.len > limits.max_id_bytes) return error.ResponseTooLarge;
                        if (std.mem.eql(u8, alias.string, configured.?)) {
                            configured_id = id;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (first_model == null) return .no_models;
    if (configured == null) {
        if (!router) return replacement(allocator, first_model.?, null);
        if (running_count == 1) return replacement(allocator, running_model.?, null);
        return .unchanged;
    }
    if (configured_id == null) {
        if (router) return .clear_configured;
        return replacement(allocator, first_model.?, configured.?);
    }
    if (!std.mem.eql(u8, configured_id.?, configured.?)) {
        return .{ .canonical = allocator.dupe(u8, configured_id.?) catch return error.OutOfMemory };
    }
    return .unchanged;
}

fn replacement(
    allocator: std.mem.Allocator,
    model: []const u8,
    configured: ?[]const u8,
) ParseError!Reconcile {
    const owned_model = allocator.dupe(u8, model) catch return error.OutOfMemory;
    errdefer allocator.free(owned_model);
    var warning: ?Warning = null;
    if (configured) |value| {
        warning = .{
            .configured_label = try modelLabel(allocator, value),
            .served_label = undefined,
        };
        errdefer allocator.free(warning.?.configured_label);
        warning.?.served_label = try modelLabel(allocator, model);
    }
    return .{ .replacement = .{ .model = owned_model, .warning = warning } };
}

pub fn modelLabel(allocator: std.mem.Allocator, model: []const u8) error{OutOfMemory}![]u8 {
    const extension = ".gguf";
    if (model.len <= extension.len or
        !std.ascii.eqlIgnoreCase(model[model.len - extension.len ..], extension))
    {
        return allocator.dupe(u8, model);
    }
    const slash = std.mem.findLastAny(u8, model, "/\\");
    const filename = if (slash) |index| model[index + 1 ..] else model;
    const stem_length = filename.len - extension.len;
    if (stem_length == 0) return allocator.dupe(u8, model);
    return allocator.dupe(u8, filename[0..stem_length]);
}

fn isRunning(value: []const u8) bool {
    return std.mem.eql(u8, value, "loaded") or
        std.mem.eql(u8, value, "loading") or
        std.mem.eql(u8, value, "sleeping");
}

fn validateParseInput(body: []const u8, limits: ParseLimits) ParseError!void {
    if (limits.max_input_bytes == 0 or limits.max_input_bytes > maximum_response_bytes or
        limits.max_models == 0 or limits.max_models > maximum_models or
        limits.max_id_bytes == 0 or limits.max_id_bytes > maximum_id_bytes or
        limits.max_aliases == 0 or limits.max_aliases > maximum_aliases or
        limits.max_json_depth == 0 or limits.max_json_depth > maximum_json_depth or
        limits.max_json_tokens == 0 or limits.max_json_tokens > maximum_json_tokens)
    {
        return error.InvalidResponse;
    }
    if (body.len > limits.max_input_bytes) return error.ResponseTooLarge;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidResponse;
    var depth: usize = 0;
    var tokens: usize = 0;
    var in_string = false;
    var escaped = false;
    for (body) |byte| {
        if (in_string) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
            continue;
        }
        switch (byte) {
            '"' => {
                in_string = true;
                tokens += 1;
            },
            '{', '[' => {
                depth += 1;
                tokens += 1;
                if (depth > limits.max_json_depth) return error.ResponseTooLarge;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidResponse;
                depth -= 1;
            },
            ':', ',' => tokens += 1,
            else => {},
        }
        if (tokens > limits.max_json_tokens) return error.ResponseTooLarge;
    }
    if (in_string or depth != 0) return error.InvalidResponse;
}

const classic_response =
    "{\"data\":[{\"id\":7},{},{\"id\":\"served-a\"},{\"id\":\"served-b\"}]}";
const router_response =
    "{\"data\":[" ++
    "{\"id\":\"idle-a\",\"status\":{\"value\":\"unloaded\"}}," ++
    "{\"id\":\"running\",\"aliases\":[\"short-name\"],\"status\":{\"value\":\"loaded\"}}," ++
    "{\"id\":\"idle-b\",\"status\":{\"value\":\"unloaded\"}}]}";

test "prepared probe owns exact bounded request and wipes header values" {
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var prepared = try PreparedProbe.init(observer.allocator(), .{
        .base_url = "  http://127.0.0.1:8080/v1///  ",
        .bearer_token = "secret",
        .extra_headers = &.{.{ .name = "X-Token", .value = "extra-secret", .privileged = true }},
    });
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1", prepared.base_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1/models", prepared.url);
    const request_value = prepared.request();
    try std.testing.expectEqual(JsonTransport.Method.get, request_value.method);
    try std.testing.expectEqual(connect_timeout_ms, request_value.limits.connect_timeout_ms);
    try std.testing.expectEqual(total_timeout_ms, request_value.limits.total_timeout_ms);
    try std.testing.expectEqual(
        JsonTransport.PrivilegedHeaderPolicy.https_or_loopback_http,
        request_value.privileged_header_policy,
    );
    try std.testing.expectEqual(@as(u64, 0), request_value.limits.idle_timeout_ms);
    try std.testing.expectEqual(maximum_response_bytes, request_value.limits.max_response_body_bytes);
    try std.testing.expectEqualStrings("Bearer secret", prepared.headers[0].value);
    prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), observer.zero_frees);
}

test "fake transport classifies reachability and preserves owned bodies" {
    const Fake = struct {
        const Self = @This();
        status: u16 = 200,
        body: []const u8 = "{}",
        saw_limits: bool = false,
        pub fn request(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            value: JsonTransport.Request,
        ) JsonTransport.Error!JsonTransport.Response {
            self.saw_limits = value.method == .get and value.limits.total_timeout_ms == 2000;
            return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
        }
    };
    var prepared = try PreparedProbe.init(std.testing.allocator, .{ .base_url = "http://localhost:11434/v1" });
    defer prepared.deinit();
    var fake: Fake = .{};
    var result = probe(std.testing.allocator, std.testing.io, JsonTransport.Transport.from(&fake), &prepared);
    try std.testing.expect(result == .body);
    result.deinit(std.testing.allocator);
    try std.testing.expect(fake.saw_limits);

    fake.status = 503;
    fake.body = "down";
    result = probe(std.testing.allocator, std.testing.io, JsonTransport.Transport.from(&fake), &prepared);
    try std.testing.expect(result == .@"unreachable");
    try std.testing.expectEqual(@as(u16, 503), result.@"unreachable".reason.non_success);
    try std.testing.expectEqualStrings("down", result.@"unreachable".body.?);
    result.deinit(std.testing.allocator);

    fake.status = 200;
    fake.body = "";
    result = probe(std.testing.allocator, std.testing.io, JsonTransport.Transport.from(&fake), &prepared);
    try std.testing.expect(result.@"unreachable".reason == .empty_body);
    result.deinit(std.testing.allocator);
}

test "classic llama reconciliation and exact warning labels" {
    var decision = try reconcileLlama(std.testing.allocator, classic_response, null, .{});
    try std.testing.expectEqualStrings("served-a", decision.replacement.model);
    decision.deinit(std.testing.allocator);

    decision = try reconcileLlama(std.testing.allocator, classic_response, "stale", .{});
    defer decision.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("served-a", decision.replacement.model);
    const message = try decision.replacement.warning.?.format(std.testing.allocator);
    try std.testing.expectEqualStrings("llama.cpp: model 'stale' is not served — using 'served-a'", message);
    std.testing.allocator.free(message);

    var same = try reconcileLlama(
        std.testing.allocator,
        "{\"data\":[{\"id\":\"/new/Qwen.GGUF\"}]}",
        "/old/Qwen.gguf",
        .{},
    );
    defer same.deinit(std.testing.allocator);
    const same_message = try same.replacement.warning.?.format(std.testing.allocator);
    defer std.testing.allocator.free(same_message);
    try std.testing.expectEqualStrings("llama.cpp: configured model is not served — using 'Qwen'", same_message);
}

test "router states aliases empty and missing configuration reconcile exactly" {
    var decision = try reconcileLlama(std.testing.allocator, router_response, null, .{});
    try std.testing.expectEqualStrings("running", decision.replacement.model);
    decision.deinit(std.testing.allocator);

    decision = try reconcileLlama(std.testing.allocator, router_response, "short-name", .{});
    try std.testing.expectEqualStrings("running", decision.canonical);
    decision.deinit(std.testing.allocator);

    decision = try reconcileLlama(std.testing.allocator, router_response, "missing", .{});
    try std.testing.expect(decision == .clear_configured);
    decision.deinit(std.testing.allocator);

    decision = try reconcileLlama(std.testing.allocator, "{\"data\":[]}", "model", .{});
    try std.testing.expect(decision == .no_models);
    decision.deinit(std.testing.allocator);

    inline for (.{ "loaded", "loading", "sleeping" }) |state| {
        const body = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"data\":[{{\"id\":\"one\",\"status\":{{\"value\":\"{s}\"}}}}]}}",
            .{state},
        );
        defer std.testing.allocator.free(body);
        decision = try reconcileLlama(std.testing.allocator, body, null, .{});
        try std.testing.expectEqualStrings("one", decision.replacement.model);
        decision.deinit(std.testing.allocator);
    }
}

test "router needs exactly one running model and ignores status on unusable entries" {
    var decision = try reconcileLlama(
        std.testing.allocator,
        "{\"data\":[{\"id\":\"a\",\"status\":{\"value\":\"loaded\"}}," ++
            "{\"id\":\"b\",\"status\":{\"value\":\"sleeping\"}}]}",
        null,
        .{},
    );
    try std.testing.expect(decision == .unchanged);
    decision.deinit(std.testing.allocator);

    decision = try reconcileLlama(
        std.testing.allocator,
        "{\"data\":[{\"id\":7,\"status\":{}},{\"id\":\"classic-looking\"}]}",
        null,
        .{},
    );
    defer decision.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("classic-looking", decision.replacement.model);
}

test "malformed and parser resource bounds are typed" {
    inline for (.{ "not json", "{}", "{\"data\":null}" }) |body| {
        try std.testing.expectError(error.InvalidResponse, reconcileLlama(std.testing.allocator, body, null, .{}));
    }
    try std.testing.expectError(error.ResponseTooLarge, reconcileLlama(
        std.testing.allocator,
        "{\"data\":[{\"id\":\"long\"}]}",
        null,
        .{ .max_id_bytes = 3 },
    ));
    try std.testing.expectError(error.ResponseTooLarge, reconcileLlama(
        std.testing.allocator,
        "{\"data\":[[[[]]]]} ",
        null,
        .{ .max_json_depth = 3 },
    ));
    try std.testing.expectError(error.ResponseTooLarge, reconcileLlama(
        std.testing.allocator,
        "{\"data\":[{\"id\":\"x\",\"aliases\":[\"a\",\"b\"]}]}",
        "z",
        .{ .max_aliases = 1 },
    ));
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var prepared = try PreparedProbe.init(allocator, .{
        .base_url = "http://localhost:8080/v1/",
        .bearer_token = "secret",
        .extra_headers = &.{.{ .name = "X-Key", .value = "value" }},
    });
    prepared.deinit();
    var decision = try reconcileLlama(allocator, router_response, "short-name", .{});
    decision.deinit(allocator);
    decision = try reconcileLlama(allocator, classic_response, "stale", .{});
    decision.deinit(allocator);
}

test "all preparation and parser allocation failures are released" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

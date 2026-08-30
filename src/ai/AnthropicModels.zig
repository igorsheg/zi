const std = @import("std");
const Effort = @import("Effort.zig");
const JsonTransport = @import("JsonTransport.zig");
const ModelListing = @import("ModelListing.zig");
const ModelMeta = @import("ModelMeta.zig");
const Provider = @import("Provider.zig");

pub const default_version = "2023-06-01";
pub const maximum_input_bytes: usize = 4 * 1024 * 1024;
pub const maximum_pages: usize = 50;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 65_536;
pub const maximum_json_work: usize = 262_144;
pub const maximum_api_key_bytes: usize = 8 * 1024;
pub const maximum_version_bytes: usize = 256;
pub const maximum_extra_headers: usize = JsonTransport.maximum_headers - 2;

pub const Config = struct {
    provider_id: []const u8,
    endpoint: []const u8,
    api_key: ?[]const u8 = null,
    version: []const u8 = default_version,
    extra_headers: []const JsonTransport.Header = &.{},
    privileged_header_policy: JsonTransport.PrivilegedHeaderPolicy = .https_only,
};

pub const Client = struct {
    transport: JsonTransport.Transport,
    config: Config,

    pub fn init(transport: JsonTransport.Transport, config: Config) Client {
        return .{ .transport = transport, .config = config };
    }

    pub fn listModels(
        self: *Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) ModelListing.Error!ModelListing.Outcome {
        try validateConfig(self.config);

        const models_url = try deriveModelsUrl(allocator, self.config.endpoint);
        defer allocator.free(models_url);
        const headers = try makeHeaders(allocator, self.config);
        defer allocator.free(headers);

        const owner = try ModelListing.Owner.init(allocator);
        var owner_live = true;
        const result_allocator = owner.arenaAllocator();
        var models: std.ArrayList(ModelListing.Model) = .empty;
        defer if (owner_live) {
            models.deinit(result_allocator);
            owner.destroy();
        };

        var after_id: ?[]u8 = null;
        defer if (after_id) |cursor| allocator.free(cursor);
        var saw_entry = false;

        for (0..maximum_pages) |_| {
            const url = makePageUrl(allocator, models_url, after_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRequest => {
                    return failureMessage(
                        allocator,
                        "{s} /models response exceeds listing limits",
                        .{self.config.provider_id},
                    );
                },
            };
            defer allocator.free(url);

            var response = self.transport.request(allocator, io, .{
                .method = .get,
                .url = url,
                .headers = headers,
                .tick = tick,
                .privileged_header_policy = self.config.privileged_header_policy,
                .limits = listing_limits,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Cancelled => return error.Cancelled,
                error.InvalidRequest => return error.InvalidRequest,
                else => {
                    const base_url = models_url[0 .. models_url.len - "/models".len];
                    return failureForTransport(allocator, self.config.provider_id, base_url);
                },
            };
            defer response.deinit(allocator);

            if (response.status < 200 or response.status >= 300) {
                return failureForStatus(
                    allocator,
                    self.config.provider_id,
                    self.config.api_key != null,
                    response.status,
                );
            }
            if (response.body.len == 0) {
                return failureMessage(
                    allocator,
                    "{s} sent an empty or truncated /models response",
                    .{self.config.provider_id},
                );
            }

            const page = parsePage(
                allocator,
                result_allocator,
                response.body,
                after_id,
                &models,
                &saw_entry,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidJson => {
                    return failureMessage(
                        allocator,
                        "{s} /models response is not valid JSON",
                        .{self.config.provider_id},
                    );
                },
                error.NoModelList => {
                    return failureMessage(
                        allocator,
                        "{s} /models response has no model list",
                        .{self.config.provider_id},
                    );
                },
                error.ResponseTooLarge => {
                    return failureMessage(
                        allocator,
                        "{s} /models response exceeds listing limits",
                        .{self.config.provider_id},
                    );
                },
            };
            if (page == .repeated) break;

            const next_cursor = switch (page) {
                .stop => break,
                .repeated => unreachable,
                .next => |cursor| cursor,
            };
            if (after_id) |cursor| allocator.free(cursor);
            after_id = next_cursor;
        }

        if (saw_entry and models.items.len == 0) {
            return failureMessage(
                allocator,
                "{s} /models response contains no usable model ids",
                .{self.config.provider_id},
            );
        }

        const list = owner.finish(models.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRequest => {
                return failureMessage(
                    allocator,
                    "{s} /models response exceeds listing limits",
                    .{self.config.provider_id},
                );
            },
        };
        owner_live = false;
        return .{ .models = list };
    }
};

const listing_limits: JsonTransport.Limits = .{
    .max_request_body_bytes = 1,
    .max_response_body_bytes = maximum_input_bytes,
    .max_header_bytes = JsonTransport.maximum_header_bytes,
    .header_buffer_bytes = JsonTransport.maximum_header_bytes,
    .connect_timeout_ms = 10_000,
    .idle_timeout_ms = 10_000,
    .total_timeout_ms = 10_000,
};

fn validateConfig(config: Config) error{InvalidRequest}!void {
    if (config.provider_id.len == 0 or
        config.provider_id.len > ModelListing.maximum_failure_bytes / 2 or
        !std.unicode.utf8ValidateSlice(config.provider_id) or
        config.endpoint.len == 0 or
        config.endpoint.len > JsonTransport.maximum_url_bytes or
        config.version.len == 0 or
        config.version.len > maximum_version_bytes or
        !headerValueSafe(config.version) or
        config.extra_headers.len > maximum_extra_headers)
    {
        return error.InvalidRequest;
    }
    if (config.api_key) |api_key| {
        if (api_key.len == 0 or api_key.len > maximum_api_key_bytes or !headerValueSafe(api_key)) {
            return error.InvalidRequest;
        }
    }
    const fixed_headers: usize = 2 + @as(usize, @intFromBool(config.api_key != null));
    if (config.extra_headers.len + fixed_headers > JsonTransport.maximum_headers) {
        return error.InvalidRequest;
    }
}

fn headerValueSafe(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn deriveModelsUrl(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
) error{ OutOfMemory, InvalidRequest }![]u8 {
    const suffix = "/messages";
    if (!std.mem.endsWith(u8, endpoint, suffix) or std.mem.findAny(u8, endpoint, "?#") != null) {
        return error.InvalidRequest;
    }
    const prefix = endpoint[0 .. endpoint.len - suffix.len];
    if (prefix.len == 0) return error.InvalidRequest;
    const length = std.math.add(usize, prefix.len, "/models".len) catch
        return error.InvalidRequest;
    if (length > JsonTransport.maximum_url_bytes) return error.InvalidRequest;
    return std.mem.concat(allocator, u8, &.{ prefix, "/models" });
}

fn makeHeaders(
    allocator: std.mem.Allocator,
    config: Config,
) error{OutOfMemory}![]JsonTransport.Header {
    const count = 2 + config.extra_headers.len + @as(usize, @intFromBool(config.api_key != null));
    const headers = try allocator.alloc(JsonTransport.Header, count);
    var next: usize = 0;
    if (config.api_key) |api_key| {
        headers[next] = .{ .name = "x-api-key", .value = api_key, .privileged = true };
        next += 1;
    }
    headers[next] = .{ .name = "anthropic-version", .value = config.version };
    next += 1;
    headers[next] = .{ .name = "Accept", .value = "application/json" };
    next += 1;
    for (config.extra_headers) |header| {
        headers[next] = header;
        next += 1;
    }
    return headers;
}

fn makePageUrl(
    allocator: std.mem.Allocator,
    models_url: []const u8,
    after_id: ?[]const u8,
) error{ OutOfMemory, InvalidRequest }![]u8 {
    const url = if (after_id) |cursor|
        try std.fmt.allocPrint(allocator, "{s}?limit=1000&after_id={s}", .{ models_url, cursor })
    else
        try std.fmt.allocPrint(allocator, "{s}?limit=1000", .{models_url});
    errdefer allocator.free(url);
    if (url.len > JsonTransport.maximum_url_bytes) return error.InvalidRequest;
    return url;
}

const ParseError = error{
    OutOfMemory,
    InvalidJson,
    NoModelList,
    ResponseTooLarge,
};

const PageResult = union(enum) {
    stop,
    repeated,
    next: []u8,
};

fn parsePage(
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    json: []const u8,
    after_id: ?[]const u8,
    models: *std.ArrayList(ModelListing.Model),
    saw_entry: *bool,
) ParseError!PageResult {
    if (json.len > maximum_input_bytes) return error.ResponseTooLarge;
    if (!std.unicode.utf8ValidateSlice(json)) return error.InvalidJson;
    try validateJsonWork(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root = valueObject(parsed.value) orelse return error.NoModelList;
    const data = root.get("data") orelse return error.NoModelList;
    if (data != .array and data != .null) return error.NoModelList;

    const last_id = optionalString(root, "last_id");
    if (after_id) |cursor| {
        if (last_id) |last| {
            if (std.mem.eql(u8, cursor, last)) return .repeated;
        }
    }

    if (data == .array) {
        for (data.array.items) |entry_value| {
            saw_entry.* = true;
            const entry = valueObject(entry_value) orelse continue;
            const id = optionalString(entry, "id") orelse continue;
            if (id.len == 0) continue;
            if (id.len > ModelListing.maximum_id_bytes) return error.ResponseTooLarge;
            if (models.items.len >= ModelListing.maximum_models) return error.ResponseTooLarge;

            var model: ModelListing.Model = .{ .id = try result_allocator.dupe(u8, id) };
            parseMetadata(entry, &model);
            try models.append(result_allocator, model);
        }
    }

    if (booleanMember(root, "has_more") != true) return .stop;
    const cursor = last_id orelse return .stop;
    if (!cursorSafe(cursor)) return .stop;
    return .{ .next = try allocator.dupe(u8, cursor) };
}

fn parseMetadata(entry: std.json.ObjectMap, model: *ModelListing.Model) void {
    model.metadata.context_window = positiveInteger(entry.get("max_input_tokens")) orelse 0;
    model.metadata.max_output = positiveInteger(entry.get("max_tokens")) orelse 0;

    const capabilities = objectMember(entry, "capabilities") orelse return;
    if (objectMember(capabilities, "image_input")) |image| {
        if (booleanMember(image, "supported")) |supported| {
            model.metadata.image_input = if (supported) .yes else .no;
        }
    }
    model.metadata.efforts = parseEfforts(capabilities.get("effort"));
}

fn parseEfforts(value: ?std.json.Value) Effort.Set {
    const present = value orelse return .{};
    if (present != .object) return .{};
    const effort = present.object;
    if (booleanMember(effort, "supported") == false) {
        return Effort.Set.init(&.{}) catch unreachable;
    }

    var result: Effort.Set = .{};
    const ladder = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };
    for (ladder) |name| {
        const level = objectMember(effort, name) orelse continue;
        if (booleanMember(level, "supported") == true) result.add(name) catch continue;
    }
    var iterator = effort.iterator();
    while (iterator.next()) |member| {
        if (std.mem.eql(u8, member.key_ptr.*, "supported")) continue;
        const level = valueObject(member.value_ptr.*) orelse continue;
        if (booleanMember(level, "supported") == true) {
            result.add(member.key_ptr.*) catch continue;
        }
    }
    return result;
}

fn cursorSafe(cursor: []const u8) bool {
    if (cursor.len == 0) return false;
    for (cursor) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) {
            return false;
        }
    }
    return true;
}

fn validateJsonWork(json: []const u8) ParseError!void {
    var depth: usize = 0;
    var fields: usize = 0;
    var work: usize = 0;
    var in_string = false;
    var escaped = false;
    for (json) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                work += 1;
                if (depth > maximum_json_depth) return error.ResponseTooLarge;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            ':' => {
                fields += 1;
                work += 1;
                if (fields > maximum_json_fields) return error.ResponseTooLarge;
            },
            ',' => work += 1,
            else => {},
        }
        if (work > maximum_json_work) return error.ResponseTooLarge;
    }
    if (in_string or depth != 0) return error.InvalidJson;
}

fn positiveInteger(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0) return null;
    return @intCast(present.integer);
}

fn booleanMember(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn objectMember(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return valueObject(value);
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn failureForStatus(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    has_key: bool,
    status: u16,
) ModelListing.Error!ModelListing.Outcome {
    if (status == 401 or status == 403) {
        if (has_key) return failureMessage(
            allocator,
            "{s} rejected the API key (HTTP {d}) — check it and retry",
            .{ provider_id, status },
        );
        return failureMessage(
            allocator,
            "{s} requires an API key (HTTP {d}) — none is configured",
            .{ provider_id, status },
        );
    }
    return failureMessage(allocator, "listing {s} models failed (HTTP {d})", .{ provider_id, status });
}

fn failureForTransport(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
) ModelListing.Error!ModelListing.Outcome {
    return failureMessage(allocator, "could not reach {s} at {s}", .{ provider_id, base_url });
}

fn failureMessage(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) ModelListing.Error!ModelListing.Outcome {
    var buffer: [ModelListing.maximum_failure_bytes]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch return error.InvalidRequest;
    return ModelListing.failure(allocator, message);
}

const FakeTransport = struct {
    responses: []const []const u8,
    status: u16 = 200,
    transport_error: ?JsonTransport.Error = null,
    advancing_pages: bool = false,
    calls: usize = 0,
    valid: bool = true,
    urls: [maximum_pages][]u8 = undefined,

    pub fn deinit(self: *FakeTransport, allocator: std.mem.Allocator) void {
        for (self.urls[0..self.calls]) |url| allocator.free(url);
        self.* = undefined;
    }

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *FakeTransport,
        value: JsonTransport.Request,
    ) JsonTransport.Error!JsonTransport.Response {
        const call = self.calls;
        if ((!self.advancing_pages and self.responses.len == 0) or call >= maximum_pages) {
            return error.ConnectionFailed;
        }
        const response_index = if (self.responses.len == 0) 0 else @min(call, self.responses.len - 1);
        self.urls[call] = try allocator.dupe(u8, value.url);
        self.calls += 1;
        self.valid = self.valid and value.method == .get;
        const has_key = value.headers.len == 4;
        self.valid = self.valid and (has_key or value.headers.len == 3);
        const metadata_index: usize = if (has_key) 1 else 0;
        if (has_key) {
            self.valid = self.valid and value.headers[0].isPrivileged();
            self.valid = self.valid and std.ascii.eqlIgnoreCase(value.headers[0].name, "x-api-key");
            self.valid = self.valid and std.mem.eql(u8, value.headers[0].value, "secret");
        }
        self.valid = self.valid and
            std.ascii.eqlIgnoreCase(value.headers[metadata_index].name, "anthropic-version");
        self.valid = self.valid and std.mem.eql(u8, value.headers[metadata_index].value, "2024-01-01");
        self.valid = self.valid and std.ascii.eqlIgnoreCase(value.headers[metadata_index + 1].name, "accept");
        self.valid = self.valid and
            std.mem.eql(u8, value.headers[metadata_index + 1].value, "application/json");
        self.valid = self.valid and std.mem.eql(u8, value.headers[metadata_index + 2].name, "X-Route");
        self.valid = self.valid and value.privileged_header_policy == .https_or_loopback_http;
        self.valid = self.valid and value.limits.max_response_body_bytes == maximum_input_bytes;
        self.valid = self.valid and value.limits.connect_timeout_ms == 10_000;
        self.valid = self.valid and value.limits.idle_timeout_ms == 10_000;
        self.valid = self.valid and value.limits.total_timeout_ms == 10_000;
        if (self.transport_error) |err| return err;
        const body = if (self.advancing_pages)
            try std.fmt.allocPrint(
                allocator,
                "{{\"data\":[],\"has_more\":true,\"last_id\":\"c{d}\"}}",
                .{call},
            )
        else
            try allocator.dupe(u8, self.responses[response_index]);
        return .{ .status = self.status, .body = body };
    }
};

fn testConfig() Config {
    return .{
        .provider_id = "anthropic-test",
        .endpoint = "http://127.0.0.1:8080/v1/messages",
        .api_key = "secret",
        .version = "2024-01-01",
        .extra_headers = &.{.{ .name = "X-Route", .value = "one" }},
        .privileged_header_policy = .https_or_loopback_http,
    };
}

fn expectFailure(outcome: *ModelListing.Outcome, expected: []const u8) !void {
    defer outcome.deinit();
    try std.testing.expect(outcome.* == .failure);
    try std.testing.expectEqualStrings(expected, outcome.failure.message);
}

test "client sends authenticated bounded GETs and follows safe cursors" {
    const responses = [_][]const u8{
        "{\"data\":[{\"id\":\"m1\"},{\"id\":\"m2\"}],\"has_more\":true,\"last_id\":\"m2\"}",
        "{\"data\":[{\"id\":\"m3\"}],\"has_more\":false,\"last_id\":\"m3\"}",
    };
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();

    try std.testing.expect(outcome == .models);
    try std.testing.expectEqual(@as(usize, 3), outcome.models.models.len);
    try std.testing.expectEqualStrings("m1", outcome.models.models[0].id);
    try std.testing.expectEqualStrings("m3", outcome.models.models[2].id);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8080/v1/models?limit=1000",
        fake.urls[0],
    );
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8080/v1/models?limit=1000&after_id=m2",
        fake.urls[1],
    );
    try std.testing.expect(fake.valid);
}

test "pagination is capped at exactly fifty advancing pages" {
    var fake: FakeTransport = .{ .responses = &.{}, .advancing_pages = true };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(usize, 50), maximum_pages);
    try std.testing.expectEqual(maximum_pages, fake.calls);
    try std.testing.expectEqual(@as(usize, 0), outcome.models.models.len);
    try std.testing.expect(fake.valid);
    for (1..maximum_pages) |call| {
        var expected_buffer: [128]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "http://127.0.0.1:8080/v1/models?limit=1000&after_id=c{d}",
            .{call - 1},
        );
        try std.testing.expectEqualStrings(expected, fake.urls[call]);
    }
}

test "repeated cursor page is discarded before append" {
    const responses = [_][]const u8{
        "{\"data\":[{\"id\":\"m1\"}],\"has_more\":true,\"last_id\":\"m1\"}",
        "{\"data\":[{\"id\":\"duplicate\"}],\"has_more\":true,\"last_id\":\"m1\"}",
    };
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), outcome.models.models.len);
    try std.testing.expectEqualStrings("m1", outcome.models.models[0].id);
}

test "oversized safe cursor is a bounded failure rather than a partial list" {
    const response = "{\"data\":[{\"id\":\"m1\"}],\"has_more\":true,\"last_id\":\"" ++
        ("a" ** JsonTransport.maximum_url_bytes) ++ "\"}";
    const responses = [_][]const u8{response};
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(&outcome, "anthropic-test /models response exceeds listing limits");
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "missing and unsafe cursors stop pagination" {
    inline for (.{
        "{\"data\":[{\"id\":\"m1\"}],\"has_more\":true}",
        "{\"data\":[{\"id\":\"m1\"}],\"has_more\":true,\"last_id\":\"bad&cursor\"}",
    }) |response| {
        const responses = [_][]const u8{response};
        var fake: FakeTransport = .{ .responses = &responses };
        defer fake.deinit(std.testing.allocator);
        var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
        var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
        defer outcome.deinit();
        try std.testing.expectEqual(@as(usize, 1), outcome.models.models.len);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
    }
}

test "null data is empty while malformed entries are skipped" {
    const valid_responses = [_][]const u8{
        "{\"data\":null}",
        "{\"data\":[null,{}, {\"id\":7}, {\"id\":\"\"}, {\"id\":\"usable\"}]}",
    };
    for (valid_responses, 0..) |response, index| {
        const responses = [_][]const u8{response};
        var fake: FakeTransport = .{ .responses = &responses };
        defer fake.deinit(std.testing.allocator);
        var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
        var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
        defer outcome.deinit();
        try std.testing.expectEqual(index, outcome.models.models.len);
    }
}

test "malformed JSON and valid JSON without a model list have exact diagnostics" {
    inline for (.{ "not json", "{\"data\":[" }) |response| {
        const responses = [_][]const u8{response};
        var fake: FakeTransport = .{ .responses = &responses };
        defer fake.deinit(std.testing.allocator);
        var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
        var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
        try expectFailure(&outcome, "anthropic-test /models response is not valid JSON");
    }

    inline for (.{ "{}", "[]", "null", "{\"data\":{}}" }) |response| {
        const responses = [_][]const u8{response};
        var fake: FakeTransport = .{ .responses = &responses };
        defer fake.deinit(std.testing.allocator);
        var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
        var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
        try expectFailure(&outcome, "anthropic-test /models response has no model list");
    }
}

test "entries without IDs retain the exact diagnostic" {
    const responses = [_][]const u8{"{\"data\":[null,{}, {\"id\":\"\"}]}"};
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(&outcome, "anthropic-test /models response contains no usable model ids");
}

test "metadata includes token limits image support and deduplicated effort order" {
    const response =
        "{\"data\":[{\"id\":\"claude\",\"max_input_tokens\":200000," ++
        "\"max_tokens\":64000,\"capabilities\":{" ++
        "\"image_input\":{\"supported\":false},\"effort\":{" ++
        "\"custom\":{\"supported\":true},\"high\":{\"supported\":true}," ++
        "\"low\":{\"supported\":true},\"xhigh\":{\"supported\":true}," ++
        "\"max\":{\"supported\":true},\"medium\":{\"supported\":true}," ++
        "\"supported\":true,\"other\":{\"supported\":false}}}}]}";
    const responses = [_][]const u8{response};
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();

    const model = outcome.models.models[0];
    try std.testing.expectEqual(@as(u64, 200_000), model.metadata.context_window);
    try std.testing.expectEqual(@as(u64, 64_000), model.metadata.max_output);
    try std.testing.expectEqual(ModelMeta.Support.no, model.metadata.image_input);
    const expected = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "custom" };
    try std.testing.expectEqual(@as(u8, expected.len), model.metadata.efforts.count);
    for (expected, 0..) |effort, index| {
        try std.testing.expectEqualStrings(effort, model.metadata.efforts.valueAt(index));
    }
}

test "effort supported false is known empty" {
    const response =
        "{\"data\":[{\"id\":\"off\",\"capabilities\":{\"effort\":{\"supported\":false}}}," ++
        "{\"id\":\"unknown\",\"capabilities\":{\"effort\":{}}}]}";
    const responses = [_][]const u8{response};
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();
    try std.testing.expect(outcome.models.models[0].metadata.efforts.known);
    try std.testing.expectEqual(@as(u8, 0), outcome.models.models[0].metadata.efforts.count);
    try std.testing.expect(!outcome.models.models[1].metadata.efforts.known);
}

test "oversized and excessive JSON become provider failures" {
    inline for (.{
        "{\"data\":[{\"id\":\"" ++ ("x" ** (ModelListing.maximum_id_bytes + 1)) ++ "\"}]}",
        "[" ** (maximum_json_depth + 1),
    }) |response| {
        const responses = [_][]const u8{response};
        var fake: FakeTransport = .{ .responses = &responses };
        defer fake.deinit(std.testing.allocator);
        var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
        var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
        try expectFailure(&outcome, "anthropic-test /models response exceeds listing limits");
    }
}

test "empty success status authentication status and other status have exact diagnostics" {
    const empty_responses = [_][]const u8{""};
    var empty_fake: FakeTransport = .{ .responses = &empty_responses };
    defer empty_fake.deinit(std.testing.allocator);
    var empty_client = Client.init(JsonTransport.Transport.from(&empty_fake), testConfig());
    var outcome = try empty_client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(&outcome, "anthropic-test sent an empty or truncated /models response");

    const responses = [_][]const u8{"{\"data\":[]}"};
    var fake: FakeTransport = .{ .responses = &responses, .status = 401 };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(
        &outcome,
        "anthropic-test rejected the API key (HTTP 401) — check it and retry",
    );

    client.config.api_key = null;
    fake.status = 403;
    outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(
        &outcome,
        "anthropic-test requires an API key (HTTP 403) — none is configured",
    );

    fake.status = 503;
    outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(&outcome, "listing anthropic-test models failed (HTTP 503)");
}

test "network cancellation and invalid requests map correctly" {
    const responses = [_][]const u8{"{\"data\":[]}"};
    var fake: FakeTransport = .{ .responses = &responses, .transport_error = error.ConnectionFailed };
    defer fake.deinit(std.testing.allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectFailure(&outcome, "could not reach anthropic-test at http://127.0.0.1:8080/v1");

    fake.transport_error = error.Cancelled;
    try std.testing.expectError(
        error.Cancelled,
        client.listModels(std.testing.allocator, std.testing.io, null),
    );

    client.config.endpoint = "https://api.test/v1/not-messages";
    try std.testing.expectError(
        error.InvalidRequest,
        client.listModels(std.testing.allocator, std.testing.io, null),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        deriveModelsUrl(std.testing.allocator, "https://api.test/v1?next=/messages"),
    );
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const responses = [_][]const u8{
        "{\"data\":[{\"id\":\"m1\"}],\"has_more\":true,\"last_id\":\"m1\"}",
        "{\"data\":[{\"id\":\"m2\",\"max_input_tokens\":1000," ++
            "\"capabilities\":{\"effort\":{\"low\":{\"supported\":true}}}}]}",
    };
    var fake: FakeTransport = .{ .responses = &responses };
    defer fake.deinit(allocator);
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig());
    var outcome = try client.listModels(allocator, std.testing.io, null);
    outcome.deinit();
}

test "client parser and pagination release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

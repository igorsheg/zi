const std = @import("std");
const Effort = @import("Effort.zig");
const JsonTransport = @import("JsonTransport.zig");
const ModelListing = @import("ModelListing.zig");
const ModelMeta = @import("ModelMeta.zig");
const Provider = @import("Provider.zig");
const SecureAllocator = @import("SecureAllocator.zig");

pub const maximum_input_bytes: usize = 4 * 1024 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 65_536;
pub const maximum_json_work: usize = 262_144;
pub const maximum_extra_headers: usize = JsonTransport.maximum_headers - 1;
pub const maximum_api_key_bytes: usize = 8 * 1024;

pub const Dialect = enum {
    generic,
    llamacpp,
    openrouter,
};

pub const Config = struct {
    provider_id: []const u8,
    endpoint: []const u8,
    api_key: ?[]const u8 = null,
    extra_headers: []const JsonTransport.Header = &.{},
    privileged_header_policy: JsonTransport.PrivilegedHeaderPolicy = .https_only,
    dialect: Dialect = .generic,
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

        const base_url = deriveBaseUrl(self.config.endpoint) catch return error.InvalidRequest;
        const url = deriveModelsUrl(allocator, base_url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRequest => return error.InvalidRequest,
        };
        defer allocator.free(url);

        const authorization = if (self.config.api_key) |api_key|
            std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch return error.OutOfMemory
        else
            null;
        defer if (authorization) |value| SecureAllocator.wipeFree(allocator, value);

        const header_count = 1 + self.config.extra_headers.len +
            @as(usize, @intFromBool(authorization != null));
        const headers = allocator.alloc(JsonTransport.Header, header_count) catch
            return error.OutOfMemory;
        defer allocator.free(headers);
        var next: usize = 0;
        if (authorization) |value| {
            headers[next] = .{
                .name = "Authorization",
                .value = value,
                .privileged = true,
            };
            next += 1;
        }
        headers[next] = .{ .name = "Accept", .value = "application/json" };
        next += 1;
        for (self.config.extra_headers) |header| {
            headers[next] = header;
            next += 1;
        }

        var response = self.transport.request(allocator, io, .{
            .method = .get,
            .url = url,
            .headers = headers,
            .tick = tick,
            .privileged_header_policy = self.config.privileged_header_policy,
            .limits = .{
                .max_request_body_bytes = 1,
                .max_response_body_bytes = maximum_input_bytes,
                .max_header_bytes = JsonTransport.maximum_header_bytes,
                .header_buffer_bytes = JsonTransport.maximum_header_bytes,
                .connect_timeout_ms = 10_000,
                .idle_timeout_ms = 10_000,
                .total_timeout_ms = 10_000,
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => return error.Cancelled,
            error.InvalidRequest => return error.InvalidRequest,
            else => return failureForTransport(allocator, self.config.provider_id, base_url),
        };
        defer response.deinit(allocator);

        if (response.status < 200 or response.status >= 300) {
            return failureForStatus(
                allocator,
                self.config.provider_id,
                base_url,
                self.config.api_key != null,
                response.status,
            );
        }
        return parseOutcome(allocator, self.config.provider_id, response.body, self.config.dialect);
    }
};

fn validateConfig(config: Config) error{InvalidRequest}!void {
    if (config.provider_id.len == 0 or
        config.provider_id.len > ModelListing.maximum_failure_bytes / 2 or
        !std.unicode.utf8ValidateSlice(config.provider_id) or
        config.endpoint.len == 0 or
        config.endpoint.len > JsonTransport.maximum_url_bytes or
        config.extra_headers.len > maximum_extra_headers)
    {
        return error.InvalidRequest;
    }
    if (config.api_key) |api_key| {
        if (api_key.len == 0 or api_key.len > maximum_api_key_bytes or !headerValueSafe(api_key)) {
            return error.InvalidRequest;
        }
    }
    const fixed_headers: usize = 1 + @as(usize, @intFromBool(config.api_key != null));
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

fn deriveBaseUrl(endpoint: []const u8) error{InvalidRequest}![]const u8 {
    const suffix: []const u8 = if (std.mem.endsWith(u8, endpoint, "/chat/completions"))
        "/chat/completions"
    else if (std.mem.endsWith(u8, endpoint, "/responses"))
        "/responses"
    else
        return error.InvalidRequest;
    const prefix = endpoint[0 .. endpoint.len - suffix.len];
    if (prefix.len == 0) return error.InvalidRequest;
    return prefix;
}

fn deriveModelsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) error{ OutOfMemory, InvalidRequest }![]u8 {
    const length = std.math.add(usize, base_url.len, "/models".len) catch
        return error.InvalidRequest;
    if (length > JsonTransport.maximum_url_bytes) return error.InvalidRequest;
    return std.mem.concat(allocator, u8, &.{ base_url, "/models" });
}

const ParseError = error{
    OutOfMemory,
    InvalidJson,
    NoModelList,
    NoUsableModelIds,
    ResponseTooLarge,
};

fn parseOutcome(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    json: []const u8,
    dialect: Dialect,
) ModelListing.Error!ModelListing.Outcome {
    if (json.len == 0) return failureMessage(
        allocator,
        "{s} sent an empty or truncated /models response",
        .{provider_id},
    );
    const list = parseResponse(allocator, json, dialect) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return failureMessage(
            allocator,
            "{s} /models response is not valid JSON",
            .{provider_id},
        ),
        error.NoModelList => return failureMessage(
            allocator,
            "{s} /models response has no model list",
            .{provider_id},
        ),
        error.NoUsableModelIds => return failureMessage(
            allocator,
            "{s} /models response contains no usable model ids",
            .{provider_id},
        ),
        error.ResponseTooLarge => return failureMessage(
            allocator,
            "{s} /models response exceeds listing limits",
            .{provider_id},
        ),
    };
    return .{ .models = list };
}

fn parse(
    allocator: std.mem.Allocator,
    json: []const u8,
    dialect: Dialect,
) ParseError!ModelListing.OwnedList {
    return parseResponse(allocator, json, dialect);
}

fn parseResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
    dialect: Dialect,
) ParseError!ModelListing.OwnedList {
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
    if (data == .null) return finishEmpty(allocator);
    if (data != .array) return error.NoModelList;
    const entries = data.array.items;
    if (entries.len == 0) return finishEmpty(allocator);
    if (entries.len > ModelListing.maximum_models) return error.ResponseTooLarge;

    const owner = ModelListing.Owner.init(allocator) catch return error.OutOfMemory;
    errdefer owner.destroy();
    const result_allocator = owner.arenaAllocator();
    var result: std.ArrayList(ModelListing.Model) = .empty;
    defer result.deinit(result_allocator);
    result.ensureTotalCapacity(result_allocator, entries.len) catch return error.OutOfMemory;

    for (entries) |entry_value| {
        const entry = valueObject(entry_value) orelse continue;
        const id = optionalString(entry, "id") orelse continue;
        if (id.len == 0) continue;
        if (id.len > ModelListing.maximum_id_bytes) return error.ResponseTooLarge;

        var model: ModelListing.Model = .{ .id = id };
        switch (dialect) {
            .generic => {},
            .llamacpp => try parseLlamaCpp(result_allocator, entry, &model),
            .openrouter => try parseOpenRouter(entry, &model),
        }
        result.appendAssumeCapacity(model);
    }
    if (result.items.len == 0) return error.NoUsableModelIds;
    return owner.finish(result.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => return error.ResponseTooLarge,
    };
}

fn finishEmpty(allocator: std.mem.Allocator) ParseError!ModelListing.OwnedList {
    const owner = ModelListing.Owner.init(allocator) catch return error.OutOfMemory;
    errdefer owner.destroy();
    return owner.finish(&.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => unreachable,
    };
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

fn parseLlamaCpp(
    allocator: std.mem.Allocator,
    entry: std.json.ObjectMap,
    model: *ModelListing.Model,
) ParseError!void {
    if (objectMember(entry, "meta")) |meta| {
        model.metadata.context_window = positiveInteger(meta.get("n_ctx")) orelse 0;
    }
    if (objectMember(entry, "architecture")) |architecture| {
        model.metadata.image_input = capabilityFromArray(architecture.get("input_modalities"), "image");
    }

    const status = objectMember(entry, "status") orelse return;
    if (booleanMember(status, "failed") == true) {
        if (integerMember(status, "exit_code")) |exit_code| {
            model.description = std.fmt.allocPrint(
                allocator,
                "failed (exit {d})",
                .{exit_code},
            ) catch return error.OutOfMemory;
        } else {
            model.description = "failed";
        }
        return;
    }
    const state = optionalString(status, "value") orelse return;
    if (state.len == 0 or std.mem.eql(u8, state, "unloaded")) return;
    if (state.len > ModelListing.maximum_description_bytes) return error.ResponseTooLarge;
    model.description = state;
}

fn parseOpenRouter(entry: std.json.ObjectMap, model: *ModelListing.Model) ParseError!void {
    model.metadata.context_window = positiveInteger(entry.get("context_length")) orelse 0;
    if (objectMember(entry, "top_provider")) |top_provider| {
        model.metadata.max_output = positiveInteger(top_provider.get("max_completion_tokens")) orelse 0;
    }
    const modalities = if (objectMember(entry, "architecture")) |architecture|
        architecture.get("input_modalities")
    else
        null;
    model.metadata.image_input = capabilityFromArray(modalities, "image");
    model.metadata.tools = capabilityFromArray(entry.get("supported_parameters"), "tools");

    if (objectMember(entry, "pricing")) |pricing| {
        model.metadata.rates = parseRates(pricing);
        try parseTiers(pricing, &model.metadata.tiers);
    }
    model.metadata.efforts = parseOpenRouterEfforts(entry);
    model.description = try descriptionLead(entry);
}

fn parseRates(object: std.json.ObjectMap) ModelMeta.Rates {
    return .{
        .input = tokenRate(object, "prompt"),
        .output = tokenRate(object, "completion"),
        .cache_read = tokenRate(object, "input_cache_read"),
        .cache_write = tokenRate(object, "input_cache_write"),
        .cache_write_1h = tokenRate(object, "input_cache_write_1h"),
    };
}

fn tokenRate(object: std.json.ObjectMap, name: []const u8) ?f64 {
    const text = optionalString(object, name) orelse return null;
    if (text.len == 0) return null;
    const per_token = std.fmt.parseFloat(f64, text) catch return null;
    if (per_token < 0 or !std.math.isFinite(per_token)) return null;
    const per_million = per_token * 1_000_000.0;
    return if (std.math.isFinite(per_million)) per_million else null;
}

fn parseTiers(pricing: std.json.ObjectMap, tiers: *ModelMeta.Tiers) ParseError!void {
    const overrides = pricing.get("overrides") orelse return;
    if (overrides != .array) return;
    tiers.known = true;
    for (overrides.array.items) |override_value| {
        if (tiers.count >= ModelMeta.maximum_tiers) break;
        const override = valueObject(override_value) orelse continue;
        const threshold = positiveInteger(override.get("min_prompt_tokens")) orelse continue;
        tiers.add(.{
            .context_threshold = threshold,
            .rates = parseRates(override),
        }) catch |err| switch (err) {
            error.InvalidThreshold => continue,
            error.TooManyTiers => break,
        };
    }
}

fn parseOpenRouterEfforts(entry: std.json.ObjectMap) Effort.Set {
    const reasoning = objectMember(entry, "reasoning") orelse {
        const parameters_value = entry.get("supported_parameters") orelse return .{};
        if (parameters_value != .array) return .{};
        for (parameters_value.array.items) |parameter| {
            if (parameter != .string) continue;
            if (std.mem.eql(u8, parameter.string, "reasoning") or
                std.mem.eql(u8, parameter.string, "reasoning_effort")) return .{};
        }
        return Effort.Set.init(&.{}) catch unreachable;
    };
    const levels = reasoning.get("supported_efforts") orelse return .{};
    if (levels != .array) return .{};
    var efforts = Effort.Set.init(&.{}) catch unreachable;
    for (levels.array.items) |level| {
        if (level != .string) continue;
        efforts.add(level.string) catch continue;
    }
    return efforts;
}

fn descriptionLead(entry: std.json.ObjectMap) ParseError!?[]const u8 {
    const description = optionalString(entry, "description") orelse return null;
    const line_end = std.mem.findAny(u8, description, "\r\n") orelse description.len;
    var end = line_end;
    while (end > 0 and (description[end - 1] == ' ' or description[end - 1] == '\t')) end -= 1;
    if (end == 0) return null;
    if (end > ModelListing.maximum_description_bytes) return error.ResponseTooLarge;
    return description[0..end];
}

fn capabilityFromArray(value: ?std.json.Value, wanted: []const u8) ModelMeta.Support {
    const present = value orelse return .unknown;
    if (present != .array) return .unknown;
    for (present.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, wanted)) return .yes;
    }
    return .no;
}

fn positiveInteger(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0) return null;
    return @intCast(present.integer);
}

fn integerMember(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
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
    base_url: []const u8,
    has_key: bool,
    status: u16,
) ModelListing.Error!ModelListing.Outcome {
    return formattedListFailure(allocator, provider_id, base_url, has_key, status);
}

fn failureForTransport(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
) ModelListing.Error!ModelListing.Outcome {
    return formattedListFailure(allocator, provider_id, base_url, false, 0);
}

fn formattedListFailure(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
    has_key: bool,
    status: u16,
) ModelListing.Error!ModelListing.Outcome {
    if (status == 401 or status == 403) {
        if (has_key) return failureMessage(
            allocator,
            "{s} rejected the API key (HTTP {d}): check it and retry",
            .{ provider_id, status },
        );
        return failureMessage(
            allocator,
            "{s} requires an API key (HTTP {d}): none is configured",
            .{ provider_id, status },
        );
    }
    if (status != 0) return failureMessage(
        allocator,
        "listing {s} models failed (HTTP {d})",
        .{ provider_id, status },
    );
    return failureMessage(
        allocator,
        "could not reach {s} at {s}",
        .{ provider_id, base_url },
    );
}

fn failureMessage(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) ModelListing.Error!ModelListing.Outcome {
    var buffer: [ModelListing.maximum_failure_bytes]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch
        return error.InvalidRequest;
    return ModelListing.failure(allocator, message);
}

const FakeTransport = struct {
    status: u16 = 200,
    body: []const u8 = "{\"data\":[{\"id\":\"model\"}]}",
    transport_error: ?JsonTransport.Error = null,
    valid: bool = true,
    calls: usize = 0,

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *FakeTransport,
        value: JsonTransport.Request,
    ) JsonTransport.Error!JsonTransport.Response {
        self.calls += 1;
        self.valid = self.valid and value.method == .get;
        self.valid = self.valid and std.mem.eql(u8, value.url, "http://127.0.0.1:8080/v1/models");
        self.valid = self.valid and value.headers.len == 3;
        self.valid = self.valid and value.headers[0].isPrivileged();
        self.valid = self.valid and std.mem.eql(u8, value.headers[0].value, "Bearer secret");
        self.valid = self.valid and std.ascii.eqlIgnoreCase(value.headers[1].name, "accept");
        self.valid = self.valid and std.mem.eql(u8, value.headers[1].value, "application/json");
        self.valid = self.valid and std.mem.eql(u8, value.headers[2].name, "X-Route");
        self.valid = self.valid and value.privileged_header_policy == .https_or_loopback_http;
        self.valid = self.valid and value.limits.max_response_body_bytes == maximum_input_bytes;
        self.valid = self.valid and value.limits.connect_timeout_ms == 10_000;
        self.valid = self.valid and value.limits.idle_timeout_ms == 10_000;
        self.valid = self.valid and value.limits.total_timeout_ms == 10_000;
        if (self.transport_error) |err| return err;
        return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }
};

fn testConfig(dialect: Dialect) Config {
    return .{
        .provider_id = "local",
        .endpoint = "http://127.0.0.1:8080/v1/chat/completions",
        .api_key = "secret",
        .extra_headers = &.{.{ .name = "X-Route", .value = "one" }},
        .privileged_header_policy = .https_or_loopback_http,
        .dialect = dialect,
    };
}

fn expectExactFailure(outcome: *ModelListing.Outcome, expected: []const u8) !void {
    defer outcome.deinit();
    try std.testing.expect(outcome.* == .failure);
    try std.testing.expectEqualStrings(expected, outcome.failure.message);
}

test "client derives models URL and sends bounded authenticated GET" {
    var fake: FakeTransport = .{};
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig(.generic));
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    defer outcome.deinit();
    try std.testing.expect(outcome == .models);
    try std.testing.expectEqual(@as(usize, 1), outcome.models.models.len);
    try std.testing.expect(fake.valid);

    client.config.endpoint = "https://api.test/v1/responses";
    const base_url = try deriveBaseUrl(client.config.endpoint);
    try std.testing.expectEqualStrings("https://api.test/v1", base_url);
    const url = try deriveModelsUrl(std.testing.allocator, base_url);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.test/v1/models", url);
    try std.testing.expectError(
        error.InvalidRequest,
        deriveBaseUrl("https://api.test/v1/completions"),
    );
}

test "null data and empty arrays are valid empty catalogs" {
    inline for (.{ "{\"data\":null}", "{\"data\":[]}" }) |fixture| {
        var outcome = try parseOutcome(std.testing.allocator, "compatible", fixture, .generic);
        defer outcome.deinit();
        try std.testing.expect(outcome == .models);
        try std.testing.expectEqual(@as(usize, 0), outcome.models.models.len);
    }
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "not json", .generic));
    inline for (.{ "{}", "{\"data\":{}}" }) |fixture| {
        try std.testing.expectError(error.NoModelList, parse(std.testing.allocator, fixture, .generic));
    }
    try std.testing.expectError(
        error.NoUsableModelIds,
        parse(std.testing.allocator, "{\"data\":[null,{}, {\"id\":7}, {\"id\":\"\"}]}", .generic),
    );

    var list = try parse(
        std.testing.allocator,
        "{\"data\":[null,{\"id\":7},{\"id\":\"first\"},{\"id\":\"second\"}]}",
        .generic,
    );
    defer list.deinit();
    try std.testing.expectEqualStrings("first", list.models[0].id);
    try std.testing.expectEqualStrings("second", list.models[1].id);
}

test "client reports exact response shape failures and keeps oversize diagnostics" {
    var fake: FakeTransport = .{};
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig(.generic));
    const cases = [_]struct { body: []const u8, message: []const u8 }{
        .{ .body = "", .message = "local sent an empty or truncated /models response" },
        .{ .body = "not json", .message = "local /models response is not valid JSON" },
        .{ .body = "{}", .message = "local /models response has no model list" },
        .{
            .body = "{\"data\":[null,{\"id\":\"\"}]}",
            .message = "local /models response contains no usable model ids",
        },
        .{
            .body = "{\"data\":[{\"id\":\"" ++
                ("x" ** (ModelListing.maximum_id_bytes + 1)) ++ "\"}]}",
            .message = "local /models response exceeds listing limits",
        },
    };
    inline for (cases) |case| {
        fake.body = case.body;
        var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
        try expectExactFailure(&outcome, case.message);
    }
}

test "listing bounds depth ids models and descriptions" {
    try std.testing.expectError(
        error.ResponseTooLarge,
        parse(std.testing.allocator, "{\"data\":[{\"id\":\"" ++
            ("x" ** (ModelListing.maximum_id_bytes + 1)) ++ "\"}]}", .generic),
    );
    try std.testing.expectError(
        error.ResponseTooLarge,
        parse(std.testing.allocator, "[" ** (maximum_json_depth + 1), .generic),
    );
    try std.testing.expectError(
        error.ResponseTooLarge,
        parse(std.testing.allocator, "{\"data\":[{\"id\":\"x\",\"description\":\"" ++
            ("x" ** (ModelListing.maximum_description_bytes + 1)) ++ "\"}]}", .openrouter),
    );
}

test "llama cpp metadata follows router status and modalities" {
    var list = try parse(
        std.testing.allocator,
        "{\"data\":[" ++
            "{\"id\":\"vision\",\"meta\":{\"n_ctx\":32768}," ++
            "\"architecture\":{\"input_modalities\":[\"text\",\"image\"]}," ++
            "\"status\":{\"value\":\"loading\"}}," ++
            "{\"id\":\"bad\",\"status\":{\"failed\":true,\"exit_code\":9}}," ++
            "{\"id\":\"idle\",\"status\":{\"value\":\"unloaded\"}}]}",
        .llamacpp,
    );
    defer list.deinit();
    try std.testing.expectEqual(@as(u64, 32_768), list.models[0].metadata.context_window);
    try std.testing.expectEqual(ModelMeta.Support.yes, list.models[0].metadata.image_input);
    try std.testing.expectEqualStrings("loading", list.models[0].description.?);
    try std.testing.expectEqualStrings("failed (exit 9)", list.models[1].description.?);
    try std.testing.expect(list.models[2].description == null);
}

test "OpenRouter metadata includes capabilities pricing tiers efforts and lead" {
    const fixture =
        "{\"data\":[{\"id\":\"vendor/model\"," ++
        "\"description\":\"First line.  \\n\\nMore.\",\"context_length\":1000000," ++
        "\"top_provider\":{\"max_completion_tokens\":64000}," ++
        "\"architecture\":{\"input_modalities\":[\"text\",\"image\"]}," ++
        "\"supported_parameters\":[\"tools\"]," ++
        "\"reasoning\":{\"supported_efforts\":[\"high\",\"low\"]}," ++
        "\"pricing\":{\"prompt\":\"0.000003\",\"completion\":\"0.000015\"," ++
        "\"input_cache_read\":\"0.0000003\",\"overrides\":[{" ++
        "\"min_prompt_tokens\":200000,\"prompt\":\"0.000006\"}]}}]}";
    var list = try parse(std.testing.allocator, fixture, .openrouter);
    defer list.deinit();
    const model = list.models[0];
    try std.testing.expectEqualStrings("First line.", model.description.?);
    try std.testing.expectEqual(@as(u64, 1_000_000), model.metadata.context_window);
    try std.testing.expectEqual(@as(u64, 64_000), model.metadata.max_output);
    try std.testing.expectEqual(ModelMeta.Support.yes, model.metadata.image_input);
    try std.testing.expectEqual(ModelMeta.Support.yes, model.metadata.tools);
    try std.testing.expectEqual(@as(f64, 3), model.metadata.rates.input.?);
    try std.testing.expectEqual(@as(f64, 15), model.metadata.rates.output.?);
    try std.testing.expectEqual(@as(f64, 0.3), model.metadata.rates.cache_read.?);
    try std.testing.expectEqual(@as(u8, 1), model.metadata.tiers.count);
    try std.testing.expectEqual(@as(u64, 200_000), model.metadata.tiers.at(0).context_threshold);
    try std.testing.expectEqual(@as(f64, 6), model.metadata.tiers.at(0).rates.input.?);
    try std.testing.expect(model.metadata.efforts.has("high"));
    try std.testing.expect(model.metadata.efforts.has("low"));
}

test "HTTP status network cancellation and invalid config map to the listing contract" {
    var fake: FakeTransport = .{ .status = 503 };
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig(.generic));
    var outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectExactFailure(&outcome, "listing local models failed (HTTP 503)");

    outcome = try failureForStatus(std.testing.allocator, "local", "https://api.test/v1", true, 401);
    try expectExactFailure(&outcome, "local rejected the API key (HTTP 401): check it and retry");
    outcome = try failureForStatus(std.testing.allocator, "local", "https://api.test/v1", false, 403);
    try expectExactFailure(&outcome, "local requires an API key (HTTP 403): none is configured");

    fake.status = 200;
    fake.transport_error = error.ConnectionFailed;
    outcome = try client.listModels(std.testing.allocator, std.testing.io, null);
    try expectExactFailure(&outcome, "could not reach local at http://127.0.0.1:8080/v1");

    fake.transport_error = error.Cancelled;
    try std.testing.expectError(
        error.Cancelled,
        client.listModels(std.testing.allocator, std.testing.io, null),
    );
    client.config.endpoint = "https://api.test/v1/completions";
    try std.testing.expectError(
        error.InvalidRequest,
        client.listModels(std.testing.allocator, std.testing.io, null),
    );
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var fake: FakeTransport = .{ .body = "{\"data\":[{\"id\":\"model\",\"description\":\"lead\\nrest\"," ++
        "\"pricing\":{\"prompt\":\"0.000001\"}}]}" };
    var client = Client.init(JsonTransport.Transport.from(&fake), testConfig(.openrouter));
    var outcome = try client.listModels(allocator, std.testing.io, null);
    outcome.deinit();
}

test "client and parser release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

const std = @import("std");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const ProviderConfig = @import("../ProviderConfig.zig");
const DiagnosticText = @import("DiagnosticText.zig");

const LocalDiscovery = ai.LocalDiscovery;
const Definition = config.ProviderDefinitions.Definition;

pub const default_ollama_base_url = "http://127.0.0.1:11434/v1";

pub const HeaderWarningKind = enum {
    missing_environment,
    invalid_resolved_value,
    protocol_owned,
    duplicate,
};

pub const HeaderWarning = struct {
    kind: HeaderWarningKind,
    name: []u8,
    environment_name: ?[]u8 = null,
};

/// Move-only resolved header snapshot. Names and values are owned; values are
/// wiped on release. Every header is marked privileged because configured
/// values may carry credentials even when their names are unconventional.
pub const ResolvedHeaders = struct {
    allocator: std.mem.Allocator,
    values: []ai.Transport.Header,
    warnings: []HeaderWarning,

    pub fn init(
        allocator: std.mem.Allocator,
        definition: ?*const Definition,
        environment: config.ApiKey.Environment,
    ) !ResolvedHeaders {
        const source = if (definition) |value| value.extra_headers orelse &.{} else &.{};
        var values: std.ArrayList(ai.Transport.Header) = .empty;
        defer values.deinit(allocator);
        errdefer for (values.items) |header| deinitHeader(allocator, header);
        var warnings: std.ArrayList(HeaderWarning) = .empty;
        defer warnings.deinit(allocator);
        errdefer for (warnings.items) |warning| deinitWarning(allocator, warning);

        var retained_bytes: usize = 0;
        for (source) |header| {
            if (protocolOwned(header.name)) {
                try appendWarning(allocator, &warnings, .protocol_owned, header.name, null);
                continue;
            }
            var duplicate = false;
            for (values.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, header.name)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                try appendWarning(allocator, &warnings, .duplicate, header.name, null);
                continue;
            }

            const resolved = resolveValue(header.value, environment) orelse {
                try appendWarning(
                    allocator,
                    &warnings,
                    .missing_environment,
                    header.name,
                    if (header.value.len > 1) header.value[1..] else "",
                );
                continue;
            };
            if (resolved.value.len == 0 or !headerValueValid(resolved.value)) {
                try appendWarning(allocator, &warnings, .invalid_resolved_value, header.name, null);
                continue;
            }
            if (values.items.len == ai.JsonTransport.maximum_headers) return error.InvalidHeaderValue;
            retained_bytes = std.math.add(usize, retained_bytes, header.name.len) catch
                return error.InvalidHeaderValue;
            retained_bytes = std.math.add(usize, retained_bytes, resolved.value.len) catch
                return error.InvalidHeaderValue;
            if (retained_bytes > LocalDiscovery.maximum_header_bytes) return error.InvalidHeaderValue;

            const name = try allocator.dupe(u8, header.name);
            const value = allocator.dupe(u8, resolved.value) catch |err| {
                allocator.free(name);
                return err;
            };
            values.append(allocator, .{
                .name = name,
                .value = value,
                .privileged = resolved.privileged,
            }) catch |err| {
                allocator.free(name);
                std.crypto.secureZero(u8, value);
                allocator.free(value);
                return err;
            };
        }
        const owned_values = try values.toOwnedSlice(allocator);
        errdefer {
            for (owned_values) |header| deinitHeader(allocator, header);
            allocator.free(owned_values);
        }
        const owned_warnings = try warnings.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .values = owned_values,
            .warnings = owned_warnings,
        };
    }

    pub fn deinit(self: *ResolvedHeaders) void {
        for (self.values) |header| deinitHeader(self.allocator, header);
        self.allocator.free(self.values);
        for (self.warnings) |warning| deinitWarning(self.allocator, warning);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }

    pub fn renderWarnings(self: *const ResolvedHeaders, writer: *std.Io.Writer, provider: []const u8) !void {
        for (self.warnings) |warning| {
            try writer.writeAll("zi: warning: providers.");
            try DiagnosticText.write(writer, provider);
            try writer.writeAll(".extra_headers: header '");
            try DiagnosticText.write(writer, warning.name);
            try writer.writeAll(switch (warning.kind) {
                .missing_environment => "' dropped — $",
                .invalid_resolved_value => "' needs a control-character-free value — ignoring it\n",
                .protocol_owned => "' is protocol-owned — ignoring it\n",
                .duplicate => "' duplicates another header name — ignoring it\n",
            });
            if (warning.kind == .missing_environment) {
                try DiagnosticText.write(writer, warning.environment_name.?);
                try writer.writeAll(" is not set\n");
            }
        }
    }
};

fn appendWarning(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList(HeaderWarning),
    kind: HeaderWarningKind,
    name: []const u8,
    environment_name: ?[]const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    const owned_environment = if (environment_name) |value|
        allocator.dupe(u8, value) catch |err| {
            allocator.free(owned_name);
            return err;
        }
    else
        null;
    warnings.append(allocator, .{
        .kind = kind,
        .name = owned_name,
        .environment_name = owned_environment,
    }) catch |err| {
        allocator.free(owned_name);
        if (owned_environment) |value| allocator.free(value);
        return err;
    };
}

fn deinitWarning(allocator: std.mem.Allocator, warning: HeaderWarning) void {
    allocator.free(warning.name);
    if (warning.environment_name) |value| allocator.free(value);
}

fn deinitHeader(allocator: std.mem.Allocator, header: ai.Transport.Header) void {
    allocator.free(header.name);
    const value = @constCast(header.value);
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

const ResolvedValue = struct {
    value: []const u8,
    privileged: bool,
};

fn resolveValue(value: []const u8, environment: config.ApiKey.Environment) ?ResolvedValue {
    if (value.len == 0 or value[0] != '$') return .{ .value = value, .privileged = false };
    if (value.len >= 2 and value[1] == '$') return .{ .value = value[1..], .privileged = false };
    const resolved = environment.get(value[1..]) orelse return null;
    return if (resolved.len == 0) null else .{ .value = resolved, .privileged = true };
}

fn headerValueValid(value: []const u8) bool {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

fn protocolOwned(name: []const u8) bool {
    inline for (.{
        "proxy-authorization",
        "accept",
        "content-type",
        "host",
        "content-length",
        "transfer-encoding",
        "connection",
        "te",
        "trailer",
        "upgrade",
    }) |owned| {
        if (std.ascii.eqlIgnoreCase(name, owned)) return true;
    }
    return false;
}

pub const PreparedLlama = struct {
    allocator: std.mem.Allocator,
    probe: LocalDiscovery.PreparedProbe,
    configured_model: ?[]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        store: config.Store,
        extra_headers: []const ai.Transport.Header,
        tick: ?ai.Provider.Tick,
    ) !PreparedLlama {
        var base = try store.readNonempty(allocator, "providers.llamacpp.base_url");
        defer base.deinit(allocator);
        var generated_base: ?[]u8 = null;
        defer if (generated_base) |value| allocator.free(value);
        const base_url = base.value orelse blk: {
            const port = try config.Settings.getInt(store, allocator, "providers.llamacpp.port");
            generated_base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{port.value});
            break :blk generated_base.?;
        };

        var api_key = try store.readNonempty(allocator, "providers.llamacpp.api_key");
        defer api_key.deinit(allocator);
        var model = try store.readForProvider(allocator, "model", "llamacpp");
        defer model.deinit(allocator);

        var probe = try LocalDiscovery.PreparedProbe.init(allocator, .{
            .base_url = base_url,
            .bearer_token = api_key.value,
            .extra_headers = extra_headers,
            .tick = tick,
        });
        errdefer probe.deinit();
        const configured_model = model.value;
        model.value = null;
        return .{
            .allocator = allocator,
            .probe = probe,
            .configured_model = configured_model,
        };
    }

    pub fn deinit(self: *PreparedLlama) void {
        self.probe.deinit();
        if (self.configured_model) |model| {
            std.crypto.secureZero(u8, model);
            self.allocator.free(model);
        }
        self.* = undefined;
    }
};

pub const LlamaStatus = union(enum) {
    @"unreachable",
    invalid_response,
    reconciled: LocalDiscovery.Reconcile,
};

pub const LlamaOutcome = struct {
    allocator: std.mem.Allocator,
    configured_model: ?[]u8,
    status: LlamaStatus,

    pub fn deinit(self: *LlamaOutcome) void {
        switch (self.status) {
            .reconciled => |*decision| decision.deinit(self.allocator),
            else => {},
        }
        if (self.configured_model) |model| {
            std.crypto.secureZero(u8, model);
            self.allocator.free(model);
        }
        self.* = undefined;
    }

    pub fn available(self: *const LlamaOutcome) bool {
        return self.status == .reconciled;
    }

    pub fn constructible(self: *const LlamaOutcome) bool {
        return switch (self.status) {
            .reconciled => true,
            .@"unreachable" => self.hasConfiguredModel(),
            .invalid_response => false,
        };
    }

    /// Mirrors hax's one exception: an explicit nonempty model tolerates only a
    /// transport/HTTP failure. A successful malformed response remains fatal.
    pub fn fatalForExplicit(self: *const LlamaOutcome) bool {
        return switch (self.status) {
            .invalid_response => true,
            .@"unreachable" => !self.hasConfiguredModel(),
            .reconciled => false,
        };
    }

    pub fn reconciliation(self: *const LlamaOutcome) ?ProviderConfig.LlamaModelReconciliation {
        return switch (self.status) {
            .@"unreachable", .invalid_response => null,
            .reconciled => |decision| switch (decision) {
                .unchanged => .unchanged,
                .no_models, .clear_configured => .clear,
                .replacement => |replacement| .{ .replace = replacement.model },
                .canonical => |model| .{ .replace = model },
            },
        };
    }

    pub fn renderWarnings(self: *const LlamaOutcome, writer: *std.Io.Writer) !void {
        switch (self.status) {
            .@"unreachable", .invalid_response => {},
            .reconciled => |decision| switch (decision) {
                .no_models => try writer.writeAll(
                    "zi: warning: llama.cpp: no models available — " ++
                        "start llama-server with -m, -hf, or --models-dir\n",
                ),
                .replacement => |replacement| if (replacement.warning) |warning| {
                    const message = try warning.format(self.allocator);
                    defer self.allocator.free(message);
                    try writer.writeAll("zi: warning: ");
                    try DiagnosticText.write(writer, message);
                    try writer.writeByte('\n');
                },
                .clear_configured => if (self.configured_model) |model| if (model.len != 0) {
                    try writer.writeAll("zi: warning: llama.cpp: model '");
                    try DiagnosticText.write(writer, model);
                    try writer.writeAll("' is not in the router catalog — pick one with /model\n");
                },
                .unchanged, .canonical => {},
            },
        }
    }

    fn hasConfiguredModel(self: *const LlamaOutcome) bool {
        const model = self.configured_model orelse return false;
        return model.len != 0;
    }
};

pub fn executeLlama(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: ai.JsonTransport.Transport,
    prepared: *PreparedLlama,
) error{ OutOfMemory, Cancelled }!LlamaOutcome {
    var probe_result = LocalDiscovery.probe(allocator, io, transport, &prepared.probe);
    defer probe_result.deinit(allocator);

    const configured_model = prepared.configured_model;
    prepared.configured_model = null;
    errdefer if (configured_model) |model| {
        std.crypto.secureZero(u8, model);
        allocator.free(model);
    };

    const status: LlamaStatus = switch (probe_result) {
        .@"unreachable" => |failure| switch (failure.reason) {
            .transport => |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Cancelled => return error.Cancelled,
                else => .@"unreachable",
            },
            .non_success, .empty_body => .@"unreachable",
        },
        .body => |body| blk: {
            const decision = LocalDiscovery.reconcileLlama(
                allocator,
                body,
                configured_model,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponse, error.ResponseTooLarge => break :blk .invalid_response,
            };
            break :blk .{ .reconciled = decision };
        },
    };
    return .{ .allocator = allocator, .configured_model = configured_model, .status = status };
}

pub fn prepareOllama(
    allocator: std.mem.Allocator,
    definitions: []const Definition,
    extra_headers: []const ai.Transport.Header,
    tick: ?ai.Provider.Tick,
) !?LocalDiscovery.PreparedProbe {
    const definition = findDefinition(definitions, "ollama");
    if (definition) |value| {
        if (declaresKey(value)) return null;
    }
    const base_url = if (definition) |value|
        if (value.base_url) |base| if (base.len != 0) base else default_ollama_base_url else default_ollama_base_url
    else
        default_ollama_base_url;
    const probe = try LocalDiscovery.PreparedProbe.init(allocator, .{
        .base_url = base_url,
        .extra_headers = extra_headers,
        .tick = tick,
    });
    return probe;
}

pub fn executeReachability(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: ai.JsonTransport.Transport,
    prepared: *const LocalDiscovery.PreparedProbe,
) error{ OutOfMemory, Cancelled }!bool {
    var result = LocalDiscovery.probe(allocator, io, transport, prepared);
    defer result.deinit(allocator);
    return switch (result) {
        .body => true,
        .@"unreachable" => |failure| switch (failure.reason) {
            .transport => |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                else => false,
            },
            .non_success, .empty_body => false,
        },
    };
}

pub fn resolveHeaders(
    allocator: std.mem.Allocator,
    definitions: []const Definition,
    id: []const u8,
    environment: config.ApiKey.Environment,
) !ResolvedHeaders {
    return ResolvedHeaders.init(allocator, findDefinition(definitions, id), environment);
}

fn findDefinition(definitions: []const Definition, id: []const u8) ?*const Definition {
    for (definitions) |*definition| if (std.mem.eql(u8, definition.id, id)) return definition;
    return null;
}

fn declaresKey(definition: *const Definition) bool {
    if (definition.api_key) |value| if (value.len != 0) return true;
    if (definition.api_key_env) |value| if (value.len != 0) return true;
    return false;
}

const EmptyEnvironment = struct {
    pub fn get(_: *const EmptyEnvironment, _: []const u8) ?[]const u8 {
        return null;
    }
};

fn testStore(document: *const config.Document, environment: *const EmptyEnvironment) config.Store {
    return .init(.{
        .file = document,
        .registry = config.Settings.storeRegistry(),
        .environment = .from(environment),
    });
}

const FakeTransport = struct {
    status: u16 = 200,
    body: []const u8,

    pub fn request(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *FakeTransport,
        _: ai.JsonTransport.Request,
    ) ai.JsonTransport.Error!ai.JsonTransport.Response {
        return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }
};

test "llama startup resolves settings and classic replacement outranks configured model" {
    var document = try config.Document.parse(
        std.testing.allocator,
        "{\"model\":\"stale\",\"providers\":{\"llamacpp\":{" ++
            "\"base_url\":\"http://127.0.0.1:18080/v1/\",\"api_key\":\"secret\"}}}",
        .{},
    );
    defer document.deinit();
    const environment: EmptyEnvironment = .{};
    var prepared = try PreparedLlama.init(std.testing.allocator, testStore(&document, &environment), &.{}, null);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:18080/v1/models", prepared.probe.url);
    try std.testing.expectEqualStrings("Bearer secret", prepared.probe.headers[0].value);

    var fake: FakeTransport = .{ .body = "{\"data\":[{\"id\":\"served\"}]}" };
    var outcome = try executeLlama(
        std.testing.allocator,
        std.testing.io,
        ai.JsonTransport.Transport.from(&fake),
        &prepared,
    );
    defer outcome.deinit();
    try std.testing.expect(outcome.available());
    try std.testing.expectEqualStrings("served", outcome.reconciliation().?.replace);
    try std.testing.expect(!outcome.fatalForExplicit());
    var warnings: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer warnings.deinit();
    try outcome.renderWarnings(&warnings.writer);
    try std.testing.expectEqualStrings(
        "zi: warning: llama.cpp: model 'stale' is not served — using 'served'\n",
        warnings.written(),
    );
}

test "llama startup distinguishes unreachable explicit fallback from malformed success" {
    var document = try config.Document.parse(std.testing.allocator, "{\"model\":\"kept\"}", .{});
    defer document.deinit();
    const environment: EmptyEnvironment = .{};

    var unavailable = try PreparedLlama.init(std.testing.allocator, testStore(&document, &environment), &.{}, null);
    defer unavailable.deinit();
    var fake: FakeTransport = .{ .status = 503, .body = "down" };
    var outcome = try executeLlama(
        std.testing.allocator,
        std.testing.io,
        ai.JsonTransport.Transport.from(&fake),
        &unavailable,
    );
    try std.testing.expect(!outcome.available());
    try std.testing.expect(outcome.constructible());
    try std.testing.expect(!outcome.fatalForExplicit());
    try std.testing.expect(outcome.reconciliation() == null);
    outcome.deinit();

    var malformed = try PreparedLlama.init(std.testing.allocator, testStore(&document, &environment), &.{}, null);
    defer malformed.deinit();
    fake.status = 200;
    fake.body = "{}";
    outcome = try executeLlama(
        std.testing.allocator,
        std.testing.io,
        ai.JsonTransport.Transport.from(&fake),
        &malformed,
    );
    defer outcome.deinit();
    try std.testing.expect(outcome.fatalForExplicit());

    var no_model_document = try config.Document.parse(std.testing.allocator, "{}", .{});
    defer no_model_document.deinit();
    var no_model = try PreparedLlama.init(
        std.testing.allocator,
        testStore(&no_model_document, &environment),
        &.{},
        null,
    );
    defer no_model.deinit();
    fake.status = 503;
    fake.body = "down";
    var missing = try executeLlama(
        std.testing.allocator,
        std.testing.io,
        ai.JsonTransport.Transport.from(&fake),
        &no_model,
    );
    defer missing.deinit();
    try std.testing.expect(!missing.constructible());
    try std.testing.expect(missing.fatalForExplicit());
}

test "Ollama availability uses recipe base and keyed definitions skip probing" {
    var probe = (try prepareOllama(std.testing.allocator, &.{}, &.{}, null)).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/models", probe.url);
    probe.deinit();

    const keyed: Definition = .{
        .id = @constCast("ollama"),
        .base_url = @constCast("http://127.0.0.1:1234/v1"),
        .api_key_env = @constCast("OLLAMA_KEY"),
    };
    try std.testing.expect((try prepareOllama(std.testing.allocator, &.{keyed}, &.{}, null)) == null);

    const overridden: Definition = .{
        .id = @constCast("ollama"),
        .base_url = @constCast("http://127.0.0.1:1234/v1/"),
    };
    probe = (try prepareOllama(std.testing.allocator, &.{overridden}, &.{}, null)).?;
    defer probe.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/v1/models", probe.url);
}

const HeaderEnvironment = struct {
    entries: []const Entry,

    const Entry = struct { name: []const u8, value: []const u8 };

    pub fn get(self: *const HeaderEnvironment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
    }
};

test "configured local headers resolve environment escapes and drop unsafe members" {
    const environment: HeaderEnvironment = .{ .entries = &.{
        .{ .name = "TOKEN", .value = "secret" },
        .{ .name = "BAD", .value = "line\nbreak" },
    } };
    var missing_name = "X-Missing".*;
    var missing_value = "$MISSING".*;
    var source = [_]config.ProviderDefinitions.Header{
        .{ .name = @constCast("X-Token"), .value = @constCast("$TOKEN") },
        .{ .name = @constCast("X-Literal"), .value = @constCast("$$cash") },
        .{ .name = &missing_name, .value = &missing_value },
        .{ .name = @constCast("Content-Type"), .value = @constCast("text/plain") },
        .{ .name = @constCast("X-Bad"), .value = @constCast("$BAD") },
        .{ .name = @constCast("x-token"), .value = @constCast("duplicate") },
    };
    const definition: Definition = .{
        .id = @constCast("llamacpp"),
        .extra_headers = @constCast(&source),
    };
    var resolved = try ResolvedHeaders.init(
        std.testing.allocator,
        &definition,
        config.ApiKey.Environment.from(&environment),
    );
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 2), resolved.values.len);
    try std.testing.expectEqualStrings("X-Token", resolved.values[0].name);
    try std.testing.expectEqualStrings("secret", resolved.values[0].value);
    try std.testing.expect(resolved.values[0].privileged);
    try std.testing.expectEqualStrings("$cash", resolved.values[1].value);
    try std.testing.expect(!resolved.values[1].isPrivileged());
    try std.testing.expectEqual(@as(usize, 4), resolved.warnings.len);
    @memset(&missing_name, 'x');
    @memset(&missing_value, 'x');

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try resolved.renderWarnings(&output.writer, "llamacpp");
    try std.testing.expect(std.mem.find(u8, output.written(), "MISSING") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "protocol-owned") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "control-character-free") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "duplicates") != null);
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const header_environment: HeaderEnvironment = .{ .entries = &.{.{ .name = "TOKEN", .value = "secret" }} };
    const source = [_]config.ProviderDefinitions.Header{
        .{ .name = @constCast("X-Token"), .value = @constCast("$TOKEN") },
        .{ .name = @constCast("X-Missing"), .value = @constCast("$MISSING") },
    };
    const definition: Definition = .{
        .id = @constCast("llamacpp"),
        .extra_headers = @constCast(&source),
    };
    var headers = try ResolvedHeaders.init(
        allocator,
        &definition,
        config.ApiKey.Environment.from(&header_environment),
    );
    defer headers.deinit();

    var document = try config.Document.parse(allocator, "{\"model\":\"stale\"}", .{});
    defer document.deinit();
    const environment: EmptyEnvironment = .{};
    var prepared = try PreparedLlama.init(
        allocator,
        testStore(&document, &environment),
        headers.values,
        null,
    );
    defer prepared.deinit();
    var fake: FakeTransport = .{ .body = "{\"data\":[{\"id\":\"served\"}]}" };
    var outcome = try executeLlama(
        allocator,
        std.testing.io,
        ai.JsonTransport.Transport.from(&fake),
        &prepared,
    );
    outcome.deinit();
}

test "local startup releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

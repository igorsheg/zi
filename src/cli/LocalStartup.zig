const std = @import("std");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const ProviderConfig = @import("../ProviderConfig.zig");
const ProviderHeaders = @import("../ProviderHeaders.zig");
const DiagnosticText = @import("DiagnosticText.zig");

const LocalDiscovery = ai.LocalDiscovery;
const Definition = config.ProviderDefinitions.Definition;

pub const default_ollama_base_url = "http://127.0.0.1:11434/v1";

pub const ResolvedHeaders = ProviderHeaders.Resolution;

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
    return ProviderHeaders.resolve(
        allocator,
        ProviderHeaders.findDefinition(definitions, id),
        environment,
    );
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

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var document = try config.Document.parse(allocator, "{\"model\":\"stale\"}", .{});
    defer document.deinit();
    const environment: EmptyEnvironment = .{};
    var prepared = try PreparedLlama.init(
        allocator,
        testStore(&document, &environment),
        &.{},
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

const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntime = @import("AgentSessionRuntime.zig");
const ModelConfigSnapshot = @import("ModelConfigSnapshot.zig");
const ModelResolution = @import("ModelResolution.zig");
const SessionFormat = @import("SessionFormat.zig");
const SessionJournal = @import("SessionJournal.zig");
const SessionSelection = @import("SessionSelection.zig");
const ZiPaths = @import("ZiPaths.zig");

const RuntimeServices = @This();

pub const Error = error{
    OutOfMemory,
    InvalidPath,
    InvalidHeader,
    InvalidRecord,
    UnsupportedVersion,
    SessionTooLarge,
    TooManyEntries,
    AlreadyExists,
    NotFound,
    UnsafeFile,
    OpenFailed,
    CreateFailed,
    CreateIndeterminate,
    ReadFailed,
    AppendFailed,
    RepairFailed,
    CommitIndeterminate,
    ReadOnly,
    InvalidSessionPath,
    MissingCwd,
    CwdUnavailable,
    SessionChanged,
    SessionStorageUnavailable,
    TooManySessions,
    Cancelled,
    InvalidModelConfiguration,
    SelectionRequired,
    IncompleteSelection,
    UnknownSelection,
    MissingCredential,
    InvalidCredential,
    DuplicateCredential,
    UnsupportedCliCredential,
    DuplicateToolName,
    InvalidToolDefinition,
    UnknownTool,
    InvalidToolArguments,
    PersistenceFailed,
};

pub const Inputs = struct {
    startup_cwd: []const u8,
    home: []const u8,
    session: SessionSelection.Intent,
    sources: SessionFormat.Sources,
    requested_provider: ?[]const u8 = null,
    requested_model: ?[]const u8 = null,
    cli_api_key: ?[]const u8 = null,
    stored_credentials: []const ModelResolution.Credential = &.{},
    openai_environment_api_key: ?[]const u8 = null,
    options: AgentSessionRuntime.Options = .{},
};

const Transport = union(enum) {
    http,
    borrowed: ai.transport.Transport,
};

io: std.Io,
allocator: std.mem.Allocator,
selection: SessionSelection,
cwd: std.Io.Dir,
snapshot: ModelConfigSnapshot,
resolved: ModelResolution.Resolved,
runtime: *AgentSessionRuntime,

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
) Error!*RuntimeServices {
    return createOwned(allocator, io, inputs, .http);
}

pub fn session(self: *RuntimeServices) *AgentSession {
    return self.runtime.session();
}

pub fn paths(self: *const RuntimeServices) *const ZiPaths {
    return self.selection.pathsView();
}

pub fn journalPath(self: *const RuntimeServices) []const u8 {
    return self.selection.journalPath();
}

pub fn modelDiagnostic(self: *const RuntimeServices) ?ModelConfigSnapshot.Diagnostic {
    return self.snapshot.diagnostic();
}

// Heap destruction follows explicit field invalidation.
// ziglint-ignore: Z030
pub fn deinit(self: *RuntimeServices) void {
    const allocator = self.allocator;
    self.runtime.deinit();
    self.cwd.close(self.io);
    self.resolved.deinit();
    self.snapshot.deinit();
    self.selection.deinit();
    self.* = undefined;
    allocator.destroy(self);
}

fn createWithTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    transport: ai.transport.Transport,
) Error!*RuntimeServices {
    return createOwned(allocator, io, inputs, .{ .borrowed = transport });
}

fn createOwned(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    transport: Transport,
) Error!*RuntimeServices {
    var selection = try SessionSelection.select(
        allocator,
        io,
        inputs.startup_cwd,
        inputs.home,
        inputs.sources,
        inputs.session,
    );
    errdefer selection.deinit();

    var snapshot = try ModelConfigSnapshot.load(allocator, io, selection.pathsView());
    errdefer snapshot.deinit();
    const requested = effectiveRequest(&selection, inputs);
    var resolved = try ModelResolution.resolve(allocator, .{
        .model_config = snapshot.view(),
        .requested_provider = requested.provider,
        .requested_model = requested.model,
        .cli_api_key = inputs.cli_api_key,
        .stored_credentials = inputs.stored_credentials,
        .openai_environment_api_key = inputs.openai_environment_api_key,
    });
    errdefer resolved.deinit();

    var cwd = std.Io.Dir.openDir(.cwd(), io, selection.pathsView().cwd, .{}) catch
        return error.CwdUnavailable;
    errdefer cwd.close(io);
    var opened = selection.takeJournal();
    const runtime = switch (transport) {
        .http => try AgentSessionRuntime.createDurable(
            allocator,
            io,
            cwd,
            resolved.runtimeConfig(),
            inputs.options,
            &opened,
            inputs.sources,
        ),
        .borrowed => |borrowed| try AgentSessionRuntime.createDurableWithTransport(
            allocator,
            io,
            cwd,
            borrowed,
            resolved.runtimeConfig(),
            inputs.options,
            &opened,
            inputs.sources,
            .none(),
        ),
    };
    errdefer runtime.deinit();

    const self = try allocator.create(RuntimeServices);
    self.* = .{
        .io = io,
        .allocator = allocator,
        .selection = selection,
        .cwd = cwd,
        .snapshot = snapshot,
        .resolved = resolved,
        .runtime = runtime,
    };
    return self;
}

const RequestedModel = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
};

fn effectiveRequest(selection: *const SessionSelection, inputs: Inputs) RequestedModel {
    if (inputs.requested_provider != null or inputs.requested_model != null) {
        return .{ .provider = inputs.requested_provider, .model = inputs.requested_model };
    }
    const restored = selection.restoredModel() orelse return .{ .provider = null, .model = null };
    return .{ .provider = restored.provider, .model = restored.model };
}

const fake_api = ai.transport_testing;

const TestSources = struct {
    next_id: u64 = 0,
    next_ms: u64 = 1_777_800_000_000,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *TestSources = @ptrCast(@alignCast(context));
        self.next_id += 1;
        var bytes: [16]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[8..16], self.next_id, .big);
        return bytes;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *TestSources = @ptrCast(@alignCast(context));
        defer self.next_ms += 1;
        return self.next_ms;
    }

    fn view(self: *TestSources) SessionFormat.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

const custom_models =
    // ziglint-ignore: Z024 -- compact external JSON fixture
    \\{"providers":{"custom-openai":{"baseUrl":"https://example.test/openai/v1","api":"openai-responses","models":[{"id":"model-a"},{"id":"model-b"}]}}}
;

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn writeCustomModels(temporary: *std.testing.TmpDir) !void {
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/models.json",
        .data = custom_models,
    });
}

fn openJournal(allocator: std.mem.Allocator, path: []const u8) !SessionJournal.Opened {
    const parent = std.fs.path.dirname(path).?;
    var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, parent, .{});
    defer directory.close(std.testing.io);
    return SessionJournal.openReadOnly(
        allocator,
        std.testing.io,
        directory,
        std.fs.path.basename(path),
    );
}

test "runtime services compose effective paths, models, credentials, durability, and transport" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeCustomModels(&temporary);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.txt", .data = "cwd evidence" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    const response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"composed"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
    var fake = fake_api.FakeTransport.init(&exchanges);

    var services = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "custom-openai",
        .requested_model = "model-a",
        .cli_api_key = "custom-secret",
    }, fake.transport());
    const journal_path = try std.testing.allocator.dupe(u8, services.journalPath());
    defer std.testing.allocator.free(journal_path);
    try std.testing.expectEqualStrings(root, services.paths().cwd);
    try std.testing.expect(services.modelDiagnostic() == null);
    try std.testing.expectEqualStrings("composed", try services.session().prompt("hello"));
    services.deinit();

    var opened = try openJournal(std.testing.allocator, journal_path);
    defer opened.deinit();
    const entries = opened.restore_candidate.entries;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("custom-openai", entries[0].model_change.selection.provider);
    try std.testing.expectEqualStrings("model-a", entries[0].model_change.selection.model);
    try std.testing.expect(entries[3].turn_end.outcome == .completed);
    try std.testing.expectEqual(@as(usize, 1), fake.next_index);
}

test "runtime services restore the journal model unless an explicit override commits first" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeCustomModels(&temporary);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});

    var created = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "custom-openai",
        .requested_model = "model-a",
        .cli_api_key = "custom-secret",
    }, fake.transport());
    const journal_path = try std.testing.allocator.dupe(u8, created.journalPath());
    defer std.testing.allocator.free(journal_path);
    created.deinit();

    var restored = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .{ .open = journal_path },
        .sources = sources.view(),
        .cli_api_key = "custom-secret",
    }, fake.transport());
    restored.deinit();

    var overridden = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .{ .open = journal_path },
        .sources = sources.view(),
        .requested_provider = "custom-openai",
        .requested_model = "model-b",
        .cli_api_key = "custom-secret",
    }, fake.transport());
    overridden.deinit();

    var opened = try openJournal(std.testing.allocator, journal_path);
    defer opened.deinit();
    const entries = opened.restore_candidate.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("model-a", entries[0].model_change.selection.model);
    try std.testing.expectEqualStrings("model-b", entries[1].model_change.selection.model);
}

test "runtime services reject unavailable restored models and credentials without rewriting" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeCustomModels(&temporary);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});
    var created = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "custom-openai",
        .requested_model = "model-a",
        .cli_api_key = "custom-secret",
    }, fake.transport());
    const journal_path = try std.testing.allocator.dupe(u8, created.journalPath());
    defer std.testing.allocator.free(journal_path);
    created.deinit();

    try std.testing.expectError(error.MissingCredential, createWithTransport(
        std.testing.allocator,
        std.testing.io,
        .{
            .startup_cwd = root,
            .home = root,
            .session = .{ .open = journal_path },
            .sources = sources.view(),
        },
        fake.transport(),
    ));
    try temporary.dir.deleteFile(std.testing.io, ".zi/agent/models.json");

    try std.testing.expectError(error.UnknownSelection, createWithTransport(
        std.testing.allocator,
        std.testing.io,
        .{
            .startup_cwd = root,
            .home = root,
            .session = .{ .open = journal_path },
            .sources = sources.view(),
            .cli_api_key = "custom-secret",
        },
        fake.transport(),
    ));
    var opened = try openJournal(std.testing.allocator, journal_path);
    defer opened.deinit();
    try std.testing.expectEqual(@as(usize, 1), opened.restore_candidate.entries.len);
    try std.testing.expectEqualStrings("model-a", opened.restore_candidate.active_model.?.model);
}

const AllocationContext = struct {
    root: []const u8,
    sources: *TestSources,
    fake: *fake_api.FakeTransport,
};

fn createAndDispose(allocator: std.mem.Allocator, context: *AllocationContext) !void {
    var services = try createWithTransport(allocator, std.testing.io, .{
        .startup_cwd = context.root,
        .home = context.root,
        .session = .new,
        .sources = context.sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
    }, context.fake.transport());
    services.deinit();
}

test "runtime services settle every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});
    var context: AllocationContext = .{ .root = root, .sources = &sources, .fake = &fake };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDispose, .{&context});
}

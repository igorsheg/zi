const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntime = @import("AgentSessionRuntime.zig");
const CredentialManager = @import("CredentialManager.zig");
const CredentialStore = @import("CredentialStore.zig");
const ModelConfigSnapshot = @import("ModelConfigSnapshot.zig");
const ModelResolution = @import("ModelResolution.zig");
const PromptFiles = @import("PromptFiles.zig");
const SessionFormat = @import("SessionFormat.zig");
const SessionJournal = @import("SessionJournal.zig");
const SessionSelection = @import("SessionSelection.zig");
const SystemPrompt = @import("SystemPrompt.zig");
const ZiPaths = @import("ZiPaths.zig");

const RuntimeServices = @This();

pub const Error = error{
    OutOfMemory,
    InvalidPath,
    InvalidHeader,
    InvalidRecord,
    UnsupportedVersion,
    InvalidCredentialFile,
    UnsafeCredentialStorage,
    CredentialReadFailed,
    CredentialLockFailed,
    CredentialWriteFailed,
    CredentialCommitIndeterminate,
    CredentialRefreshUnavailable,
    CredentialRefreshFailed,
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
    InvalidSystemPrompt,
    SystemPromptTooLarge,
    PromptFileTooLarge,
    InvalidPromptFile,
    UnsafePromptFile,
    PromptFileReadFailed,
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
    environment: ai.auth.Environment = .{},
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
credential_resolver: *CredentialManager.PersistentResolver,
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
    self.credential_resolver.deinit();
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

    var runtime_options = inputs.options;
    runtime_options.prompt.working_directory = selection.pathsView().cwd;
    const requested_prompt_files = requestedPromptFiles(runtime_options.prompt.policy);
    var prompt_files: ?PromptFiles = if (requested_prompt_files.system or requested_prompt_files.append)
        try PromptFiles.load(allocator, io, selection.pathsView(), requested_prompt_files)
    else
        null;
    defer if (prompt_files) |*files| files.deinit();
    var discovered_appends: [1][]const u8 = undefined;
    runtime_options.prompt.policy = resolvePromptPolicy(
        runtime_options.prompt.policy,
        if (prompt_files) |*files| files else null,
        &discovered_appends,
    );

    var snapshot = try ModelConfigSnapshot.load(allocator, io, selection.pathsView());
    errdefer snapshot.deinit();
    const requested = effectiveRequest(&selection, inputs);
    var refresh_http = ai.transport.HttpTransport.init(allocator);
    const refresh_transport = switch (transport) {
        .http => refresh_http.transport(),
        .borrowed => |borrowed| borrowed,
    };
    var stored_credentials = CredentialManager.loadForRuntime(
        allocator,
        io,
        selection.pathsView(),
        refresh_transport,
        .{
            .model_config = snapshot.view(),
            .selection = .{
                .provider = requested.provider orelse "",
                .model = requested.model orelse "",
            },
            .explicit_api_key = inputs.cli_api_key,
            .now_ms = inputs.sources.nowMsFn(inputs.sources.clock_context),
        },
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCredentialFile => error.InvalidCredentialFile,
        error.UnsupportedVersion => error.UnsupportedVersion,
        error.UnsafePath => error.UnsafeCredentialStorage,
        error.ReadFailed => error.CredentialReadFailed,
        error.LockFailed => error.CredentialLockFailed,
        error.WriteFailed => error.CredentialWriteFailed,
        error.CommitIndeterminate => error.CredentialCommitIndeterminate,
        error.InvalidModelConfiguration => error.InvalidModelConfiguration,
        error.AuthenticationUnavailable,
        error.RefreshUnavailable,
        => error.CredentialRefreshUnavailable,
        error.Rejected,
        error.InvalidResponse,
        error.Cancelled,
        error.TimedOut,
        error.InvalidUrl,
        error.InvalidRequest,
        error.ConnectionFailed,
        error.ResponseTooLarge,
        error.ConsumerStopped,
        => error.CredentialRefreshFailed,
    };
    defer stored_credentials.deinit();
    var resolved = try ModelResolution.resolve(allocator, .{
        .model_config = snapshot.view(),
        .requested_provider = requested.provider,
        .requested_model = requested.model,
        .cli_api_key = inputs.cli_api_key,
        .stored_credentials = stored_credentials.entries,
        .environment = inputs.environment,
    });
    errdefer resolved.deinit();

    const credential_resolver = CredentialManager.PersistentResolver.init(
        allocator,
        selection.pathsView().cwd,
        selection.pathsView().home,
        snapshot.view(),
        resolved.selection,
        inputs.cli_api_key,
        inputs.environment,
        inputs.sources.clock_context,
        inputs.sources.nowMsFn,
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPath => error.InvalidPath,
    };
    errdefer credential_resolver.deinit();
    var runtime_config = resolved.runtimeConfig();
    runtime_config.auth_resolver = credential_resolver.resolver();
    var cwd = std.Io.Dir.openDir(.cwd(), io, selection.pathsView().cwd, .{}) catch
        return error.CwdUnavailable;
    errdefer cwd.close(io);
    var opened = selection.takeJournal();
    const runtime = switch (transport) {
        .http => try AgentSessionRuntime.createDurable(
            allocator,
            io,
            cwd,
            runtime_config,
            runtime_options,
            &opened,
            inputs.sources,
        ),
        .borrowed => |borrowed| try AgentSessionRuntime.createDurableWithTransport(
            allocator,
            io,
            cwd,
            borrowed,
            runtime_config,
            runtime_options,
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
        .credential_resolver = credential_resolver,
        .runtime = runtime,
    };
    return self;
}

fn requestedPromptFiles(policy: SystemPrompt.Policy) PromptFiles.Requested {
    return switch (policy) {
        .verbatim => .{},
        .composed => |composition| .{
            .system = switch (composition.base) {
                .builtin => true,
                .custom => false,
            },
            .append = composition.appends.len == 0,
        },
    };
}

fn resolvePromptPolicy(
    policy: SystemPrompt.Policy,
    files: ?*const PromptFiles,
    discovered_appends: *[1][]const u8,
) SystemPrompt.Policy {
    return switch (policy) {
        .verbatim => policy,
        .composed => |composition| .{ .composed = .{
            .base = switch (composition.base) {
                .builtin => if (files) |loaded|
                    if (loaded.system()) |text| .{ .custom = text } else .builtin
                else
                    .builtin,
                .custom => composition.base,
            },
            .appends = if (composition.appends.len > 0)
                composition.appends
            else if (files) |loaded|
                if (loaded.append()) |text| appends: {
                    discovered_appends[0] = text;
                    break :appends discovered_appends[0..1];
                } else &.{}
            else
                &.{},
        } },
    };
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
    \\{"providers":{"custom-openai":{"baseUrl":"https://example.test/openai/v1","protocol":"openai-responses","models":[{"id":"model-a"},{"id":"model-b"}]}}}
;

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn testAccessToken(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{account_id},
    );
    defer allocator.free(payload);
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
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

test "runtime services compose effective paths, models, prompts, credentials, durability, and transport" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.txt", .data = "cwd evidence" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var credential_paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer credential_paths.deinit();
    try CredentialStore.put(std.testing.allocator, std.testing.io, &credential_paths, .{
        .provider_id = "custom-openai",
        .credential = .{ .api_key = .{ .key = "stored-custom-secret" } },
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Global system base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/APPEND_SYSTEM.md",
        .data = "Ignored global rules.",
    });
    try writeCustomModels(&temporary);
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
    const Inspector = struct {
        const Self = @This();

        prompt_seen: bool = false,

        fn inspect(context: *anyopaque, request: ai.transport.Request) error{Rejected}!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (std.mem.find(u8, request.body, "Global system base.") == null) return error.Rejected;
            if (std.mem.find(u8, request.body, "Use focused tests.") == null) return error.Rejected;
            if (std.mem.find(u8, request.body, "Ignored global rules.") != null) return error.Rejected;
            self.prompt_seen = true;
        }
    };
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: Inspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = Inspector.inspect };

    var services = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "custom-openai",
        .requested_model = "model-a",
        .options = .{ .prompt = .{ .policy = .{ .composed = .{
            .appends = &.{"Use focused tests."},
        } } } },
    }, fake.transport());
    const journal_path = try std.testing.allocator.dupe(u8, services.journalPath());
    defer std.testing.allocator.free(journal_path);
    try std.testing.expectEqualStrings(root, services.paths().cwd);
    try std.testing.expect(services.modelDiagnostic() == null);
    try std.testing.expect(std.mem.startsWith(u8, services.session().systemPrompt(), "Global system base."));
    try std.testing.expect(std.mem.find(u8, services.session().systemPrompt(), root) != null);
    try std.testing.expect(std.mem.find(
        u8,
        services.session().systemPrompt(),
        "<human_rules>\nUse focused tests.\n</human_rules>",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        services.session().systemPrompt(),
        "Ignored global rules.",
    ) == null);
    try std.testing.expectEqualStrings("composed", try services.session().prompt("hello"));
    try std.testing.expect(inspector.prompt_seen);
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

test "runtime services discover global prompt files for default composition" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Discovered base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/APPEND_SYSTEM.md",
        .data = "Discovered rules.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});

    var services = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
    }, fake.transport());
    defer services.deinit();

    try std.testing.expect(std.mem.startsWith(u8, services.session().systemPrompt(), "Discovered base."));
    try std.testing.expect(std.mem.find(
        u8,
        services.session().systemPrompt(),
        "<human_rules>\nDiscovered rules.\n</human_rules>",
    ) != null);
}

test "runtime services do not read global prompt files shadowed by explicit policy" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.createDir(std.testing.io, ".zi/agent/APPEND_SYSTEM.md", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});

    var replaced = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
        .options = .{ .prompt = .{ .policy = .{ .verbatim = "Explicit replacement." } } },
    }, fake.transport());
    try std.testing.expectEqualStrings("Explicit replacement.", replaced.session().systemPrompt());
    replaced.deinit();

    try temporary.dir.deleteTree(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Discovered base.",
    });
    var appended = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
        .options = .{ .prompt = .{ .policy = .{ .composed = .{
            .appends = &.{"Explicit rules."},
        } } } },
    }, fake.transport());
    defer appended.deinit();
    try std.testing.expect(std.mem.startsWith(u8, appended.session().systemPrompt(), "Discovered base."));
    try std.testing.expect(std.mem.find(u8, appended.session().systemPrompt(), "Explicit rules.") != null);
}

test "runtime services refresh and persist expired Codex credentials before prompting" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var credential_paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer credential_paths.deinit();
    try CredentialStore.put(std.testing.allocator, std.testing.io, &credential_paths, .{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "expired-access",
            .refresh = "expired-refresh",
            .expires_at_ms = 1,
            .account_id = "expired-account",
        } },
    });
    const access = try testAccessToken(std.testing.allocator, "runtime-account");
    defer std.testing.allocator.free(access);
    const refresh_response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"runtime-refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(refresh_response);
    const model_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"refreshed codex"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = refresh_response } },
        .{ .response = .{ .status = 200, .body = model_response } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var sources: TestSources = .{};
    var services = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
    }, fake.transport());
    try std.testing.expectEqualStrings("refreshed codex", try services.session().prompt("hello"));
    services.deinit();

    var stored = try CredentialStore.load(std.testing.allocator, std.testing.io, &credential_paths);
    defer stored.deinit();
    const refreshed = stored.entries[0].credential.oauth;
    try std.testing.expectEqualStrings(access, refreshed.access);
    try std.testing.expectEqualStrings("runtime-refresh", refreshed.refresh);
    try std.testing.expectEqualStrings("runtime-account", refreshed.account_id.?);
    try std.testing.expectEqual(@as(usize, 2), fake.next_index);
}

test "long-lived runtime rechecks OAuth expiry before each invocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var credential_paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer credential_paths.deinit();
    var sources: TestSources = .{};
    const expires_at_ms = sources.next_ms + 10 * 60 * 1000;
    try CredentialStore.put(std.testing.allocator, std.testing.io, &credential_paths, .{
        .provider_id = "openai-codex",
        .credential = .{ .oauth = .{
            .access = "initial-access",
            .refresh = "initial-refresh",
            .expires_at_ms = expires_at_ms,
            .account_id = "initial-account",
        } },
    });
    const access = try testAccessToken(std.testing.allocator, "rotated-account");
    defer std.testing.allocator.free(access);
    const refresh_response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(refresh_response);
    const first_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"first"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const second_response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_2","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"second"}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = first_response } },
        .{ .response = .{ .status = 200, .body = refresh_response } },
        .{ .response = .{ .status = 200, .body = second_response } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var services = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
    }, fake.transport());
    defer services.deinit();
    try std.testing.expectEqualStrings("first", try services.session().prompt("one"));
    sources.next_ms = expires_at_ms;
    try std.testing.expectEqualStrings("second", try services.session().prompt("two"));
    try std.testing.expectEqual(@as(usize, 3), fake.next_index);

    var stored = try CredentialStore.load(std.testing.allocator, std.testing.io, &credential_paths);
    defer stored.deinit();
    try std.testing.expectEqualStrings("rotated-refresh", stored.entries[0].credential.oauth.refresh);
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

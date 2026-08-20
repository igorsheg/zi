const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntime = @import("AgentSessionRuntime.zig");
const CredentialManager = @import("CredentialManager.zig");
const CredentialStore = @import("CredentialStore.zig");
const ContextFiles = @import("ContextFiles.zig");
const ModelConfigSnapshot = @import("ModelConfigSnapshot.zig");
const ModelResolution = @import("ModelResolution.zig");
const ProjectTrust = @import("ProjectTrust.zig");
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
    ContextFileTooLarge,
    ContextFilesTooLarge,
    TooManyContextFiles,
    ContextTraversalTooDeep,
    InvalidContextFile,
    UnsafeContextFile,
    ContextFileReadFailed,
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
    project_trust: ProjectTrust.Intent = .automatic,
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
    const project_trust = ProjectTrust.resolve(inputs.project_trust);
    var prompt_files: ?PromptFiles = if (requested_prompt_files.system or requested_prompt_files.append)
        try PromptFiles.load(allocator, io, selection.pathsView(), requested_prompt_files, project_trust)
    else
        null;
    defer if (prompt_files) |*files| files.deinit();
    var discovered_rules: [1][]const u8 = undefined;
    runtime_options.prompt.policy = resolvePromptPolicy(
        runtime_options.prompt.policy,
        if (prompt_files) |*files| files else null,
        &discovered_rules,
    );

    var context_files: ?ContextFiles = if (requestsContextFiles(runtime_options.prompt.policy))
        try ContextFiles.load(allocator, io, selection.pathsView())
    else
        null;
    defer if (context_files) |*files| files.deinit();
    var discovered_context_sections: []SystemPrompt.ContextSection = &.{};
    defer if (discovered_context_sections.len > 0) allocator.free(discovered_context_sections);
    if (context_files) |*files| {
        const loaded_sections = files.sections();
        if (loaded_sections.len > 0) {
            discovered_context_sections = try allocator.alloc(SystemPrompt.ContextSection, loaded_sections.len);
            for (loaded_sections, discovered_context_sections) |source, *destination| {
                destination.* = .{ .path = source.path, .text = source.text };
            }
        }
    }
    runtime_options.prompt.policy = resolveContextPolicy(
        runtime_options.prompt.policy,
        discovered_context_sections,
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
            .append = composition.rules.len == 0,
        },
    };
}

fn resolvePromptPolicy(
    policy: SystemPrompt.Policy,
    files: ?*const PromptFiles,
    discovered_rules: *[1][]const u8,
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
            .context_sections = composition.context_sections,
            .rules = if (composition.rules.len > 0)
                composition.rules
            else if (files) |loaded|
                if (loaded.append()) |text| rules: {
                    discovered_rules[0] = text;
                    break :rules discovered_rules[0..1];
                } else &.{}
            else
                &.{},
        } },
    };
}

fn requestsContextFiles(policy: SystemPrompt.Policy) bool {
    return switch (policy) {
        .verbatim => false,
        .composed => |composition| composition.context_sections.len == 0,
    };
}

fn resolveContextPolicy(
    policy: SystemPrompt.Policy,
    discovered: []const SystemPrompt.ContextSection,
) SystemPrompt.Policy {
    return switch (policy) {
        .verbatim => policy,
        .composed => |composition| .{ .composed = .{
            .base = composition.base,
            .context_sections = if (composition.context_sections.len > 0)
                composition.context_sections
            else
                discovered,
            .rules = composition.rules,
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
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Untrusted project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/APPEND_SYSTEM.md",
        .data = "Untrusted project rules.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/AGENTS.md",
        .data = "Global context instructions.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = "Project context instructions.",
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
            if (std.mem.find(u8, request.body, "Global context instructions.") == null) return error.Rejected;
            if (std.mem.find(u8, request.body, "Project context instructions.") == null) return error.Rejected;
            if (std.mem.find(u8, request.body, "Untrusted project base.") != null) return error.Rejected;
            if (std.mem.find(u8, request.body, "Untrusted project rules.") != null) return error.Rejected;
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
            .rules = &.{"Use focused tests."},
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
    const global_context_position = std.mem.find(
        u8,
        services.session().systemPrompt(),
        "Global context instructions.",
    ).?;
    const project_context_position = std.mem.find(
        u8,
        services.session().systemPrompt(),
        "Project context instructions.",
    ).?;
    const explicit_rules_position = std.mem.find(
        u8,
        services.session().systemPrompt(),
        "Use focused tests.",
    ).?;
    try std.testing.expect(global_context_position < project_context_position);
    try std.testing.expect(project_context_position < explicit_rules_position);
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

test "runtime services gate project prompt precedence with launch trust" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/SYSTEM.md",
        .data = "Global base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/APPEND_SYSTEM.md",
        .data = "Global rules.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/APPEND_SYSTEM.md",
        .data = "Project rules.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});

    var automatic = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
    }, fake.transport());
    try std.testing.expect(std.mem.startsWith(u8, automatic.session().systemPrompt(), "Global base."));
    try std.testing.expect(std.mem.find(u8, automatic.session().systemPrompt(), "Global rules.") != null);
    automatic.deinit();

    var approved = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
        .project_trust = .approve,
    }, fake.transport());
    try std.testing.expect(std.mem.startsWith(u8, approved.session().systemPrompt(), "Project base."));
    try std.testing.expect(std.mem.find(u8, approved.session().systemPrompt(), "Project rules.") != null);
    approved.deinit();

    var explicit_rules = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
        .project_trust = .approve,
        .options = .{ .prompt = .{ .policy = .{ .composed = .{
            .rules = &.{"Explicit rules."},
        } } } },
    }, fake.transport());
    defer explicit_rules.deinit();
    try std.testing.expect(std.mem.startsWith(u8, explicit_rules.session().systemPrompt(), "Project base."));
    try std.testing.expect(std.mem.find(u8, explicit_rules.session().systemPrompt(), "Explicit rules.") != null);
    try std.testing.expect(std.mem.find(u8, explicit_rules.session().systemPrompt(), "Project rules.") == null);
}

test "runtime services do not read global prompt files shadowed by explicit policy" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent/SYSTEM.md");
    try temporary.dir.createDir(std.testing.io, ".zi/agent/APPEND_SYSTEM.md", .default_dir);
    try temporary.dir.createDir(std.testing.io, "AGENTS.md", .default_dir);
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

    try temporary.dir.deleteTree(std.testing.io, "AGENTS.md");
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
            .rules = &.{"Explicit rules."},
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

test "runtime services discover context from a resumed session working directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "launch/.zi");
    try temporary.dir.createDirPath(std.testing.io, "stored/.zi");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "launch/AGENTS.md",
        .data = "Launch directory context.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "stored/AGENTS.md",
        .data = "Stored directory context.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "launch/.zi/SYSTEM.md",
        .data = "Launch project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "stored/.zi/SYSTEM.md",
        .data = "Stored project base.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const launch_cwd = try std.fs.path.resolve(std.testing.allocator, &.{ root, "launch" });
    defer std.testing.allocator.free(launch_cwd);
    const stored_cwd = try std.fs.path.resolve(std.testing.allocator, &.{ root, "stored" });
    defer std.testing.allocator.free(stored_cwd);
    var sources: TestSources = .{};
    var fake = fake_api.FakeTransport.init(&.{});

    var created = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = stored_cwd,
        .home = root,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = "secret",
    }, fake.transport());
    const journal_path = try std.testing.allocator.dupe(u8, created.journalPath());
    defer std.testing.allocator.free(journal_path);
    created.deinit();

    var resumed = try createWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = launch_cwd,
        .home = root,
        .session = .{ .open = journal_path },
        .sources = sources.view(),
        .cli_api_key = "secret",
        .project_trust = .approve,
    }, fake.transport());
    defer resumed.deinit();
    try std.testing.expectEqualStrings(stored_cwd, resumed.paths().cwd);
    try std.testing.expect(std.mem.startsWith(u8, resumed.session().systemPrompt(), "Stored project base."));
    try std.testing.expect(std.mem.find(u8, resumed.session().systemPrompt(), "Launch project base.") == null);
    try std.testing.expect(std.mem.find(
        u8,
        resumed.session().systemPrompt(),
        "Stored directory context.",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        resumed.session().systemPrompt(),
        "Launch directory context.",
    ) == null);
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

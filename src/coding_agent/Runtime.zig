const std = @import("std");
const builtin = @import("builtin");
const ai = @import("../ai/root.zig");
const agent_root = @import("../agent/root.zig");
const agent_session_mod = @import("AgentSession.zig");
const Credentials = @import("Credentials.zig");
const Model = @import("Model.zig");
const ProjectTrust = @import("ProjectTrust.zig");
const Prompt = @import("Prompt.zig");
const Session = @import("Session.zig");
const SessionFormat = @import("SessionFormat.zig");
const SettingsStore = @import("SettingsStore.zig");
const ZiPaths = @import("ZiPaths.zig");

/// Test-only: opens a dedicated cwd handle for a session so the session's
/// toolset workspace can close it without closing the caller's TmpDir handle.
fn testSessionCwd(dir: std.Io.Dir) !std.Io.Dir {
    return dir.openDir(std.testing.io, ".", .{});
}

const ModelAdmission = struct {
    const CredentialManager = Credentials.Manager;
    const ModelBootstrapPolicy = Model.BootstrapPolicy;
    const ModelConfig = Model.Config;
    const ModelResolution = Model.Resolution;
    const Error = error{
        OutOfMemory,
        Cancelled,
        SelectionRequired,
        IncompleteSelection,
        UnknownSelection,
        MissingCredential,
        InvalidCredential,
        DuplicateCredential,
        UnsupportedCliCredential,
        InvalidModelConfiguration,
        InvalidCredentialFile,
        UnsupportedVersion,
        UnsafeCredentialStorage,
        CredentialReadFailed,
        CredentialLockFailed,
        CredentialWriteFailed,
        CredentialCommitIndeterminate,
        CredentialRefreshUnavailable,
        CredentialRefreshFailed,
    };

    /// The admission-relevant slice of the process launch inputs.
    const Request = struct {
        cli_api_key: ?[]const u8 = null,
        environment: ai.auth.Environment = .{},
        sources: SessionFormat.Sources,
    };

    /// Bounded catalog scan results feeding ModelBootstrapPolicy.plan.
    const Models = struct {
        available: [ModelBootstrapPolicy.max_available_models]ai.ModelIdentity = undefined,
        available_len: usize = 0,
        scoped: [ModelBootstrapPolicy.max_scoped_models]ai.ModelIdentity = undefined,
        scoped_len: usize = 0,

        fn availableItems(self: *const Models) []const ai.ModelIdentity {
            return self.available[0..self.available_len];
        }

        fn scopedItems(self: *const Models) []const ai.ModelIdentity {
            return self.scoped[0..self.scoped_len];
        }

        fn appendAvailable(self: *Models, identity: ai.ModelIdentity) bool {
            if (self.available_len == self.available.len) return false;
            self.available[self.available_len] = identity;
            self.available_len += 1;
            return true;
        }

        fn appendScoped(self: *Models, identity: ai.ModelIdentity) Error!void {
            for (self.scopedItems()) |existing| {
                if (sameIdentity(existing, identity)) return;
            }
            if (self.scoped_len == self.scoped.len) return error.InvalidModelConfiguration;
            self.scoped[self.scoped_len] = identity;
            self.scoped_len += 1;
        }
    };

    /// Probes catalog entries against resolvable auth so the planner only sees
    /// models this process could actually run.
    fn buildModels(
        model_config: ModelConfig,
        enabled_models: ?[]const []const u8,
        stored_credentials: []const ai.credential.Entry,
        environment: ai.auth.Environment,
    ) Error!Models {
        var result: Models = .{};
        for (model_config.catalog.entries) |entry| {
            _ = ai.Models.resolveAuth(
                model_config.catalog,
                model_config.providers,
                entry.identity,
                .{
                    .stored = stored_credentials,
                    .environment = environment,
                },
            ) catch continue;
            if (!result.appendAvailable(entry.identity)) break;
        }

        const patterns = enabled_models orelse return result;
        for (patterns) |pattern| {
            if (std.mem.findScalar(u8, pattern, '*') == null) {
                const slash = std.mem.findScalar(u8, pattern, '/') orelse continue;
                if (slash == 0 or slash + 1 == pattern.len) continue;
                const resolved = model_config.resolve(.{
                    .provider = pattern[0..slash],
                    .model = pattern[slash + 1 ..],
                }) orelse continue;
                if (containsIdentity(result.availableItems(), resolved.entry.identity)) {
                    try result.appendScoped(resolved.entry.identity);
                }
                continue;
            }

            // Zi admits '*' over canonical provider/model text. Other minimatch
            // syntax is literal until the catalog needs a wider matching contract.
            for (result.availableItems()) |identity| {
                if (wildcardMatchesIdentity(pattern, identity)) try result.appendScoped(identity);
            }
        }
        return result;
    }

    /// Attempts plan candidates in order until one admits. An explicit CLI
    /// selection is terminal; every other provenance falls through to the next
    /// candidate on unavailable credentials or resolution.
    fn admitPlan(
        allocator: std.mem.Allocator,
        io: std.Io,
        zi_paths: *const ZiPaths,
        transport: ai.transport.Transport,
        model_config: ModelConfig,
        plan: ModelBootstrapPolicy.Plan,
        request: Request,
    ) Error!ModelResolution.Resolved {
        var index: usize = 0;
        while (index < plan.items().len) {
            const candidate = plan.items()[index];
            const terminal = candidate.provenance == .explicit_cli;
            const admission = try admitCandidate(
                allocator,
                io,
                zi_paths,
                transport,
                model_config,
                candidate.identity,
                request,
                terminal,
            );
            switch (admission) {
                .admitted => |resolved| return resolved,
                .unavailable => {},
            }
            index = plan.nextAfterAdmissionFailure(index) orelse return error.SelectionRequired;
        }
        return error.SelectionRequired;
    }

    const CandidateAdmission = union(enum) {
        admitted: ModelResolution.Resolved,
        unavailable,
    };

    fn admitCandidate(
        allocator: std.mem.Allocator,
        io: std.Io,
        zi_paths: *const ZiPaths,
        transport: ai.transport.Transport,
        model_config: ModelConfig,
        identity: ai.ModelIdentity,
        request: Request,
        terminal: bool,
    ) Error!CandidateAdmission {
        var stored_credentials = CredentialManager.loadForRuntime(
            allocator,
            io,
            zi_paths,
            transport,
            .{
                .model_config = model_config,
                .selection = identity,
                .explicit_api_key = request.cli_api_key,
                .now_ms = request.sources.nowMsFn(request.sources.clock_context),
            },
        ) catch |failure| {
            if (!terminal and credentialFailureAllowsFallback(failure)) return .unavailable;
            return mapCredentialRuntimeFailure(failure);
        };
        defer stored_credentials.deinit();

        const resolved = ModelResolution.resolve(allocator, .{
            .model_config = model_config,
            .requested_provider = identity.provider,
            .requested_model = identity.model,
            .cli_api_key = request.cli_api_key,
            .stored_credentials = stored_credentials.entries,
            .environment = request.environment,
        }) catch |failure| {
            if (!terminal and resolutionFailureAllowsFallback(failure)) return .unavailable;
            return failure;
        };
        return .{ .admitted = resolved };
    }

    fn credentialFailureAllowsFallback(failure: CredentialManager.Error) bool {
        return switch (failure) {
            error.InvalidModelConfiguration,
            error.AuthenticationUnavailable,
            error.RefreshUnavailable,
            error.TimedOut,
            error.InvalidUrl,
            error.InvalidRequest,
            error.ConnectionFailed,
            error.InvalidResponse,
            error.ResponseTooLarge,
            error.ConsumerStopped,
            error.Rejected,
            => true,
            else => false,
        };
    }

    fn resolutionFailureAllowsFallback(failure: ModelResolution.Error) bool {
        return switch (failure) {
            error.SelectionRequired,
            error.IncompleteSelection,
            error.UnknownSelection,
            error.MissingCredential,
            error.InvalidCredential,
            error.DuplicateCredential,
            error.UnsupportedCliCredential,
            => true,
            else => false,
        };
    }

    fn mapCredentialRuntimeFailure(failure: CredentialManager.Error) Error {
        return switch (failure) {
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
            error.Cancelled => error.Cancelled,
            error.Rejected,
            error.InvalidResponse,
            error.TimedOut,
            error.InvalidUrl,
            error.InvalidRequest,
            error.ConnectionFailed,
            error.ResponseTooLarge,
            error.ConsumerStopped,
            => error.CredentialRefreshFailed,
        };
    }

    fn wildcardMatchesIdentity(pattern: []const u8, identity: ai.ModelIdentity) bool {
        const text_len = identity.provider.len + 1 + identity.model.len;
        var pattern_index: usize = 0;
        var text_index: usize = 0;
        var star_index: ?usize = null;
        var star_text_index: usize = 0;

        while (text_index < text_len) {
            if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                star_index = pattern_index;
                pattern_index += 1;
                star_text_index = text_index;
            } else if (pattern_index < pattern.len and
                pattern[pattern_index] == identityByte(identity, text_index))
            {
                pattern_index += 1;
                text_index += 1;
            } else if (star_index) |star| {
                pattern_index = star + 1;
                star_text_index += 1;
                text_index = star_text_index;
            } else {
                return false;
            }
        }
        while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
        return pattern_index == pattern.len;
    }

    fn identityByte(identity: ai.ModelIdentity, index: usize) u8 {
        if (index < identity.provider.len) return identity.provider[index];
        if (index == identity.provider.len) return '/';
        return identity.model[index - identity.provider.len - 1];
    }

    fn containsIdentity(identities: []const ai.ModelIdentity, wanted: ai.ModelIdentity) bool {
        for (identities) |identity| {
            if (sameIdentity(identity, wanted)) return true;
        }
        return false;
    }

    fn sameIdentity(left: ai.ModelIdentity, right: ai.ModelIdentity) bool {
        return std.mem.eql(u8, left.provider, right.provider) and
            std.mem.eql(u8, left.model, right.model);
    }

    test "enabled model scope admits exact aliases and star wildcards in settings order" {
        const stored = [_]ai.credential.Entry{
            .{
                .provider_id = "openai",
                .credential = .{ .api_key = .{ .key = "openai-key" } },
            },
            .{
                .provider_id = "openai-codex",
                .credential = .{ .oauth = .{
                    .access = "codex-access",
                    .refresh = "codex-refresh",
                    .expires_at_ms = 1,
                } },
            },
        };
        const patterns = [_][]const u8{
            "openai-codex/gpt-5.4*",
            "openai/gpt-5.6",
            "openai-codex/gpt-5.4",
            "openai-codex/gpt-5.?",
        };
        const models = try buildModels(
            ModelConfig.builtin,
            &patterns,
            &stored,
            .{},
        );

        try std.testing.expectEqual(@as(usize, 3), models.scopedItems().len);
        try std.testing.expectEqualStrings("gpt-5.4", models.scopedItems()[0].model);
        try std.testing.expectEqualStrings("gpt-5.4-mini", models.scopedItems()[1].model);
        try std.testing.expectEqualStrings("gpt-5.6-sol", models.scopedItems()[2].model);
    }
};

const RuntimeResources = struct {
    const ContextFiles = Prompt.ContextFiles;
    const PromptFiles = Prompt.PromptFiles;
    const SystemPrompt = Prompt.SystemPrompt;

    const Error = error{
        OutOfMemory,
        InvalidProjectIdentity,
        ProjectIdentityUnavailable,
        InvalidProjectTrustFile,
        UnsupportedVersion,
        UnsafeProjectTrustStorage,
        ProjectTrustReadFailed,
        ProjectTrustLockFailed,
        ProjectTrustWriteFailed,
        ProjectTrustCommitIndeterminate,
        Cancelled,
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
    };

    arena: std.heap.ArenaAllocator,
    prompt_files: ?PromptFiles = null,
    context_files: ?ContextFiles = null,
    project_trust: ProjectTrust.Decision,
    effective_policy: SystemPrompt.Policy,

    fn resolve(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        intent: ProjectTrust.Intent,
        requested_policy: SystemPrompt.Policy,
    ) Error!RuntimeResources {
        const requested_prompt_files = requestedPromptFiles(requested_policy);
        const project_trust = try resolveProjectTrust(
            allocator,
            io,
            paths,
            requested_prompt_files,
            intent,
        );
        var resources: RuntimeResources = .{
            .arena = .init(allocator),
            .project_trust = project_trust,
            .effective_policy = requested_policy,
        };
        errdefer resources.deinit();

        if (requested_prompt_files.system or requested_prompt_files.append) {
            resources.prompt_files = try PromptFiles.load(
                allocator,
                io,
                paths,
                requested_prompt_files,
                project_trust,
            );
        }
        resources.effective_policy = try resolvePromptPolicy(
            resources.arena.allocator(),
            requested_policy,
            if (resources.prompt_files) |*files| files else null,
        );

        if (requestsContextFiles(resources.effective_policy)) {
            resources.context_files = try ContextFiles.load(allocator, io, paths);
        }
        resources.effective_policy = try resolveContextPolicy(
            resources.arena.allocator(),
            resources.effective_policy,
            if (resources.context_files) |*files| files else null,
        );
        return resources;
    }

    fn policy(self: *const RuntimeResources) SystemPrompt.Policy {
        return self.effective_policy;
    }

    fn projectTrust(self: *const RuntimeResources) ProjectTrust.Decision {
        return self.project_trust;
    }

    fn deinit(self: *RuntimeResources) void {
        if (self.context_files) |*files| files.deinit();
        if (self.prompt_files) |*files| files.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    fn resolveProjectTrust(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        requested: PromptFiles.Requested,
        intent: ProjectTrust.Intent,
    ) Error!ProjectTrust.Decision {
        if (intent != .automatic) return ProjectTrust.resolve(intent, null);
        const has_prompt_source = try PromptFiles.hasProjectSources(io, paths, requested);
        const has_settings_source = try SettingsStore.hasProjectSource(io, paths);
        if (!has_prompt_source and !has_settings_source) {
            return ProjectTrust.resolve(.automatic, null);
        }
        var identity = try ProjectTrust.Identity.init(allocator, io, paths.cwd);
        defer identity.deinit();
        var snapshot = try ProjectTrust.load(allocator, io, paths);
        defer snapshot.deinit();
        const saved = if (snapshot.nearest(&identity)) |entry| entry.decision else null;
        return ProjectTrust.resolve(.automatic, saved);
    }

    fn requestedPromptFiles(policy_value: SystemPrompt.Policy) PromptFiles.Requested {
        return switch (policy_value) {
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
        allocator: std.mem.Allocator,
        policy_value: SystemPrompt.Policy,
        files: ?*const PromptFiles,
    ) Error!SystemPrompt.Policy {
        return switch (policy_value) {
            .verbatim => policy_value,
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
                        const discovered = try allocator.alloc([]const u8, 1);
                        discovered[0] = text;
                        break :rules discovered;
                    } else &.{}
                else
                    &.{},
            } },
        };
    }

    fn requestsContextFiles(policy_value: SystemPrompt.Policy) bool {
        return switch (policy_value) {
            .verbatim => false,
            .composed => |composition| composition.context_sections.len == 0,
        };
    }

    fn resolveContextPolicy(
        allocator: std.mem.Allocator,
        policy_value: SystemPrompt.Policy,
        files: ?*const ContextFiles,
    ) Error!SystemPrompt.Policy {
        return switch (policy_value) {
            .verbatim => policy_value,
            .composed => |composition| .{ .composed = .{
                .base = composition.base,
                .context_sections = if (composition.context_sections.len > 0)
                    composition.context_sections
                else if (files) |loaded| discovered: {
                    const sources = loaded.sections();
                    const sections = try allocator.alloc(SystemPrompt.ContextSection, sources.len);
                    for (sources, sections) |source, *section| {
                        section.* = .{ .path = source.path, .text = source.text };
                    }
                    break :discovered sections;
                } else &.{},
                .rules = composition.rules,
            } },
        };
    }

    fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
        const length = try temporary.dir.realPath(std.testing.io, buffer);
        return buffer[0..length];
    }

    const AllocationContext = struct {
        paths: *const ZiPaths,
    };

    fn resolveAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
        var resources = try resolve(
            allocator,
            std.testing.io,
            context.paths,
            .approve,
            .{ .composed = .{} },
        );
        resources.deinit();
    }

    test "runtime resources own discovered prompt and context policy" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "AGENTS.md",
            .data = "Project context.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();

        var resources = try resolve(
            std.testing.allocator,
            std.testing.io,
            &paths,
            .approve,
            .{ .composed = .{} },
        );
        defer resources.deinit();
        const composition = resources.policy().composed;
        try std.testing.expectEqualStrings("Project base.", composition.base.custom);
        try std.testing.expect(composition.context_sections.len >= 1);
        try std.testing.expectEqualStrings(
            "Project context.",
            composition.context_sections[composition.context_sections.len - 1].text,
        );
    }

    test "runtime resources settle every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "AGENTS.md",
            .data = "Project context.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        var context: AllocationContext = .{ .paths = &paths };

        try std.testing.checkAllAllocationFailures(std.testing.allocator, resolveAndDeinit, .{&context});
    }
};

pub const SessionRuntime = struct {
    const agent_api = agent_root;
    const ai_catalog = ai.model_catalog;
    const ai_model = ai.model;
    const ai_models = ai.models;
    const ai_protocol = ai.protocol_api;
    const ai_adapters = ai.adapters;
    const ai_settings = ai.settings;
    const ai_transport = ai.transport;
    const AgentSession = agent_session_mod.AgentSession;
    const ModelConfig = Model.Config;
    const ModelConfigSnapshot = Model.Snapshot;
    const SessionCommit = Session.Commit;
    const SessionJournal = Session.Journal;
    const model_resolution = Model.Resolution;
    const max_credentials = 32;

    pub const Credential = model_resolution.StoredCredential;
    pub const Config = model_resolution.RuntimeConfig;

    pub const Options = AgentSession.Options;

    pub const CreateError = error{
        OutOfMemory,
        InvalidModelConfiguration,
        InvalidSystemPrompt,
        SystemPromptTooLarge,
        DuplicateToolName,
        InvalidToolDefinition,
        UnknownTool,
        InvalidToolArguments,
    };

    pub const DurableCreateError = error{
        OutOfMemory,
        InvalidModelConfiguration,
        InvalidSystemPrompt,
        SystemPromptTooLarge,
        DuplicateToolName,
        InvalidToolDefinition,
        UnknownTool,
        InvalidToolArguments,
        PersistenceFailed,
        CommitIndeterminate,
        SessionTooLarge,
    };

    const TransportOwner = union(enum) {
        http: ai_transport.HttpTransport,
        borrowed: ai_transport.Transport,

        fn view(self: *TransportOwner) ai_transport.Transport {
            return switch (self.*) {
                .http => |*http| http.transport(),
                .borrowed => |transport| transport,
            };
        }
    };

    allocator: std.mem.Allocator,
    transport: TransportOwner,
    model_runtime: ai_models,
    session_value: AgentSession,

    /// Takes ownership of `cwd`: initialize (via AgentSession.init) closes it on
    /// failure and transfers it into the session on success. Failures before
    /// the initialize call close it here.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: std.Io.Dir,
        config: Config,
        options: Options,
    ) CreateError!*SessionRuntime {
        var cwd_consumed = false;
        defer if (!cwd_consumed) cwd.close(io);
        const runtime = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(runtime);
        runtime.allocator = allocator;
        runtime.transport = .{ .http = ai_transport.HttpTransport.init(allocator) };
        cwd_consumed = true;
        try runtime.initialize(io, cwd, config, options);
        return runtime;
    }

    pub fn createDurable(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: std.Io.Dir,
        config: Config,
        options: Options,
        opened: *SessionJournal.Opened,
        sources: SessionFormat.Sources,
    ) DurableCreateError!*SessionRuntime {
        var owned = opened.*;
        opened.* = undefined;
        var owned_live = true;
        errdefer if (owned_live) owned.deinit();
        var cwd_consumed = false;
        defer if (!cwd_consumed) cwd.close(io);
        const runtime = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(runtime);
        runtime.allocator = allocator;
        runtime.transport = .{ .http = ai_transport.HttpTransport.init(allocator) };
        cwd_consumed = true;
        const initialize_result = runtime.initializeDurable(
            io,
            cwd,
            config,
            options,
            &owned,
            sources,
            .none(),
        );
        owned_live = false;
        try initialize_result;
        return runtime;
    }

    pub fn session(self: *SessionRuntime) *AgentSession {
        return &self.session_value;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *SessionRuntime) void {
        const allocator = self.allocator;
        self.session_value.deinit();
        self.model_runtime.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    fn createWithTransport(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: std.Io.Dir,
        transport: ai_transport.Transport,
        config: Config,
        options: Options,
    ) CreateError!*SessionRuntime {
        var cwd_consumed = false;
        defer if (!cwd_consumed) cwd.close(io);
        const runtime = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(runtime);
        runtime.allocator = allocator;
        runtime.transport = .{ .borrowed = transport };
        cwd_consumed = true;
        try runtime.initialize(io, cwd, config, options);
        return runtime;
    }

    pub fn createDurableWithTransport(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: std.Io.Dir,
        transport: ai_transport.Transport,
        config: Config,
        options: Options,
        opened: *SessionJournal.Opened,
        sources: SessionFormat.Sources,
        faults: SessionJournal.Faults,
    ) DurableCreateError!*SessionRuntime {
        var owned = opened.*;
        opened.* = undefined;
        var owned_live = true;
        errdefer if (owned_live) owned.deinit();
        var cwd_consumed = false;
        defer if (!cwd_consumed) cwd.close(io);
        const runtime = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(runtime);
        runtime.allocator = allocator;
        runtime.transport = .{ .borrowed = transport };
        cwd_consumed = true;
        const initialize_result = runtime.initializeDurable(io, cwd, config, options, &owned, sources, faults);
        owned_live = false;
        try initialize_result;
        return runtime;
    }

    fn initialize(
        self: *SessionRuntime,
        io: std.Io,
        cwd: std.Io.Dir,
        config: Config,
        options: Options,
    ) CreateError!void {
        var cwd_owned = true;
        defer if (cwd_owned) cwd.close(io);

        self.model_runtime = ai_models.init(
            self.allocator,
            self.transport.view(),
            ai_protocol.Registry.init(&ai_adapters.builtin) catch return error.InvalidModelConfiguration,
            .{
                .catalog = config.model_config.catalog,
                .providers = config.model_config.providers,
                .credentials = config.credentials,
                .auth_resolver = config.auth_resolver,
                .selection = config.selection,
            },
        ) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidConfiguration => error.InvalidModelConfiguration,
        };
        errdefer self.model_runtime.deinit();
        // AgentSession.init consumes `cwd` on success and closes it on any
        // failure; transfer ownership immediately before the call.
        cwd_owned = false;
        self.session_value = try AgentSession.init(
            self.allocator,
            io,
            self.model_runtime.model(),
            cwd,
            options,
        );
    }

    fn initializeDurable(
        self: *SessionRuntime,
        io: std.Io,
        cwd: std.Io.Dir,
        config: Config,
        options: Options,
        opened: *SessionJournal.Opened,
        sources: SessionFormat.Sources,
        faults: SessionJournal.Faults,
    ) DurableCreateError!void {
        var opened_owned = true;
        errdefer if (opened_owned) opened.deinit();
        try self.initialize(io, cwd, config, options);
        errdefer {
            self.session_value.deinit();
            self.model_runtime.deinit();
        }

        const commit_result = SessionCommit.create(
            self.allocator,
            opened,
            sources,
            self.model_runtime.model().identity,
            faults,
        );
        opened_owned = false;
        const commit_owner = commit_result catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionTooLarge => error.SessionTooLarge,
            error.PersistenceFailed => error.PersistenceFailed,
            error.CommitIndeterminate => error.CommitIndeterminate,
        };
        errdefer commit_owner.deinit();
        try self.session_value.bindCommit(commit_owner);
    }

    const fake_api = ai.transport_testing;

    const test_compatible_profile = profile: {
        var value: ai_settings.ModelProfile = .{};
        value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
        value.settings = .initMany(&.{ .temperature, .top_p, .max_output_tokens, .stop_sequences, .seed });
        break :profile value;
    };
    const test_responses_profile = profile: {
        var value: ai_settings.ModelProfile = .{};
        value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
        value.settings = .initMany(&.{ .max_output_tokens, .reasoning_effort });
        value.reasoning_efforts = .initMany(&.{ .low, .medium, .high });
        break :profile value;
    };
    const test_codex_profile = profile: {
        var value: ai_settings.ModelProfile = .{};
        value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
        value.settings = .initMany(&.{.reasoning_effort});
        value.reasoning_efforts = .initMany(&.{ .minimal, .low, .medium, .high });
        break :profile value;
    };
    const test_catalog_entries = [_]ai_catalog.Entry{
        .{
            .identity = .{ .provider = "runtime-openai", .model = "runtime-model" },
            .protocol_id = "openai-completions",
            .aliases = &.{"runtime-latest"},
            .profile = test_compatible_profile,
        },
        .{
            .identity = .{ .provider = "openai", .model = "responses-runtime" },
            .protocol_id = "openai-responses",
            .aliases = &.{"responses-latest"},
            .profile = test_responses_profile,
        },
        .{
            .identity = .{ .provider = "openai-codex", .model = "codex-runtime" },
            .protocol_id = "openai-codex-responses",
            .profile = test_codex_profile,
        },
    };
    const test_catalog: ai_catalog.Catalog = .{ .entries = &test_catalog_entries };
    const test_provider_definitions = [_]ModelConfig.ProviderDefinition{
        .{
            .id = "runtime-openai",
            .name = "Runtime OpenAI",
            .base_url = "https://example.test/v1",
            .auth = .{ .api_key = .{} },
        },
        .{
            .id = "openai",
            .name = "OpenAI",
            .base_url = "https://api.openai.com/v1",
            .auth = .{ .api_key = .{} },
        },
        .{
            .id = "openai-codex",
            .name = "OpenAI Codex",
            .base_url = "https://chatgpt.com/backend-api",
            .auth = .{ .oauth = .{} },
        },
    };
    const test_model_config: ModelConfig = .{
        .catalog = test_catalog,
        .providers = &test_provider_definitions,
    };

    fn apiKeyCredential(provider_id: []const u8, key: []const u8) Credential {
        return .{ .provider_id = provider_id, .credential = .{ .api_key = .{ .key = key } } };
    }

    fn oauthCredential(provider_id: []const u8, access: []const u8, account_id: ?[]const u8) Credential {
        return .{
            .provider_id = provider_id,
            .credential = .{ .oauth = .{
                .access = access,
                .refresh = "refresh",
                .expires_at_ms = 1,
                .account_id = account_id,
            } },
        };
    }

    const CustomResponsesInspector = struct {
        calls: usize = 0,

        fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
            const self: *CustomResponsesInspector = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, request.url, "https://example.test/openai/v1/responses")) {
                return error.Rejected;
            }
            if (std.mem.indexOf(u8, request.body, "\"model\":\"custom-reasoning-model\"") == null) {
                return error.Rejected;
            }
            if (!hasHeader(request, "authorization", "Bearer runtime-secret")) return error.Rejected;
            switch (self.calls) {
                0 => {
                    if (std.mem.indexOf(u8, request.body, "read note.txt") == null) {
                        return error.Rejected;
                    }
                    if (std.mem.indexOf(u8, request.body, "\"name\":\"read\"") == null) return error.Rejected;
                },
                1 => {
                    if (std.mem.indexOf(u8, request.body, "\"type\":\"function_call_output\"") == null) {
                        return error.Rejected;
                    }
                    if (std.mem.indexOf(u8, request.body, "runtime evidence") == null) return error.Rejected;
                },
                else => return error.Rejected,
            }
            self.calls += 1;
        }
    };

    const ResponsesInspector = struct {
        saw_request: bool = false,

        fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
            const self: *ResponsesInspector = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, request.url, "https://api.openai.com/v1/responses")) return error.Rejected;
            if (!hasHeader(request, "authorization", "Bearer responses-secret")) return error.Rejected;
            if (std.mem.indexOf(u8, request.body, "\"model\":\"responses-runtime\"") == null) {
                return error.Rejected;
            }
            self.saw_request = true;
        }
    };

    const CodexInspector = struct {
        saw_request: bool = false,

        fn inspect(context: *anyopaque, request: ai_transport.Request) error{Rejected}!void {
            const self: *CodexInspector = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, request.url, "https://chatgpt.com/backend-api/codex/responses")) {
                return error.Rejected;
            }
            if (!hasHeader(request, "authorization", "Bearer codex-secret")) return error.Rejected;
            if (!hasHeader(request, "chatgpt-account-id", "account-runtime")) return error.Rejected;
            if (std.mem.indexOf(u8, request.body, "\"model\":\"codex-runtime\"") == null) return error.Rejected;
            if (std.mem.indexOf(u8, request.body, "hello codex") == null) return error.Rejected;
            self.saw_request = true;
        }
    };

    fn hasHeader(request: ai_transport.Request, name: []const u8, value: []const u8) bool {
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return true;
        }
        return false;
    }

    const DurableSources = struct {
        next_id: u64 = 0,
        next_ms: u64 = 1_777_800_000_000,

        fn nextId(context: *anyopaque) [16]u8 {
            const self: *DurableSources = @ptrCast(@alignCast(context));
            self.next_id += 1;
            var bytes: [16]u8 = @splat(0);
            std.mem.writeInt(u64, bytes[8..16], self.next_id, .big);
            return bytes;
        }

        fn nowMs(context: *anyopaque) u64 {
            const self: *DurableSources = @ptrCast(@alignCast(context));
            defer self.next_ms += 1;
            return self.next_ms;
        }

        fn view(self: *DurableSources) SessionFormat.Sources {
            return .{
                .id_context = self,
                .nextIdFn = nextId,
                .clock_context = self,
                .nowMsFn = nowMs,
            };
        }
    };

    const AppendFault = struct {
        fail_on_record: usize,
        records_seen: usize = 0,
        failed: bool = false,

        fn boundary(context: *anyopaque, point: SessionJournal.Boundary) anyerror!void {
            const self: *AppendFault = @ptrCast(@alignCast(context));
            if (point != .after_append_record_write) return;
            self.records_seen += 1;
            if (!self.failed and self.records_seen == self.fail_on_record) {
                self.failed = true;
                return error.InjectedFault;
            }
        }

        fn faults(self: *AppendFault) SessionJournal.Faults {
            return .{ .context = self, .boundaryFn = boundary };
        }
    };

    const DurableEventRecorder = struct {
        model_completions: usize = 0,
        tool_completions: usize = 0,

        fn emit(context: *anyopaque, event: agent_session_mod.Event) agent_api.event.SinkError!void {
            const self: *DurableEventRecorder = @ptrCast(@alignCast(context));
            switch (event) {
                .message_end => |ended| switch (ended.message) {
                    .published => |message| if (message == .response) {
                        self.model_completions += 1;
                    },
                    .discarded_response => {},
                },
                .tool_execution_end => |ended| switch (ended.result) {
                    .published => self.tool_completions += 1,
                    .discarded => {},
                },
                else => {},
            }
        }
    };

    fn createTestJournal(
        dir: std.Io.Dir,
        cwd: []const u8,
    ) !SessionJournal.Opened {
        return SessionJournal.create(
            std.testing.allocator,
            std.testing.io,
            dir,
            "session.jsonl",
            .{
                .id = "session-runtime",
                .timestamp = "2026-08-19T10:30:00.000Z",
                .cwd = cwd,
            },
            .none(),
        );
    }

    test "runtime owns catalog and provider configuration through a cwd-bound tool loop" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "runtime evidence" });
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/models.json",
            .data =
            \\{
            \\  "providers": {
            \\    "custom-openai": {
            \\      "baseUrl": "https://example.test/openai/v1",
            \\      "protocol": "openai-responses",
            \\      "models": [{
            \\        "id": "custom-reasoning-model",
            \\        "reasoning": true,
            \\        "input": ["text", "image"],
            \\        "contextWindow": 272000,
            \\        "maxTokens": 128000
            \\      }]
            \\    }
            \\  }
            \\}
            ,
        });

        const tool_response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read"}}
            \\
            \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":"}
            \\
            \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"\"note.txt\"}"}
            \\
            // ziglint-ignore: Z024
            \\data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"note.txt\"}"}
            \\
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"note.txt\"}"}}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const final_response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
            \\
            \\data: {"type":"response.output_text.delta","output_index":0,"delta":"runtime complete"}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const exchanges = [_]fake_api.Exchange{
            .{ .response = .{ .status = 200, .body = tool_response, .chunk_bytes = 13 } },
            .{ .response = .{ .status = 200, .body = final_response, .chunk_bytes = 11 } },
        };
        var fake = fake_api.FakeTransport.init(&exchanges);
        var inspector: CustomResponsesInspector = .{};
        fake.inspector = .{ .context = &inspector, .inspect_fn = CustomResponsesInspector.inspect };

        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
        var paths = try ZiPaths.init(
            std.testing.allocator,
            path_buffer[0..path_length],
            path_buffer[0..path_length],
        );
        errdefer paths.deinit();
        var snapshot = try ModelConfigSnapshot.load(std.testing.allocator, std.testing.io, &paths);
        errdefer snapshot.deinit();
        try std.testing.expect(snapshot.diagnostic() == null);
        var resolved = try model_resolution.resolve(std.testing.allocator, .{
            .model_config = snapshot.view(),
            .requested_provider = "custom-openai",
            .requested_model = "custom-reasoning-model",
            .cli_api_key = "runtime-secret",
        });
        errdefer resolved.deinit();

        var runtime = try createWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            resolved.runtimeConfig(),
            .{},
        );
        defer runtime.deinit();
        resolved.deinit();
        snapshot.deinit();
        paths.deinit();

        const result = try runtime.session().prompt("read note.txt");
        try std.testing.expectEqualStrings("runtime complete", result);
        try std.testing.expect(runtime.session().state() == .ready);
        try std.testing.expectEqual(@as(usize, 2), fake.next_index);
        try std.testing.expectEqual(@as(usize, 2), inspector.calls);
        const history = runtime.session().messages();
        try std.testing.expectEqualStrings("custom-openai", history[3].response.identity.provider);
        try std.testing.expectEqualStrings("custom-reasoning-model", history[3].response.identity.model);
    }

    test "durable runtime commits a FakeTransport tool loop before publishing history" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "durable evidence" });
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
        const cwd = path_buffer[0..path_length];
        var opened = try createTestJournal(temporary.dir, cwd);

        const tool_response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read"}}
            \\
            // ziglint-ignore: Z024
            \\data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"note.txt\"}"}
            \\
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"note.txt\"}"}}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const final_response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
            \\
            \\data: {"type":"response.output_text.delta","output_index":0,"delta":"durably complete"}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const exchanges = [_]fake_api.Exchange{
            .{ .response = .{ .status = 200, .body = tool_response, .chunk_bytes = 13 } },
            .{ .response = .{ .status = 200, .body = final_response, .chunk_bytes = 11 } },
        };
        var fake = fake_api.FakeTransport.init(&exchanges);
        var sources: DurableSources = .{};
        const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
        var runtime = try createDurableWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "responses-runtime" },
            },
            .{},
            &opened,
            sources.view(),
            .none(),
        );
        errdefer runtime.deinit();

        try std.testing.expectEqualStrings("durably complete", try runtime.session().prompt("read note.txt"));
        try std.testing.expectEqual(@as(usize, 4), runtime.session().messages().len);
        runtime.deinit();

        var restored = try SessionJournal.openReadOnly(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
        );
        defer restored.deinit();
        const entries = restored.restore_candidate.entries;
        try std.testing.expectEqual(@as(usize, 6), entries.len);
        try std.testing.expect(entries[0] == .model_change);
        try std.testing.expect(entries[1] == .message);
        try std.testing.expect(entries[2] == .message);
        try std.testing.expect(entries[3] == .message);
        try std.testing.expect(entries[4] == .message);
        try std.testing.expect(entries[5].turn_end.outcome == .completed);
        try std.testing.expectEqual(@as(usize, 4), restored.restore_candidate.context_messages.len);
        try std.testing.expectEqualStrings(
            "durable evidence",
            restored.restore_candidate.context_messages[2].request.parts[0].tool_result.content[0].text,
        );
        try std.testing.expect(restored.restore_candidate.recovery == .clean);
    }

    test "durable runtime publishes neither a message nor completion event before journal commit" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
        var opened = try createTestJournal(temporary.dir, path_buffer[0..path_length]);
        const response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
            \\
            \\data: {"type":"response.output_text.delta","output_index":0,"delta":"must not publish"}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const exchanges = [_]fake_api.Exchange{.{ .response = .{
            .status = 200,
            .body = response,
            .chunk_bytes = 9,
        } }};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var sources: DurableSources = .{};
        var fault: AppendFault = .{ .fail_on_record = 3 };
        var events: DurableEventRecorder = .{};
        const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
        var runtime = try createDurableWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "responses-runtime" },
            },
            .{ .events = .{ .context = &events, .emitFn = DurableEventRecorder.emit } },
            &opened,
            sources.view(),
            fault.faults(),
        );
        errdefer runtime.deinit();

        try std.testing.expectError(error.PersistenceFailed, runtime.session().prompt("hello"));
        try std.testing.expectEqual(@as(usize, 1), runtime.session().messages().len);
        try std.testing.expectEqual(@as(usize, 0), events.model_completions);
        try std.testing.expect(runtime.session().state() == .ready);
        runtime.deinit();

        var restored = try SessionJournal.openReadOnly(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
        );
        defer restored.deinit();
        const entries = restored.restore_candidate.entries;
        try std.testing.expectEqual(@as(usize, 3), entries.len);
        try std.testing.expect(entries[0] == .model_change);
        try std.testing.expect(entries[1].message.message == .request);
        try std.testing.expectEqual(
            SessionFormat.FailureCategory.persistence_failed,
            entries[2].turn_end.outcome.failed,
        );
        try std.testing.expectEqual(@as(usize, 1), restored.restore_candidate.context_messages.len);
    }

    test "durable runtime withholds a tool result and completion event when its commit fails" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
        var opened = try createTestJournal(temporary.dir, path_buffer[0..path_length]);
        const response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"write"}}
            \\
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"created.txt\",\"content\":\"tool effect\"}"}
            \\
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"write","arguments":"{\"path\":\"created.txt\",\"content\":\"tool effect\"}"}}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const exchanges = [_]fake_api.Exchange{.{ .response = .{
            .status = 200,
            .body = response,
            .chunk_bytes = 11,
        } }};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var sources: DurableSources = .{};
        var fault: AppendFault = .{ .fail_on_record = 4 };
        var events: DurableEventRecorder = .{};
        const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
        var runtime = try createDurableWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "responses-runtime" },
            },
            .{ .events = .{ .context = &events, .emitFn = DurableEventRecorder.emit } },
            &opened,
            sources.view(),
            fault.faults(),
        );
        errdefer runtime.deinit();

        try std.testing.expectError(error.PersistenceFailed, runtime.session().prompt("write the file"));
        try std.testing.expectEqual(@as(usize, 1), runtime.session().messages().len);
        try std.testing.expectEqual(@as(usize, 1), events.model_completions);
        try std.testing.expectEqual(@as(usize, 0), events.tool_completions);
        const created = try temporary.dir.readFileAlloc(
            std.testing.io,
            "created.txt",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(created);
        try std.testing.expectEqualStrings("tool effect", created);
        runtime.deinit();

        var restored = try SessionJournal.openReadOnly(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
        );
        defer restored.deinit();
        const entries = restored.restore_candidate.entries;
        try std.testing.expectEqual(@as(usize, 4), entries.len);
        try std.testing.expect(entries[2].message.message == .response);
        try std.testing.expectEqual(
            SessionFormat.FailureCategory.persistence_failed,
            entries[3].turn_end.outcome.failed,
        );
        try std.testing.expectEqual(@as(usize, 1), restored.restore_candidate.context_messages.len);
    }

    test "durable runtime closes a restored open turn before admitting cancellation" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
        var opened = try createTestJournal(temporary.dir, path_buffer[0..path_length]);
        try opened.journal.append(.{ .model_change = .{
            .base = .{
                .id = "model-entry",
                .parent_id = null,
                .timestamp = "2026-08-19T10:30:01.000Z",
            },
            .selection = .{ .provider = "openai", .model = "responses-runtime" },
        } }, .none());
        try opened.journal.append(.{ .message = .{
            .base = .{
                .id = "open-turn",
                .parent_id = "model-entry",
                .timestamp = "2026-08-19T10:30:02.000Z",
            },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "before crash" } }} } },
        } }, .none());
        opened.deinit();
        opened = try SessionJournal.openWritable(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
        );

        const exchanges: [0]fake_api.Exchange = .{};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var sources: DurableSources = .{};
        const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
        var runtime = try createDurableWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "responses-runtime" },
            },
            .{},
            &opened,
            sources.view(),
            .none(),
        );
        errdefer runtime.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime.session().messages().len);
        try std.testing.expectEqualStrings(
            "before crash",
            runtime.session().messages()[0].request.parts[0].user.text,
        );

        var cancellation: ai_model.CancellationToken = .{};
        cancellation.cancel();
        try std.testing.expectError(
            error.Cancelled,
            runtime.session().promptWithControl("cancel this", .{ .cancellation = &cancellation }),
        );
        try std.testing.expect(runtime.session().state() == .ready);
        try std.testing.expectEqual(@as(usize, 0), fake.next_index);
        runtime.deinit();

        var restored = try SessionJournal.openReadOnly(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
        );
        defer restored.deinit();
        const entries = restored.restore_candidate.entries;
        try std.testing.expectEqual(@as(usize, 5), entries.len);
        try std.testing.expect(entries[2].turn_end.outcome == .interrupted);
        try std.testing.expect(entries[3].message.message == .request);
        try std.testing.expect(entries[4].turn_end.outcome == .cancelled);
        try std.testing.expect(restored.restore_candidate.recovery == .clean);
    }

    test "OpenAI Responses runtime crosses the provider and protocol seams" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
            \\
            \\data: {"type":"response.output_text.delta","output_index":0,"delta":"responses complete"}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response, .chunk_bytes = 9 } }};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var inspector: ResponsesInspector = .{};
        fake.inspector = .{ .context = &inspector, .inspect_fn = ResponsesInspector.inspect };
        var resolved = try model_resolution.resolve(std.testing.allocator, .{
            .model_config = test_model_config,
            .requested_provider = "openai",
            .requested_model = "responses-latest",
            .cli_api_key = "responses-secret",
        });
        defer resolved.deinit();

        var runtime = try createWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            resolved.runtimeConfig(),
            .{},
        );
        defer runtime.deinit();

        try std.testing.expectEqualStrings("responses complete", try runtime.session().prompt("hello responses"));
        try std.testing.expect(inspector.saw_request);
    }

    test "OpenAI Codex runtime crosses the provider and Responses SSE seams" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const response =
            // ziglint-ignore: Z024 -- compact provider wire fixture
            \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
            \\
            \\data: {"type":"response.output_text.delta","output_index":0,"delta":"codex complete"}
            \\
            \\data: {"type":"response.completed","response":{"status":"completed"}}
            \\
        ;
        // ziglint-ignore: Z024
        const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response, .chunk_bytes = 11 } }};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var inspector: CodexInspector = .{};
        fake.inspector = .{ .context = &inspector, .inspect_fn = CodexInspector.inspect };
        const credentials = [_]Credential{oauthCredential("openai-codex", "codex-secret", "account-runtime")};

        var runtime = try createWithTransport(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai-codex", .model = "codex-runtime" },
            },
            .{},
        );
        defer runtime.deinit();

        try std.testing.expectEqualStrings("codex complete", try runtime.session().prompt("hello codex"));
        try std.testing.expect(inspector.saw_request);
    }

    test "runtime rejects invalid credentials and unavailable selections before transport admission" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const exchanges: [0]fake_api.Exchange = .{};
        var fake = fake_api.FakeTransport.init(&exchanges);
        const no_credentials: [0]Credential = .{};
        const empty_provider_id = [_]Credential{apiKeyCredential("", "key")};
        const empty_api_key = [_]Credential{apiKeyCredential("openai", "")};
        const unknown_provider = [_]Credential{apiKeyCredential("missing", "key")};
        const empty_access_token = [_]Credential{oauthCredential("openai-codex", "", null)};
        const empty_account_id = [_]Credential{oauthCredential("openai-codex", "token", "")};
        const duplicate_credentials = [_]Credential{
            apiKeyCredential("openai", "one"),
            apiKeyCredential("openai", "two"),
        };
        const openai_credential = [_]Credential{apiKeyCredential("openai", "key")};
        const no_auth_definitions = [_]ModelConfig.ProviderDefinition{.{
            .id = "runtime-openai",
            .name = "Runtime OpenAI",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        }};
        const no_auth_config: ModelConfig = .{
            .catalog = test_catalog,
            .providers = &no_auth_definitions,
        };
        const unexpected_api_key = [_]Credential{apiKeyCredential("runtime-openai", "key")};
        const openai_only_definitions = [_]ModelConfig.ProviderDefinition{test_provider_definitions[1]};
        const openai_only_config: ModelConfig = .{
            .catalog = test_catalog,
            .providers = &openai_only_definitions,
        };
        const unexpected_codex = [_]Credential{oauthCredential("openai-codex", "token", null)};
        const cases = [_]Config{
            .{ .model_config = test_model_config, .credentials = &empty_provider_id, .selection = .{
                .provider = "openai",
                .model = "responses-runtime",
            } },
            .{ .model_config = test_model_config, .credentials = &empty_api_key, .selection = .{
                .provider = "openai",
                .model = "responses-runtime",
            } },
            .{ .model_config = test_model_config, .credentials = &unknown_provider, .selection = .{
                .provider = "openai",
                .model = "responses-runtime",
            } },
            .{ .model_config = no_auth_config, .credentials = &unexpected_api_key, .selection = .{
                .provider = "runtime-openai",
                .model = "runtime-model",
            } },
            .{ .model_config = test_model_config, .credentials = &empty_access_token, .selection = .{
                .provider = "openai-codex",
                .model = "codex-runtime",
            } },
            .{ .model_config = test_model_config, .credentials = &empty_account_id, .selection = .{
                .provider = "openai-codex",
                .model = "codex-runtime",
            } },
            .{ .model_config = test_model_config, .credentials = &duplicate_credentials, .selection = .{
                .provider = "openai",
                .model = "responses-runtime",
            } },
            .{ .model_config = test_model_config, .credentials = &no_credentials, .selection = .{
                .provider = "openai",
                .model = "responses-runtime",
            } },
            .{ .model_config = openai_only_config, .credentials = &unexpected_codex, .selection = .{
                .provider = "openai",
                .model = "responses-runtime",
            } },
            .{ .model_config = test_model_config, .credentials = &openai_credential, .selection = .{
                .provider = "openai",
                .model = "missing",
            } },
        };
        for (cases) |config| {
            const cwd = try testSessionCwd(temporary.dir);
            try std.testing.expectError(error.InvalidModelConfiguration, createWithTransport(
                std.testing.allocator,
                std.testing.io,
                cwd,
                fake.transport(),
                config,
                .{},
            ));
        }
        try std.testing.expectEqual(@as(usize, 0), fake.next_index);
    }

    fn createAndDisposeForAllocationFailure(allocator: std.mem.Allocator, cwd_dir: std.Io.Dir) !void {
        const cwd = try testSessionCwd(cwd_dir);
        const exchanges: [0]fake_api.Exchange = .{};
        var fake = fake_api.FakeTransport.init(&exchanges);
        const credentials = [_]Credential{
            apiKeyCredential("runtime-openai", "runtime-secret"),
            apiKeyCredential("openai", "responses-secret"),
            oauthCredential("openai-codex", "codex-secret", "account-runtime"),
        };
        var runtime = try createWithTransport(
            allocator,
            std.testing.io,
            cwd,
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "runtime-openai", .model = "runtime-model" },
            },
            .{},
        );
        runtime.deinit();
    }

    test "runtime construction settles every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            createAndDisposeForAllocationFailure,
            .{temporary.dir},
        );
    }

    test "runtime closes the admitted cwd when model construction fails before the session" {
        if (builtin.os.tag == .windows) return; // /dev/fd probe is unix-only
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const before = openFdCount(std.testing.io);
        const no_auth_definitions = [_]ModelConfig.ProviderDefinition{.{
            .id = "runtime-openai",
            .name = "Runtime OpenAI",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        }};
        const failing_config: ModelConfig = .{
            .catalog = test_catalog,
            .providers = &no_auth_definitions,
        };
        const unexpected_api_key = [_]Credential{apiKeyCredential("runtime-openai", "key")};
        for (0..20) |_| {
            const cwd = try temporary.dir.openDir(std.testing.io, ".", .{});
            try std.testing.expectError(
                error.InvalidModelConfiguration,
                create(
                    std.testing.allocator,
                    std.testing.io,
                    cwd,
                    .{
                        .model_config = failing_config,
                        .credentials = &unexpected_api_key,
                        .selection = .{ .provider = "runtime-openai", .model = "runtime-model" },
                    },
                    .{},
                ),
            );
        }
        // Every failing create must close its dedicated cwd exactly once: a
        // leak grows the open-fd count and a double close aborts the suite.
        const after = openFdCount(std.testing.io);
        try std.testing.expect(after <= before);
    }

    fn openFdCount(io: std.Io) usize {
        var dir = std.Io.Dir.openDir(.cwd(), io, "/dev/fd", .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var count: usize = 0;
        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next(io) catch return count;
            if (entry == null) return count;
            count += 1;
        }
    }

    fn deleteAllocationJournal(dir: std.Io.Dir) !void {
        dir.deleteFile(std.testing.io, "allocation-session.jsonl") catch |failure| switch (failure) {
            error.FileNotFound => {},
            else => return failure,
        };
    }

    fn createDurableForAllocationFailure(
        allocator: std.mem.Allocator,
        cwd_dir: std.Io.Dir,
        cwd: []const u8,
    ) !void {
        try deleteAllocationJournal(cwd_dir);
        defer deleteAllocationJournal(cwd_dir) catch unreachable;
        var opened = try SessionJournal.create(
            allocator,
            std.testing.io,
            cwd_dir,
            "allocation-session.jsonl",
            .{
                .id = "allocation-session",
                .timestamp = "2026-08-19T10:30:00.000Z",
                .cwd = cwd,
            },
            .none(),
        );
        var sources: DurableSources = .{};
        const exchanges: [0]fake_api.Exchange = .{};
        var fake = fake_api.FakeTransport.init(&exchanges);
        const session_cwd = try testSessionCwd(cwd_dir);
        const credentials = [_]Credential{apiKeyCredential("openai", "responses-secret")};
        var runtime = try createDurableWithTransport(
            allocator,
            std.testing.io,
            session_cwd,
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "responses-runtime" },
            },
            .{},
            &opened,
            sources.view(),
            .none(),
        );
        runtime.deinit();
    }

    test "durable runtime binding settles every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            createDurableForAllocationFailure,
            .{ temporary.dir, path_buffer[0..path_length] },
        );
    }

    test "runtime wipes every copied credential and Codex account ID" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const backing = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(backing);
        @memset(backing, 0xa5);
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const exchanges: [0]fake_api.Exchange = .{};
        var fake = fake_api.FakeTransport.init(&exchanges);
        const credentials = [_]Credential{
            apiKeyCredential("openai", "wipe-openai-secret"),
            oauthCredential("openai-codex", "wipe-codex-secret", "wipe-account-runtime"),
        };

        var runtime = try createWithTransport(
            fixed.allocator(),
            std.testing.io,
            try testSessionCwd(temporary.dir),
            fake.transport(),
            .{
                .model_config = test_model_config,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "responses-runtime" },
            },
            .{},
        );
        const sensitive = runtime.model_runtime.sensitive[0..runtime.model_runtime.sensitive_count];
        try std.testing.expectEqual(@as(usize, 4), sensitive.len);
        var offsets: [4]usize = undefined;
        var lengths: [4]usize = undefined;
        for (sensitive, 0..) |value, index| {
            offsets[index] = @intFromPtr(value.ptr) - @intFromPtr(backing.ptr);
            lengths[index] = value.len;
        }
        runtime.deinit();
        for (offsets, lengths) |offset, length| {
            for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }

    test "production runtime uses built-in model configuration without model IO" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const credentials = [_]Credential{apiKeyCredential("openai", "runtime-secret")};
        var runtime = try create(
            std.testing.allocator,
            std.testing.io,
            try testSessionCwd(temporary.dir),
            .{
                .model_config = ModelConfig.builtin,
                .credentials = &credentials,
                .selection = .{ .provider = "openai", .model = "gpt-5.6" },
            },
            .{},
        );
        runtime.deinit();
    }
};

pub const Services = struct {
    const AgentSession = agent_session_mod.AgentSession;
    const AgentSessionRuntime = SessionRuntime;
    const CredentialManager = Credentials.Manager;
    // ModelAdmission is file-private above Services.
    const CredentialStore = Credentials.Store;
    const ModelBootstrapPolicy = Model.BootstrapPolicy;
    const ModelConfigSnapshot = Model.Snapshot;
    const ModelResolution = Model.Resolution;
    // RuntimeResources is file-private above Services.
    const SessionJournal = Session.Journal;
    const SessionSelection = Session.Selection;
    const SessionTranscript = Session.Transcript;
    pub const Error = error{
        OutOfMemory,
        InvalidPath,
        InvalidProjectIdentity,
        ProjectIdentityUnavailable,
        InvalidProjectTrustFile,
        UnsafeProjectTrustStorage,
        ProjectTrustReadFailed,
        ProjectTrustLockFailed,
        ProjectTrustWriteFailed,
        ProjectTrustCommitIndeterminate,
        InvalidHeader,
        InvalidRecord,
        InvalidTranscript,
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

    pub const ModelLess = struct {
        allocator: std.mem.Allocator,
        selection: SessionSelection,

        // Heap destruction follows explicit field invalidation.
        // ziglint-ignore: Z030
        pub fn deinit(self: *ModelLess) void {
            const allocator = self.allocator;
            self.selection.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }
    };

    pub const Lifecycle = union(enum) {
        model_less: *ModelLess,
        runnable: *Services,

        pub fn journalPath(self: Lifecycle) []const u8 {
            return switch (self) {
                .model_less => |value| value.selection.journalPath(),
                .runnable => |value| value.journalPath(),
            };
        }

        pub fn activeModel(self: Lifecycle) ?ai.ModelIdentity {
            return switch (self) {
                .model_less => |value| value.selection.restoredModel(),
                .runnable => |value| value.modelIdentity(),
            };
        }

        pub fn deinit(self: Lifecycle) void {
            switch (self) {
                .model_less => |value| value.deinit(),
                .runnable => |value| value.deinit(),
            }
        }
    };

    pub const Interactive = struct {
        lifecycle: Lifecycle,
        transcript_value: SessionTranscript,

        pub fn transcript(self: *const Interactive) *const SessionTranscript {
            return &self.transcript_value;
        }

        pub fn journalPath(self: *const Interactive) []const u8 {
            return self.lifecycle.journalPath();
        }

        pub fn activeModel(self: *const Interactive) ?ai.ModelIdentity {
            return self.lifecycle.activeModel();
        }

        pub fn deinit(self: *Interactive) void {
            self.lifecycle.deinit();
            self.transcript_value.deinit();
            self.* = undefined;
        }
    };

    const Mode = enum { runtime, interactive, reopen };

    fn allowsModelLess(comptime mode: Mode) bool {
        return mode != .runtime;
    }

    fn includesTranscript(comptime mode: Mode) bool {
        return mode == .interactive;
    }

    /// Mode-specific creation result: interactive creation always carries a
    /// required transcript; runtime and reopen cannot contain one.
    fn Result(comptime mode: Mode) type {
        return switch (mode) {
            .runtime, .reopen => struct {
                lifecycle: Lifecycle,
            },
            .interactive => struct {
                lifecycle: Lifecycle,
                transcript: SessionTranscript,
            },
        };
    }

    io: std.Io,
    allocator: std.mem.Allocator,
    selection: SessionSelection,
    snapshot: ModelConfigSnapshot,
    resolved: ModelResolution.Resolved,
    credential_resolver: *CredentialManager.PersistentResolver,
    runtime: *AgentSessionRuntime,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
    ) Error!*Services {
        const created = try createOwned(allocator, io, .runtime, inputs, .http);
        return switch (created.lifecycle) {
            .runnable => |runtime| runtime,
            .model_less => |runtime| {
                runtime.deinit();
                return error.SelectionRequired;
            },
        };
    }

    pub fn createInteractive(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
    ) Error!Interactive {
        const created = try createOwned(allocator, io, .interactive, inputs, .http);
        return .{
            .lifecycle = created.lifecycle,
            .transcript_value = created.transcript,
        };
    }

    pub fn reopenInteractive(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
    ) Error!Lifecycle {
        const created = try createOwned(allocator, io, .reopen, inputs, .http);
        return created.lifecycle;
    }

    pub fn session(self: *Services) *AgentSession {
        return self.runtime.session();
    }

    fn paths(self: *const Services) *const ZiPaths {
        return self.selection.pathsView();
    }

    fn journalPath(self: *const Services) []const u8 {
        return self.selection.journalPath();
    }

    fn modelIdentity(self: *const Services) ai.ModelIdentity {
        return self.resolved.selection;
    }

    fn modelDiagnostic(self: *const Services) ?ModelConfigSnapshot.Diagnostic {
        return self.snapshot.diagnostic();
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *Services) void {
        const allocator = self.allocator;
        self.runtime.deinit();
        self.credential_resolver.deinit();
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
    ) Error!*Services {
        const created = try createOwned(
            allocator,
            io,
            .runtime,
            inputs,
            .{ .borrowed = transport },
        );
        return switch (created.lifecycle) {
            .runnable => |runtime| runtime,
            .model_less => |runtime| {
                runtime.deinit();
                return error.SelectionRequired;
            },
        };
    }

    fn createInteractiveWithTransport(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
        transport: ai.transport.Transport,
    ) Error!Interactive {
        const created = try createOwned(
            allocator,
            io,
            .interactive,
            inputs,
            .{ .borrowed = transport },
        );
        return .{
            .lifecycle = created.lifecycle,
            .transcript_value = created.transcript,
        };
    }

    fn createOwned(
        allocator: std.mem.Allocator,
        io: std.Io,
        comptime mode: Mode,
        inputs: Inputs,
        transport: Transport,
    ) Error!Result(mode) {
        var selection = try SessionSelection.select(
            allocator,
            io,
            inputs.startup_cwd,
            inputs.home,
            inputs.sources,
            inputs.session,
        );
        errdefer {
            selection.discardNew();
            selection.deinit();
        }

        var runtime_options = inputs.options;
        runtime_options.prompt.working_directory = selection.pathsView().cwd;
        var resources = try RuntimeResources.resolve(
            allocator,
            io,
            selection.pathsView(),
            inputs.project_trust,
            runtime_options.prompt.policy,
        );
        defer resources.deinit();
        runtime_options.prompt.policy = resources.policy();

        var settings = SettingsStore.load(
            allocator,
            io,
            selection.pathsView(),
            resources.projectTrust(),
        ) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
        };
        defer settings.deinit();
        var snapshot = try ModelConfigSnapshot.load(allocator, io, selection.pathsView());
        errdefer snapshot.deinit();

        var planning_credentials = switch (explicitSelection(inputs)) {
            .complete => CredentialStore.empty(allocator) catch |failure|
                return mapCredentialStoreFailure(failure),
            else => CredentialStore.load(allocator, io, selection.pathsView()) catch |failure|
                return mapCredentialStoreFailure(failure),
        };
        defer planning_credentials.deinit();
        const bootstrap_models = try ModelAdmission.buildModels(
            snapshot.view(),
            settings.enabled_models,
            planning_credentials.entries,
            inputs.environment,
        );
        const bootstrap_plan = ModelBootstrapPolicy.plan(.{
            .session_state = if (selection.isFresh()) .fresh else .existing,
            .explicit = explicitSelection(inputs),
            .fresh_scoped_models = bootstrap_models.scopedItems(),
            .restored_model = selection.restoredModel(),
            .effective_settings_default = settingsDefault(&settings),
            .available_models = bootstrap_models.availableItems(),
        }) catch |failure| return switch (failure) {
            error.IncompleteExplicitSelection => error.IncompleteSelection,
            error.TooManyScopedModels,
            error.TooManyAvailableModels,
            error.TooManyCandidates,
            => error.InvalidModelConfiguration,
        };

        var refresh_http = ai.transport.HttpTransport.init(allocator);
        const refresh_transport = switch (transport) {
            .http => refresh_http.transport(),
            .borrowed => |borrowed| borrowed,
        };
        var resolved = ModelAdmission.admitPlan(
            allocator,
            io,
            selection.pathsView(),
            refresh_transport,
            snapshot.view(),
            bootstrap_plan,
            .{
                .cli_api_key = inputs.cli_api_key,
                .environment = inputs.environment,
                .sources = inputs.sources,
            },
        ) catch |failure| {
            if (failure != error.SelectionRequired or !allowsModelLess(mode)) return failure;
            const model_less = try allocator.create(ModelLess);
            errdefer allocator.destroy(model_less);
            var transcript_value: ?SessionTranscript = if (includesTranscript(mode))
                try SessionTranscript.init(allocator, selection.restoredView())
            else
                null;
            errdefer if (transcript_value) |*transcript| transcript.deinit();
            snapshot.deinit();
            model_less.* = .{
                .allocator = allocator,
                .selection = selection,
            };
            return switch (mode) {
                .interactive => .{
                    .lifecycle = .{ .model_less = model_less },
                    .transcript = transcript_value.?,
                },
                .runtime, .reopen => .{
                    .lifecycle = .{ .model_less = model_less },
                },
            };
        };
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
        // The persistent resolver is the sole live credential authority; wipe
        // the admission-time copy so the runtime retains no duplicate secrets.
        resolved.wipeCredentials();
        var runtime_config = resolved.runtimeConfig();
        runtime_config.auth_resolver = credential_resolver.resolver();
        var cwd = std.Io.Dir.openDir(.cwd(), io, selection.pathsView().cwd, .{}) catch
            return error.CwdUnavailable;
        var cwd_transferred = false;
        errdefer if (!cwd_transferred) cwd.close(io);
        var transcript_value: ?SessionTranscript = if (includesTranscript(mode))
            try SessionTranscript.init(allocator, selection.restoredView())
        else
            null;
        errdefer if (transcript_value) |*transcript| transcript.deinit();
        var opened = selection.takeJournal();
        const runtime_result = switch (transport) {
            .http => AgentSessionRuntime.createDurable(
                allocator,
                io,
                cwd,
                runtime_config,
                runtime_options,
                &opened,
                inputs.sources,
            ),
            .borrowed => |borrowed| AgentSessionRuntime.createDurableWithTransport(
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
        // createDurable transfers cwd on success and closes it on any failure,
        // so ownership leaves createOwned at this point either way.
        cwd_transferred = true;
        const runtime = try runtime_result;
        errdefer runtime.deinit();

        const self = try allocator.create(Services);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .selection = selection,
            .snapshot = snapshot,
            .resolved = resolved,
            .credential_resolver = credential_resolver,
            .runtime = runtime,
        };
        return switch (mode) {
            .interactive => .{
                .lifecycle = .{ .runnable = self },
                .transcript = transcript_value.?,
            },
            .runtime, .reopen => .{
                .lifecycle = .{ .runnable = self },
            },
        };
    }

    fn explicitSelection(inputs: Inputs) ModelBootstrapPolicy.ExplicitSelection {
        if (inputs.requested_provider) |provider| {
            const model = inputs.requested_model orelse return .provider_only;
            return .{ .complete = .{ .provider = provider, .model = model } };
        }
        return if (inputs.requested_model != null) .model_only else .absent;
    }

    fn settingsDefault(settings: *const SettingsStore.Snapshot) ?ai.ModelIdentity {
        const provider = settings.default_provider orelse return null;
        const model = settings.default_model orelse return null;
        return .{ .provider = provider, .model = model };
    }

    fn mapCredentialStoreFailure(failure: CredentialStore.Error) Error {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidCredentialFile => error.InvalidCredentialFile,
            error.UnsupportedVersion => error.UnsupportedVersion,
            error.UnsafePath => error.UnsafeCredentialStorage,
            error.ReadFailed => error.CredentialReadFailed,
            error.LockFailed => error.CredentialLockFailed,
            error.WriteFailed => error.CredentialWriteFailed,
            error.CommitIndeterminate => error.CredentialCommitIndeterminate,
        };
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

    fn openWritableJournal(allocator: std.mem.Allocator, path: []const u8) !SessionJournal.Opened {
        const parent = std.fs.path.dirname(path).?;
        var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, parent, .{});
        defer directory.close(std.testing.io);
        return SessionJournal.openWritable(
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

        var resume_fake = fake_api.FakeTransport.init(&.{});
        var resumed = try createInteractiveWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .{ .open = journal_path },
            .sources = sources.view(),
        }, resume_fake.transport());
        const transcript_view = resumed.transcript();
        try std.testing.expectEqual(@as(usize, 3), transcript_view.items.len);
        try std.testing.expectEqualStrings(
            "model-a",
            transcript_view.items[0].content.model_change.model,
        );
        try std.testing.expectEqualStrings(
            "hello",
            transcript_view.items[1].content.user.parts[0].text,
        );
        try std.testing.expectEqualStrings(
            "composed",
            transcript_view.items[2].content.assistant.parts[0].text.text,
        );
        resumed.deinit();

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
        try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
        try temporary.dir.createDir(
            std.testing.io,
            ".zi/agent",
            std.Io.File.Permissions.fromMode(0o700),
        );
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

        var identity = try ProjectTrust.Identity.init(std.testing.allocator, std.testing.io, root);
        defer identity.deinit();
        var trust_paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer trust_paths.deinit();
        try ProjectTrust.put(
            std.testing.allocator,
            std.testing.io,
            &trust_paths,
            &identity,
            .trusted,
        );
        var saved = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
            .requested_provider = "openai",
            .requested_model = "gpt-5.6",
            .cli_api_key = "secret",
        }, fake.transport());
        try std.testing.expect(std.mem.startsWith(u8, saved.session().systemPrompt(), "Project base."));
        saved.deinit();

        try ProjectTrust.put(
            std.testing.allocator,
            std.testing.io,
            &trust_paths,
            &identity,
            .untrusted,
        );
        var denied = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
            .requested_provider = "openai",
            .requested_model = "gpt-5.6",
            .cli_api_key = "secret",
        }, fake.transport());
        try std.testing.expect(std.mem.startsWith(u8, denied.session().systemPrompt(), "Global base."));
        denied.deinit();

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

        try ProjectTrust.put(
            std.testing.allocator,
            std.testing.io,
            &trust_paths,
            &identity,
            .trusted,
        );
        var rejected = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
            .requested_provider = "openai",
            .requested_model = "gpt-5.6",
            .cli_api_key = "secret",
            .project_trust = .reject,
        }, fake.transport());
        try std.testing.expect(std.mem.startsWith(u8, rejected.session().systemPrompt(), "Global base."));
        rejected.deinit();

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

    test "runtime services consult saved trust only for automatic protected resources" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
        try temporary.dir.createDir(
            std.testing.io,
            ".zi/agent",
            std.Io.File.Permissions.fromMode(0o700),
        );
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "Global base.",
        });
        const trust_file = try temporary.dir.createFile(std.testing.io, ".zi/agent/trust.json", .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        try trust_file.writePositionalAll(std.testing.io, "invalid", 0);
        trust_file.close(std.testing.io);
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var sources: TestSources = .{};
        var fake = fake_api.FakeTransport.init(&.{});
        const base_inputs: Inputs = .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
            .requested_provider = "openai",
            .requested_model = "gpt-5.6",
            .cli_api_key = "secret",
        };

        var no_project_source = try createWithTransport(
            std.testing.allocator,
            std.testing.io,
            base_inputs,
            fake.transport(),
        );
        try std.testing.expect(std.mem.startsWith(
            u8,
            no_project_source.session().systemPrompt(),
            "Global base.",
        ));
        no_project_source.deinit();

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        try std.testing.expectError(
            error.InvalidProjectTrustFile,
            createWithTransport(std.testing.allocator, std.testing.io, base_inputs, fake.transport()),
        );

        var rejected_inputs = base_inputs;
        rejected_inputs.project_trust = .reject;
        var rejected = try createWithTransport(
            std.testing.allocator,
            std.testing.io,
            rejected_inputs,
            fake.transport(),
        );
        try std.testing.expect(std.mem.startsWith(u8, rejected.session().systemPrompt(), "Global base."));
        rejected.deinit();

        var approved_inputs = base_inputs;
        approved_inputs.project_trust = .approve;
        var approved = try createWithTransport(
            std.testing.allocator,
            std.testing.io,
            approved_inputs,
            fake.transport(),
        );
        defer approved.deinit();
        try std.testing.expect(std.mem.startsWith(u8, approved.session().systemPrompt(), "Project base."));
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

        var stored_identity = try ProjectTrust.Identity.init(
            std.testing.allocator,
            std.testing.io,
            stored_cwd,
        );
        defer stored_identity.deinit();
        var trust_paths = try ZiPaths.init(std.testing.allocator, stored_cwd, root);
        defer trust_paths.deinit();
        try ProjectTrust.put(
            std.testing.allocator,
            std.testing.io,
            &trust_paths,
            &stored_identity,
            .trusted,
        );

        var resumed = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = launch_cwd,
            .home = root,
            .session = .{ .open = journal_path },
            .sources = sources.view(),
            .cli_api_key = "secret",
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

    test "runtime services retain a synthetic interruption for restored open turns" {
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

        var writable = try openWritableJournal(std.testing.allocator, journal_path);
        const parent_id = writable.restore_candidate.active_leaf_id.?;
        try writable.journal.append(.{ .message = .{
            .base = .{
                .id = "open-user",
                .parent_id = parent_id,
                .timestamp = "2026-08-19T10:30:02.000Z",
            },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "unfinished" } }} } },
        } }, .none());
        writable.deinit();

        var resumed = try createInteractiveWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .{ .open = journal_path },
            .sources = sources.view(),
            .cli_api_key = "custom-secret",
        }, fake.transport());
        const transcript_view = resumed.transcript();
        try std.testing.expectEqual(@as(usize, 3), transcript_view.items.len);
        try std.testing.expectEqualStrings(
            "unfinished",
            transcript_view.items[1].content.user.parts[0].text,
        );
        try std.testing.expect(transcript_view.items[2].content == .interrupted);
        try std.testing.expect(transcript_view.items[2].metadata == .recovered_open_turn);
        try std.testing.expectEqualStrings(
            "open-user",
            transcript_view.items[2].content.interrupted.turn_id,
        );
        resumed.deinit();
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

    test "runtime services fall back from an invalid restored model and append one model change" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi");
        try temporary.dir.createDir(
            std.testing.io,
            ".zi/agent",
            std.Io.File.Permissions.fromMode(0o700),
        );
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

        try std.testing.expectError(error.SelectionRequired, createWithTransport(
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
        var unchanged = try openJournal(std.testing.allocator, journal_path);
        try std.testing.expectEqual(@as(usize, 1), unchanged.restore_candidate.entries.len);
        unchanged.deinit();

        try temporary.dir.deleteFile(std.testing.io, ".zi/agent/models.json");
        var credential_paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer credential_paths.deinit();
        try CredentialStore.put(std.testing.allocator, std.testing.io, &credential_paths, .{
            .provider_id = "openai",
            .credential = .{ .api_key = .{ .key = "stored-openai" } },
        });
        var resumed = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .{ .open = journal_path },
            .sources = sources.view(),
        }, fake.transport());
        resumed.deinit();

        var opened = try openJournal(std.testing.allocator, journal_path);
        defer opened.deinit();
        try std.testing.expectEqual(@as(usize, 2), opened.restore_candidate.entries.len);
        try std.testing.expectEqualStrings("model-a", opened.restore_candidate.entries[0].model_change.selection.model);
        // ziglint-ignore: Z024
        try std.testing.expectEqualStrings("openai", opened.restore_candidate.entries[1].model_change.selection.provider);
        try std.testing.expectEqualStrings("gpt-5.6-sol", opened.restore_candidate.active_model.?.model);
    }

    test "runtime services use trusted project enabled scope then settings default without prompt files" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi");
        try temporary.dir.createDir(
            std.testing.io,
            ".zi/agent",
            std.Io.File.Permissions.fromMode(0o700),
        );
        try writeCustomModels(&temporary);
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var zi_paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer zi_paths.deinit();
        try CredentialStore.put(std.testing.allocator, std.testing.io, &zi_paths, .{
            .provider_id = "custom-openai",
            .credential = .{ .api_key = .{ .key = "custom-key" } },
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/settings.json",
            .data =
            // ziglint-ignore: Z024 -- compact settings fixture
            "{\"defaultProvider\":\"custom-openai\",\"defaultModel\":\"model-b\",\"enabledModels\":[\"custom-openai/model-a\"]}",
        });
        var identity = try ProjectTrust.Identity.init(std.testing.allocator, std.testing.io, root);
        defer identity.deinit();
        try ProjectTrust.put(
            std.testing.allocator,
            std.testing.io,
            &zi_paths,
            &identity,
            .trusted,
        );
        var sources: TestSources = .{};
        var fake = fake_api.FakeTransport.init(&.{});

        var scoped = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
        }, fake.transport());
        try std.testing.expectEqualStrings("model-a", scoped.resolved.selection.model);
        scoped.deinit();

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/settings.json",
            .data = "{\"defaultProvider\":\"custom-openai\",\"defaultModel\":\"model-b\"}",
        });
        var configured_default = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
        }, fake.transport());
        try std.testing.expectEqualStrings("model-b", configured_default.resolved.selection.model);
        configured_default.deinit();

        var rejected = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
            .project_trust = .reject,
        }, fake.transport());
        defer rejected.deinit();
        try std.testing.expectEqualStrings("model-a", rejected.resolved.selection.model);
    }

    test "runtime services keep complete explicit failures terminal and reject partial selection" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi");
        try temporary.dir.createDir(
            std.testing.io,
            ".zi/agent",
            std.Io.File.Permissions.fromMode(0o700),
        );
        try writeCustomModels(&temporary);
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var zi_paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer zi_paths.deinit();
        try CredentialStore.put(std.testing.allocator, std.testing.io, &zi_paths, .{
            .provider_id = "openai",
            .credential = .{ .api_key = .{ .key = "openai-key" } },
        });
        var sources: TestSources = .{};
        var fake = fake_api.FakeTransport.init(&.{});
        const base: Inputs = .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
        };

        var partial = base;
        partial.requested_provider = "openai";
        try std.testing.expectError(
            error.IncompleteSelection,
            createWithTransport(std.testing.allocator, std.testing.io, partial, fake.transport()),
        );

        var unknown = base;
        unknown.requested_provider = "openai";
        unknown.requested_model = "unknown";
        try std.testing.expectError(
            error.UnknownSelection,
            createWithTransport(std.testing.allocator, std.testing.io, unknown, fake.transport()),
        );

        var missing_credential = base;
        missing_credential.requested_provider = "custom-openai";
        missing_credential.requested_model = "model-b";
        try std.testing.expectError(
            error.MissingCredential,
            createWithTransport(
                std.testing.allocator,
                std.testing.io,
                missing_credential,
                fake.transport(),
            ),
        );
    }

    test "complete explicit API key selection does not read auth storage" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi");
        try temporary.dir.createDir(
            std.testing.io,
            ".zi/agent",
            std.Io.File.Permissions.fromMode(0o700),
        );
        const auth_file = try temporary.dir.createFile(std.testing.io, ".zi/agent/auth.json", .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        try auth_file.writePositionalAll(std.testing.io, "invalid", 0);
        auth_file.close(std.testing.io);
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
            .requested_model = "gpt-5.6-sol",
            .cli_api_key = "explicit-key",
        }, fake.transport());
        defer services.deinit();
        try std.testing.expectEqualStrings("openai", services.resolved.selection.provider);
    }

    test "runtime services return SelectionRequired when no authenticated model exists" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var sources: TestSources = .{};
        var fake = fake_api.FakeTransport.init(&.{});

        const inputs: Inputs = .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
        };
        try std.testing.expectError(error.SelectionRequired, createWithTransport(
            std.testing.allocator,
            std.testing.io,
            inputs,
            fake.transport(),
        ));
        var sessions = try temporary.dir.openDir(std.testing.io, ".zi/agent/sessions", .{ .iterate = true });
        defer sessions.close(std.testing.io);
        var iterator = sessions.iterateAssumeFirstIteration();
        try std.testing.expect(try iterator.next(std.testing.io) == null);
    }

    test "interactive runtime admits and preserves a model-less durable session" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var sources: TestSources = .{};

        var interactive = try createInteractive(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
        });
        defer interactive.deinit();
        try std.testing.expectEqual(@as(usize, 0), interactive.transcript().items.len);
        switch (interactive.lifecycle) {
            .runnable => return error.UnexpectedRunnableSession,
            .model_less => {},
        }

        var sessions = try temporary.dir.openDir(std.testing.io, ".zi/agent/sessions", .{ .iterate = true });
        defer sessions.close(std.testing.io);
        var iterator = sessions.iterateAssumeFirstIteration();
        try std.testing.expect(try iterator.next(std.testing.io) != null);
        try std.testing.expect(try iterator.next(std.testing.io) == null);
    }

    test "failed OAuth refresh falls through to the next authenticated bootstrap candidate" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var zi_paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer zi_paths.deinit();
        try CredentialStore.put(std.testing.allocator, std.testing.io, &zi_paths, .{
            .provider_id = "openai-codex",
            .credential = .{ .oauth = .{
                .access = "expired-access",
                .refresh = "expired-refresh",
                .expires_at_ms = 1,
                .account_id = "expired-account",
            } },
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/settings.json",
            .data = "{\"enabledModels\":[\"openai-codex/gpt-5.6-terra\"]}",
        });
        const exchanges = [_]fake_api.Exchange{.{ .response = .{
            .status = 400,
            .body = "{\"error\":\"invalid_grant\"}",
        } }};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var sources: TestSources = .{};
        var services = try createWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .session = .new,
            .sources = sources.view(),
            .project_trust = .approve,
            .environment = .{ .entries = &.{.{
                .name = "OPENAI_API_KEY",
                .value = "environment-openai",
            }} },
        }, fake.transport());
        defer services.deinit();

        try std.testing.expectEqualStrings("openai", services.resolved.selection.provider);
        try std.testing.expectEqualStrings("gpt-5.6-sol", services.resolved.selection.model);
        try std.testing.expectEqual(@as(usize, 1), fake.next_index);
        var stored = try CredentialStore.load(std.testing.allocator, std.testing.io, &zi_paths);
        defer stored.deinit();
        try std.testing.expectEqualStrings("expired-refresh", stored.entries[0].credential.oauth.refresh);
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
};

pub const ReopenInputs = struct {
    const AgentSessionRuntime = SessionRuntime;
    const RuntimeServices = Services;
    const SessionSelection = Session.Selection;
    const SystemPrompt = Prompt.SystemPrompt;
    const max_environment_entries = 64;
    const max_sensitive_bytes = 1024 * 1024;

    pub const Error = error{
        OutOfMemory,
        TooManyEnvironmentEntries,
        SensitiveInputsTooLarge,
    };

    pub const Selection = struct {
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    sensitive: std.ArrayList([]u8) = .empty,
    inputs: RuntimeServices.Inputs,

    /// Owns every string in a runtime input that can outlive process parsing.
    /// Source callbacks and event sinks remain borrowed function contracts.
    pub fn init(
        allocator: std.mem.Allocator,
        source: RuntimeServices.Inputs,
    ) Error!ReopenInputs {
        if (source.environment.entries.len > max_environment_entries) {
            return error.TooManyEnvironmentEntries;
        }

        var self: ReopenInputs = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .inputs = undefined,
        };
        errdefer self.deinit();
        try self.sensitive.ensureTotalCapacity(
            allocator,
            source.environment.entries.len + @intFromBool(source.cli_api_key != null),
        );

        const owned = self.arena.allocator();
        const environment_entries = try owned.alloc(ai.auth.EnvironmentEntry, source.environment.entries.len);
        var sensitive_bytes: usize = 0;
        for (source.environment.entries, environment_entries) |entry, *destination| {
            const value = try self.copySensitive(entry.value, &sensitive_bytes);
            destination.* = .{
                .name = try owned.dupe(u8, entry.name),
                .value = value,
            };
        }
        const cli_api_key = if (source.cli_api_key) |value|
            try self.copySensitive(value, &sensitive_bytes)
        else
            null;

        self.inputs = .{
            .startup_cwd = try owned.dupe(u8, source.startup_cwd),
            .home = try owned.dupe(u8, source.home),
            .session = try copySessionIntent(owned, source.session),
            .sources = source.sources,
            .requested_provider = if (source.requested_provider) |value| try owned.dupe(u8, value) else null,
            .requested_model = if (source.requested_model) |value| try owned.dupe(u8, value) else null,
            .cli_api_key = cli_api_key,
            .project_trust = source.project_trust,
            .environment = .{ .entries = environment_entries },
            .options = try copyOptions(owned, source.options),
        };
        return self;
    }

    pub fn initial(self: *const ReopenInputs) RuntimeServices.Inputs {
        return self.inputs;
    }

    pub fn reopen(
        self: *const ReopenInputs,
        journal_path: []const u8,
        selection: Selection,
    ) RuntimeServices.Inputs {
        var result = self.inputs;
        result.session = .{ .open = journal_path };
        result.requested_provider = selection.provider;
        result.requested_model = selection.model;
        return result;
    }

    pub fn deinit(self: *ReopenInputs) void {
        for (self.sensitive.items) |value| std.crypto.secureZero(u8, value);
        self.sensitive.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn copySensitive(
        self: *ReopenInputs,
        value: []const u8,
        retained_bytes: *usize,
    ) Error![]u8 {
        if (value.len > max_sensitive_bytes -| retained_bytes.*) {
            return error.SensitiveInputsTooLarge;
        }
        const copy = try self.arena.allocator().dupe(u8, value);
        self.sensitive.appendAssumeCapacity(copy);
        retained_bytes.* += copy.len;
        return copy;
    }

    fn copySessionIntent(
        allocator: std.mem.Allocator,
        source: SessionSelection.Intent,
    ) error{OutOfMemory}!SessionSelection.Intent {
        return switch (source) {
            .new => .new,
            .continue_recent => .continue_recent,
            .open => |path| .{ .open = try allocator.dupe(u8, path) },
        };
    }

    fn copyOptions(
        allocator: std.mem.Allocator,
        source: AgentSessionRuntime.Options,
    ) error{OutOfMemory}!AgentSessionRuntime.Options {
        var result = source;
        result.prompt.working_directory = try allocator.dupe(u8, source.prompt.working_directory);
        result.prompt.policy = switch (source.prompt.policy) {
            .verbatim => |text| .{ .verbatim = try allocator.dupe(u8, text) },
            .composed => |composition| .{ .composed = try copyComposition(allocator, composition) },
        };
        return result;
    }

    fn copyComposition(
        allocator: std.mem.Allocator,
        source: SystemPrompt.Composition,
    ) error{OutOfMemory}!SystemPrompt.Composition {
        const sections = try allocator.alloc(SystemPrompt.ContextSection, source.context_sections.len);
        for (source.context_sections, sections) |section, *destination| {
            destination.* = .{
                .path = try allocator.dupe(u8, section.path),
                .text = try allocator.dupe(u8, section.text),
            };
        }
        const rules = try allocator.alloc([]const u8, source.rules.len);
        for (source.rules, rules) |rule, *destination| destination.* = try allocator.dupe(u8, rule);
        return .{
            .base = switch (source.base) {
                .builtin => .builtin,
                .custom => |text| .{ .custom = try allocator.dupe(u8, text) },
            },
            .context_sections = sections,
            .rules = rules,
        };
    }

    test "reopen inputs own nested launch text and wipe every copied secret" {
        var api_key = [_]u8{ 'c', 'l', 'i' };
        var environment_secret = [_]u8{ 'e', 'n', 'v' };
        var source_context = [_]u8{ 'r', 'u', 'l', 'e' };
        const environment = [_]ai.auth.EnvironmentEntry{.{
            .name = "OPENAI_API_KEY",
            .value = &environment_secret,
        }};
        const sections = [_]SystemPrompt.ContextSection{.{ .path = "AGENTS.md", .text = &source_context }};
        var owned = try ReopenInputs.init(std.testing.allocator, .{
            .startup_cwd = "/work",
            .home = "/home",
            .session = .{ .open = "session.jsonl" },
            .sources = undefined,
            .requested_provider = "openai",
            .requested_model = "model",
            .cli_api_key = &api_key,
            .environment = .{ .entries = &environment },
            .options = .{ .prompt = .{ .policy = .{ .composed = .{
                .context_sections = &sections,
                .rules = &.{"prompt rule"},
            } } } },
        });
        @memset(&api_key, 'x');
        @memset(&environment_secret, 'x');
        @memset(&source_context, 'x');

        try std.testing.expectEqualStrings("cli", owned.initial().cli_api_key.?);
        try std.testing.expectEqualStrings("env", owned.initial().environment.entries[0].value);
        try std.testing.expectEqualStrings(
            "rule",
            owned.initial().options.prompt.policy.composed.context_sections[0].text,
        );
        const reopened = owned.reopen("exact.jsonl", .{});
        try std.testing.expectEqualStrings("exact.jsonl", reopened.session.open);
        try std.testing.expect(reopened.requested_provider == null);
        try std.testing.expect(reopened.requested_model == null);

        owned.deinit();
    }
};

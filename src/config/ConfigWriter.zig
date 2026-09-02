const std = @import("std");
const AtomicReplace = @import("AtomicReplace.zig");
const Document = @import("Document.zig");
const Loader = @import("Loader.zig");
const Preset = @import("Preset.zig");
const SecureOpen = @import("SecureOpen.zig");
const Store = @import("Store.zig");

const ConfigWriter = @This();

pub const maximum_file_bytes: usize = Loader.maximum_file_bytes;
const temp_prefix = ".zi-config.tmp.";

pub const NonceError = AtomicReplace.NonceError;
pub const NonceSource = AtomicReplace.NonceSource;
pub const OpsError = AtomicReplace.OpsError;
pub const CreateTempError = AtomicReplace.CreateTempError;
pub const CommitOps = AtomicReplace.CommitOps;

pub const Definition = struct {
    provider: []const u8,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    system_prompt_append: ?[]const u8 = null,
    tint: ?[]const u8 = null,
};

pub const SaveKind = enum { saved, updated };

pub const SaveOutcome = union(enum) {
    written: SaveKind,
    state_shadow,
    no_path,
    unusable,
    conflict,
    malformed_presets,
    too_large,
    invalid: Preset.Invalid,
    failed,

    pub fn deinit(self: *SaveOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .invalid => |*value| value.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const Options = struct {
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource = null,
    commit_ops: CommitOps = .standard,
    /// Borrowed for Owner's lifetime.
    home: ?[]const u8 = null,
    /// Borrowed for Owner's lifetime.
    cwd: ?[]const u8 = null,
};

const SourceState = enum { no_path, unusable, writable };

/// Address-stable owner for config Store borrows and the replaceable preset cache.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource,
    commit_ops: CommitOps,
    path: ?[]u8,
    source: SourceState,
    expected: ?Loader.Fingerprint,
    document_value: Document,
    presets_value: Preset.Enumeration,
    state_document: ?*const Document,
    home: ?[]const u8,
    cwd: ?[]const u8,
    generation: u64 = 0,

    /// On success consumes config_result and initial_presets. On error both remain owned.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config_result: *?Loader.Result,
        initial_presets: *Preset.Enumeration,
        state_document: ?*const Document,
        options: Options,
    ) error{OutOfMemory}!*Owner {
        const loaded_document = if (config_result.*) |*result| result.document != null else false;
        var synthetic: ?Document = null;
        errdefer if (synthetic) |*value| value.deinit();
        if (!loaded_document) synthetic = Document.parse(allocator, "{}", .{}) catch return error.OutOfMemory;

        const owner = allocator.create(Owner) catch return error.OutOfMemory;
        errdefer allocator.destroy(owner);

        const source: SourceState = if (config_result.*) |result| switch (result.outcome) {
            .loaded, .empty, .missing => .writable,
            .invalid, .oversize, .unreadable, .non_regular => .unusable,
        } else .no_path;
        const path = if (config_result.*) |result| result.path else null;
        const expected = if (config_result.*) |result| result.fingerprint else null;
        const document_value = if (config_result.*) |*result|
            if (result.document) |value| value else synthetic.?
        else
            synthetic.?;

        owner.* = .{
            .allocator = allocator,
            .io = io,
            .secure_open = options.secure_open,
            .nonce_source = options.nonce_source,
            .commit_ops = options.commit_ops,
            .path = path,
            .source = source,
            .expected = expected,
            .document_value = document_value,
            .presets_value = initial_presets.*,
            .state_document = state_document,
            .home = options.home,
            .cwd = options.cwd,
        };
        if (config_result.*) |*result| {
            result.* = undefined;
            config_result.* = null;
        }
        initial_presets.* = undefined;
        synthetic = null;
        return owner;
    }

    pub fn deinit(self: *Owner) void {
        const allocator = self.allocator;
        self.presets_value.deinit(allocator);
        self.document_value.deinit();
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn document(self: *const Owner) *const Document {
        return &self.document_value;
    }

    pub fn plans(self: *const Owner) []const Preset.Plan {
        return self.presets_value.plans;
    }

    pub fn invalid(self: *const Owner) []const Preset.Invalid {
        return self.presets_value.invalid;
    }

    pub fn lookup(self: *const Owner, name: []const u8) Preset.BorrowedLookup {
        for (self.presets_value.plans) |*plan| {
            if (std.mem.eql(u8, plan.name, name)) return .{ .plan = plan };
        }
        for (self.presets_value.invalid) |*item| {
            if (std.mem.eql(u8, item.name, name)) return .{ .invalid = item };
        }
        return .missing;
    }

    pub fn inspect(
        self: *const Owner,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) error{OutOfMemory}!Preset.SaveInspection {
        return Preset.inspectForSave(allocator, self.documents(), name);
    }

    pub fn configPath(self: *const Owner) ?[]const u8 {
        return self.path;
    }

    pub fn configRoot(self: *const Owner) ?[]const u8 {
        return if (self.path) |path| std.fs.path.dirname(path) else null;
    }

    pub fn generationValue(self: *const Owner) u64 {
        return self.generation;
    }

    pub fn savePreset(
        self: *Owner,
        outcome_allocator: std.mem.Allocator,
        name: []const u8,
        definition: Definition,
    ) error{OutOfMemory}!SaveOutcome {
        if (!Preset.nameValid(name)) return .{ .invalid = try makeInvalid(
            outcome_allocator,
            name,
            null,
            .invalid_name,
        ) };
        if (definition.provider.len == 0) return .{ .invalid = try makeInvalid(
            outcome_allocator,
            name,
            "provider",
            .missing_provider,
        ) };
        if (!definitionWithinBounds(definition)) return .too_large;
        if (definition.tint) |tint| if (!canonicalTint(tint)) return .{ .invalid = try makeInvalid(
            outcome_allocator,
            name,
            "tint",
            .invalid_tint,
        ) };

        var inspection = try self.inspect(self.allocator, name);
        defer inspection.deinit(self.allocator);
        if (inspection.state_shadow) return .state_shadow;
        switch (self.source) {
            .no_path => return .no_path,
            .unusable => return .unusable,
            .writable => {},
        }

        var preparation = try self.prepareCandidate(
            outcome_allocator,
            name,
            definition,
            inspection.description,
            if (inspection.exists) .updated else .saved,
        );
        switch (preparation) {
            .malformed_presets => return .malformed_presets,
            .too_large => return .too_large,
            .invalid => |report| return .{ .invalid = report },
            .failed => return .failed,
            .candidate => |*candidate| {
                defer candidate.deinit(self.allocator);
                const atomic = try AtomicReplace.commit(.{
                    .allocator = self.allocator,
                    .io = self.io,
                    .secure_open = self.secure_open,
                    .nonce_source = self.nonce_source,
                    .commit_ops = self.commit_ops,
                    .path = self.path.?,
                    .expected = self.expected,
                    .temp_prefix = temp_prefix,
                }, candidate.bytes());
                const installed = switch (atomic) {
                    .written => |value| value,
                    .conflict => return .conflict,
                    .target_unavailable, .unavailable, .failed => return .failed,
                };
                self.expected = installed;
                std.mem.swap(Document, &self.document_value, &candidate.document);
                std.mem.swap(Preset.Enumeration, &self.presets_value, &candidate.presets);
                self.generation +%= 1;
                return .{ .written = candidate.kind };
            },
        }
    }

    fn documents(self: *const Owner) Preset.Documents {
        return .{ .state = self.state_document, .config = &self.document_value };
    }

    fn promptRoots(self: *const Owner) Preset.PromptRoots {
        return .{
            .secure_open = self.secure_open,
            .config_root = self.configRoot(),
            .home = self.home,
            .cwd = self.cwd,
        };
    }

    fn prepareCandidate(
        self: *Owner,
        outcome_allocator: std.mem.Allocator,
        name: []const u8,
        definition: Definition,
        description: ?[]const u8,
        kind: SaveKind,
    ) error{OutOfMemory}!Preparation {
        var working = cloneDocument(self.allocator, &self.document_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .failed,
        };
        defer working.deinit();
        const root = &working.parsed.value.object;
        _ = root.orderedRemove(try flatKey(working.parsed.arena.allocator(), name));

        var presets: *std.json.ObjectMap = undefined;
        if (root.getPtr("presets")) |value| {
            presets = switch (value.*) {
                .object => |*object| object,
                else => return .malformed_presets,
            };
        } else {
            const arena = working.parsed.arena.allocator();
            root.put(arena, "presets", .{ .object = std.json.ObjectMap.empty }) catch
                return error.OutOfMemory;
            presets = &root.getPtr("presets").?.object;
        }

        const arena = working.parsed.arena.allocator();
        var preset = std.json.ObjectMap.empty;
        if (description) |value| try putString(arena, &preset, "description", value);
        if (definition.tint) |value| try putString(arena, &preset, "tint", value);
        try putString(arena, &preset, "provider", definition.provider);
        if (definition.model) |value| try putString(arena, &preset, "model", value);
        if (definition.effort) |value| try putString(arena, &preset, "effort", value);
        if (definition.system_prompt) |value| try putString(arena, &preset, "system_prompt", value);
        if (definition.system_prompt_append) |value| {
            try putString(arena, &preset, "system_prompt_append", value);
        }
        const owned_name = arena.dupe(u8, name) catch return error.OutOfMemory;
        presets.put(arena, owned_name, .{ .object = preset }) catch return error.OutOfMemory;

        const storage = self.allocator.alloc(u8, maximum_file_bytes + 1) catch return error.OutOfMemory;
        var storage_owned = true;
        defer if (storage_owned) wipeFree(self.allocator, storage);
        var writer = std.Io.Writer.fixed(storage);
        std.json.Stringify.value(working.parsed.value, .{ .whitespace = .indent_2 }, &writer) catch return .too_large;
        const bytes = writer.buffered();
        if (bytes.len > maximum_file_bytes) return .too_large;

        var final_document = Document.parse(self.allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InputTooLarge,
            error.NestingTooDeep,
            error.TooManyFields,
            error.TooManyTokens,
            error.StringTooLong,
            error.NumberOutOfRange,
            => return .too_large,
            error.InvalidLimits, error.InvalidJson, error.RootNotObject => return .failed,
        };
        var document_owned = true;
        defer if (document_owned) final_document.deinit();
        var enumeration = Preset.enumerate(
            self.allocator,
            self.io,
            .{ .state = self.state_document, .config = &final_document },
            self.promptRoots(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooManyPresets, error.RetainedDataTooLarge => return .too_large,
        };
        var enumeration_owned = true;
        defer if (enumeration_owned) enumeration.deinit(self.allocator);
        switch (lookupEnumeration(&enumeration, name)) {
            .plan => {},
            .invalid => |report| return .{ .invalid = try cloneInvalid(outcome_allocator, report) },
            .missing => return .failed,
        }
        storage_owned = false;
        document_owned = false;
        enumeration_owned = false;
        return .{ .candidate = .{
            .document = final_document,
            .presets = enumeration,
            .storage = storage,
            .bytes_len = bytes.len,
            .kind = kind,
        } };
    }
};

const Candidate = struct {
    document: Document,
    presets: Preset.Enumeration,
    storage: []u8,
    bytes_len: usize,
    kind: SaveKind,

    fn bytes(self: *const Candidate) []const u8 {
        return self.storage[0..self.bytes_len];
    }

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        self.presets.deinit(allocator);
        self.document.deinit();
        wipeFree(allocator, self.storage);
        self.* = undefined;
    }
};

const Preparation = union(enum) {
    candidate: Candidate,
    malformed_presets,
    too_large,
    invalid: Preset.Invalid,
    failed,
};

fn canonicalTint(tint: []const u8) bool {
    inline for (.{ "teal", "violet", "rose", "sage" }) |allowed| {
        if (std.mem.eql(u8, tint, allowed)) return true;
    }
    return false;
}

fn definitionWithinBounds(definition: Definition) bool {
    if (definition.provider.len > Document.maximum_string_bytes) return false;
    inline for (.{
        definition.model,
        definition.effort,
        definition.system_prompt,
        definition.system_prompt_append,
        definition.tint,
    }) |value| if (value) |bytes| if (bytes.len > Document.maximum_string_bytes) return false;
    return true;
}

fn cloneDocument(allocator: std.mem.Allocator, source: *const Document) Document.Error!Document {
    var wiping: Document.WipingAllocator = .{ .backing = allocator };
    const scratch = wiping.allocator();
    const bytes = std.json.Stringify.valueAlloc(scratch, source.parsed.value, .{}) catch
        return error.OutOfMemory;
    defer scratch.free(bytes);
    return Document.parse(allocator, bytes, .{});
}

fn flatKey(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    return std.mem.concat(allocator, u8, &.{ "presets.", name }) catch return error.OutOfMemory;
}

fn putString(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) error{OutOfMemory}!void {
    const owned = allocator.dupe(u8, value) catch return error.OutOfMemory;
    object.put(allocator, key, .{ .string = owned }) catch return error.OutOfMemory;
}

fn lookupEnumeration(enumeration: *const Preset.Enumeration, name: []const u8) Preset.BorrowedLookup {
    for (enumeration.plans) |*plan| if (std.mem.eql(u8, plan.name, name)) return .{ .plan = plan };
    for (enumeration.invalid) |*item| if (std.mem.eql(u8, item.name, name)) return .{ .invalid = item };
    return .missing;
}

fn makeInvalid(
    allocator: std.mem.Allocator,
    name: []const u8,
    field: ?[]const u8,
    reason: Preset.InvalidReason,
) error{OutOfMemory}!Preset.Invalid {
    const owned_name = allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer wipeFree(allocator, owned_name);
    const owned_field = if (field) |value| allocator.dupe(u8, value) catch return error.OutOfMemory else null;
    return .{ .name = owned_name, .field = owned_field, .reason = reason };
}

fn cloneInvalid(allocator: std.mem.Allocator, source: *const Preset.Invalid) error{OutOfMemory}!Preset.Invalid {
    return makeInvalid(allocator, source.name, source.field, source.reason);
}

fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

const TestSecureOpen = struct {
    directory: std.Io.Dir,
    base: []const u8,

    fn relative(self: *TestSecureOpen, path: []const u8) SecureOpen.Error![]const u8 {
        if (!std.mem.startsWith(u8, path, self.base) or path.len <= self.base.len or
            path[self.base.len] != '/') return error.InvalidPath;
        return path[self.base.len + 1 ..];
    }

    pub fn statAbsolute(
        self: *TestSecureOpen,
        io: std.Io,
        path: []const u8,
    ) SecureOpen.Error!std.Io.File.Stat {
        return self.directory.statFile(
            io,
            try self.relative(path),
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Failed,
        };
    }

    pub fn openAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File {
        return self.directory.openFile(io, try self.relative(path), .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Failed,
        };
    }
};

const EmptyStore = struct {
    pub fn find(_: *const EmptyStore, _: []const u8) ?Store.Setting {
        return null;
    }

    pub fn get(_: *const EmptyStore, _: []const u8) ?[]const u8 {
        return null;
    }
};

const FixedNonce = struct {
    value: u8 = 1,

    pub fn fillBytes(self: *FixedNonce, bytes: []u8) NonceError!void {
        @memset(bytes, self.value);
        self.value +%= 1;
    }
};

const TestHarness = struct {
    tmp: std.testing.TmpDir,
    directory: std.Io.Dir,
    base: [:0]u8,
    access: TestSecureOpen,
    nonce: FixedNonce = .{},

    fn init() !TestHarness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "private", .fromMode(0o700));
        const directory = try tmp.dir.openDir(std.testing.io, "private", .{});
        errdefer directory.close(std.testing.io);
        const base = try directory.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{
            .tmp = tmp,
            .directory = directory,
            .base = base,
            .access = .{ .directory = directory, .base = base },
        };
    }

    fn deinit(self: *TestHarness) void {
        std.testing.allocator.free(self.base);
        self.directory.close(std.testing.io);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn path(self: *TestHarness) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.base, "config.json" });
    }

    fn load(self: *TestHarness) !Loader.Result {
        const path_value = try self.path();
        defer std.testing.allocator.free(path_value);
        return Loader.loadTierFile(
            std.testing.allocator,
            std.testing.io,
            SecureOpen.Capability.from(&self.access),
            path_value,
        );
    }

    fn presets(self: *TestHarness, config: ?*const Document) !Preset.Enumeration {
        return Preset.enumerate(
            std.testing.allocator,
            std.testing.io,
            .{ .config = config },
            .{ .secure_open = SecureOpen.Capability.from(&self.access), .config_root = self.base },
        );
    }

    fn owner(self: *TestHarness, result: *?Loader.Result, presets_value: *Preset.Enumeration) !*Owner {
        return Owner.init(
            std.testing.allocator,
            std.testing.io,
            result,
            presets_value,
            null,
            .{
                .secure_open = SecureOpen.Capability.from(&self.access),
                .nonce_source = NonceSource.from(&self.nonce),
                .cwd = self.base,
            },
        );
    }
};

test "config writer publishes a missing file through stable document and preset slots" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    var loaded_value = try harness.load();
    var loaded: ?Loader.Result = loaded_value;
    loaded_value = undefined;
    var presets_value = try harness.presets(null);
    const owner = try harness.owner(&loaded, &presets_value);
    defer owner.deinit();
    try std.testing.expect(loaded == null);
    const stable_document = owner.document();
    const empty: EmptyStore = .{};
    const store = Store.init(.{
        .file = stable_document,
        .registry = Store.SettingRegistry.from(&empty),
        .environment = Store.Environment.from(&empty),
    });

    var outcome = try owner.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .model = "mock-model",
        .effort = "high",
        .tint = "rose",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(SaveKind.saved, outcome.written);
    try std.testing.expect(stable_document == owner.document());
    try std.testing.expectEqual(@as(u64, 1), owner.generationValue());
    const plan = owner.lookup("review").plan;
    try std.testing.expectEqualStrings("mock", plan.provider);
    try std.testing.expectEqualStrings("mock-model", plan.model.value.?);
    try std.testing.expectEqualStrings("rose", plan.tint.value.?);
    var stored_provider = try store.read(std.testing.allocator, "presets.review.provider");
    defer stored_provider.deinit(std.testing.allocator);
    try std.testing.expectEqual(Store.Source.config, stored_provider.source);
    try std.testing.expectEqualStrings("mock", stored_provider.value.?);

    const bytes = try harness.directory.readFileAlloc(
        std.testing.io,
        "config.json",
        std.testing.allocator,
        .limited(maximum_file_bytes),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "  \"presets\": {\n" ++
            "    \"review\": {\n" ++
            "      \"tint\": \"rose\",\n" ++
            "      \"provider\": \"mock\",\n" ++
            "      \"model\": \"mock-model\",\n" ++
            "      \"effort\": \"high\"\n" ++
            "    }\n" ++
            "  }\n" ++
            "}",
        bytes,
    );
}

const FailingCommit = struct {
    fn makeParent(_: std.Io, _: ?*anyopaque, _: []const u8) OpsError!void {
        return error.Failed;
    }
};

fn exerciseConfigWriterAllocationFailures(allocator: std.mem.Allocator, harness: *TestHarness) !void {
    const path = try std.fs.path.join(allocator, &.{ harness.base, "allocation-config.json" });
    var result: ?Loader.Result = .{ .path = path, .outcome = .missing };
    defer if (result) |*value| value.deinit(allocator);
    var presets_value = try Preset.enumerate(
        allocator,
        std.testing.io,
        .{},
        .{ .secure_open = SecureOpen.Capability.from(&harness.access) },
    );
    var presets_owned = true;
    defer if (presets_owned) presets_value.deinit(allocator);
    const owner = try Owner.init(
        allocator,
        std.testing.io,
        &result,
        &presets_value,
        null,
        .{
            .secure_open = SecureOpen.Capability.from(&harness.access),
            .nonce_source = NonceSource.from(&harness.nonce),
            .commit_ops = .{ .make_parent_fn = FailingCommit.makeParent },
            .cwd = harness.base,
        },
    );
    presets_owned = false;
    defer owner.deinit();
    var outcome = try owner.savePreset(allocator, "review", .{
        .provider = "mock",
        .model = "mock-model",
        .effort = "high",
        .system_prompt = "instructions",
        .tint = "rose",
    });
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .failed);
}

test "config writer releases every allocation before failed commit" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseConfigWriterAllocationFailures,
        .{&harness},
    );
}

test "config writer preserves unknown roots and scalar description while replacing one preset" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    try harness.directory.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "{\"unknown\":42,\"presets.review\":{\"provider\":\"flat\"}," ++
            "\"presets\":{\"review\":{\"description\":false,\"provider\":\"old\",\"extra\":1}}}",
    });
    var loaded_value = try harness.load();
    var presets_value = try harness.presets(&loaded_value.document.?);
    var loaded: ?Loader.Result = loaded_value;
    loaded_value = undefined;
    const owner = try harness.owner(&loaded, &presets_value);
    defer owner.deinit();

    var outcome = try owner.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .model = "new-model",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(SaveKind.updated, outcome.written);
    try std.testing.expectEqual(@as(i64, 42), owner.document().lookup("unknown").?.integer);
    try std.testing.expect(owner.document().parsed.value.object.get("presets.review") == null);
    try std.testing.expectEqualStrings("0", owner.document().lookup("presets.review.description").?.string);
    try std.testing.expect(owner.document().lookup("presets.review.extra") == null);
    try std.testing.expect(owner.lookup("review") == .plan);
    const bytes = try harness.directory.readFileAlloc(
        std.testing.io,
        "config.json",
        std.testing.allocator,
        .limited(maximum_file_bytes),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "  \"unknown\": 42,\n" ++
            "  \"presets\": {\n" ++
            "    \"review\": {\n" ++
            "      \"description\": \"0\",\n" ++
            "      \"provider\": \"mock\",\n" ++
            "      \"model\": \"new-model\"\n" ++
            "    }\n" ++
            "  }\n" ++
            "}",
        bytes,
    );
}

test "config writer rejects malformed roots invalid prompts and oversized fields before commit" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    try harness.directory.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = "{\"presets\":1}" });
    var loaded_value = try harness.load();
    var presets_value = try harness.presets(&loaded_value.document.?);
    var loaded: ?Loader.Result = loaded_value;
    loaded_value = undefined;
    const malformed = try harness.owner(&loaded, &presets_value);
    defer malformed.deinit();
    var malformed_outcome = try malformed.savePreset(std.testing.allocator, "review", .{ .provider = "mock" });
    defer malformed_outcome.deinit(std.testing.allocator);
    try std.testing.expect(malformed_outcome == .malformed_presets);

    try harness.directory.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = "{}" });
    var clean_value = try harness.load();
    var clean_presets = try harness.presets(&clean_value.document.?);
    var clean_loaded: ?Loader.Result = clean_value;
    clean_value = undefined;
    const clean = try harness.owner(&clean_loaded, &clean_presets);
    defer clean.deinit();
    var invalid_outcome = try clean.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .system_prompt = "@missing",
    });
    defer invalid_outcome.deinit(std.testing.allocator);
    try std.testing.expect(invalid_outcome == .invalid);
    try std.testing.expectEqual(Preset.InvalidReason.prompt_read, invalid_outcome.invalid.reason);

    var oversized: [Document.maximum_string_bytes + 1]u8 = @splat('x');
    var large_outcome = try clean.savePreset(std.testing.allocator, "large", .{ .provider = &oversized });
    defer large_outcome.deinit(std.testing.allocator);
    try std.testing.expect(large_outcome == .too_large);
    try std.testing.expectEqual(@as(u64, 0), clean.generationValue());
}

test "config writer rejects external edits before publication" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    try harness.directory.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = "{}" });
    var loaded_value = try harness.load();
    var presets_value = try harness.presets(&loaded_value.document.?);
    var loaded: ?Loader.Result = loaded_value;
    loaded_value = undefined;
    const owner = try harness.owner(&loaded, &presets_value);
    defer owner.deinit();
    try harness.directory.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "{\"external\":true}",
    });

    var outcome = try owner.savePreset(std.testing.allocator, "review", .{ .provider = "mock" });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .conflict);
    try std.testing.expect(owner.lookup("review") == .missing);
    try std.testing.expectEqual(@as(u64, 0), owner.generationValue());
    const bytes = try harness.directory.readFileAlloc(
        std.testing.io,
        "config.json",
        std.testing.allocator,
        .limited(maximum_file_bytes),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"external\":true}", bytes);
}

test "config writer reports state shadow before missing config path" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    var state = try Document.parse(
        std.testing.allocator,
        "{\"presets\":{\"review\":{\"provider\":\"state\"}}}",
        .{},
    );
    defer state.deinit();
    var no_result: ?Loader.Result = null;
    var presets_value = try Preset.enumerate(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state },
        .{ .secure_open = SecureOpen.Capability.from(&harness.access) },
    );
    const owner = try Owner.init(
        std.testing.allocator,
        std.testing.io,
        &no_result,
        &presets_value,
        &state,
        .{ .secure_open = SecureOpen.Capability.from(&harness.access) },
    );
    defer owner.deinit();
    var invalid_tint = try owner.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .tint = "blue",
    });
    defer invalid_tint.deinit(std.testing.allocator);
    try std.testing.expectEqual(Preset.InvalidReason.invalid_tint, invalid_tint.invalid.reason);
    var outcome = try owner.savePreset(std.testing.allocator, "review", .{ .provider = "mock" });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .state_shadow);
}

test "config writer keeps no-path and unusable sources read only" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    var no_result: ?Loader.Result = null;
    var empty_presets = try harness.presets(null);
    const no_path = try harness.owner(&no_result, &empty_presets);
    defer no_path.deinit();
    var no_path_invalid = try no_path.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .tint = "blue",
    });
    defer no_path_invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(Preset.InvalidReason.invalid_tint, no_path_invalid.invalid.reason);
    var no_path_outcome = try no_path.savePreset(std.testing.allocator, "review", .{ .provider = "mock" });
    defer no_path_outcome.deinit(std.testing.allocator);
    try std.testing.expect(no_path_outcome == .no_path);

    try harness.directory.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = "{" });
    var invalid_value = try harness.load();
    var invalid: ?Loader.Result = invalid_value;
    invalid_value = undefined;
    var invalid_presets = try harness.presets(null);
    const unusable = try harness.owner(&invalid, &invalid_presets);
    defer unusable.deinit();
    var unusable_invalid = try unusable.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .tint = "blue",
    });
    defer unusable_invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(Preset.InvalidReason.invalid_tint, unusable_invalid.invalid.reason);
    var unusable_outcome = try unusable.savePreset(std.testing.allocator, "review", .{ .provider = "mock" });
    defer unusable_outcome.deinit(std.testing.allocator);
    try std.testing.expect(unusable_outcome == .unusable);
}

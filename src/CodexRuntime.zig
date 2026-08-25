const std = @import("std");
const ai = @import("ai/root.zig");
const persistence = @import("persistence/root.zig");
const CodexAuth = @import("CodexAuth.zig");
const CodexRefreshRotator = @import("CodexRefreshRotator.zig");

const CodexRuntime = @This();
const Credentials = ai.CodexCredentials;
const JsonTransport = ai.JsonTransport;
const CredentialStore = persistence.CredentialStore;
const PrivateFileStore = persistence.PrivateFileStore;

pub const CreateError = error{ OutOfMemory, InvalidStateRoot };

pub const CreateResult = union(enum) {
    ready: *Owner,
    failure: CodexAuth.InitFailure,
};

/// Heap-stable production composition for Codex credentials. The loader,
/// transport, nonce source, clock context, allocator, and I/O must outlive it.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: State,

    const Managed = struct {
        directory: std.Io.Dir,
        private_store: PrivateFileStore.Store,
        credential_store: CredentialStore.Store,
        refresh_rotator: CodexRefreshRotator,
        source: CodexAuth.ManagedSource,
    };

    const State = union(enum) {
        codex_cli: Credentials.BorrowedCliSource,
        managed: Managed,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        state_root: ?[]const u8,
        cli_loader: Credentials.Loader,
        transport: JsonTransport.Transport,
        nonce_source: PrivateFileStore.NonceSource,
        clock: CodexAuth.Clock,
    ) CreateError!CreateResult {
        if (state_root) |path| try validateStateRoot(path);

        const self = try allocator.create(Owner);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;

        const path = state_root orelse return self.initCli(cli_loader, .missing);
        const directory = std.Io.Dir.openDir(.cwd(), io, path, .{
            .follow_symlinks = false,
        }) catch return self.initCli(cli_loader, .unreadable);
        var directory_owned = true;
        errdefer if (directory_owned) directory.close(io);
        directory.setPermissions(io, .fromMode(0o700)) catch {
            directory_owned = false;
            return self.initCliAfterClose(cli_loader, directory, .unreadable);
        };

        self.state = .{ .managed = undefined };
        const managed = &self.state.managed;
        managed.directory = directory;
        directory_owned = false;
        errdefer managed.directory.close(io);
        managed.private_store = .init(io, managed.directory);
        managed.credential_store = .init(managed.private_store, nonce_source);
        managed.refresh_rotator = .init(transport);
        const initialized = try CodexAuth.ManagedSource.init(
            allocator,
            io,
            &managed.credential_store,
            cli_loader,
            clock,
            managed.refresh_rotator.rotator(),
        );
        switch (initialized) {
            .ready => |ready_source| {
                managed.source = ready_source;
                return .{ .ready = self };
            },
            .failure => |failure| {
                managed.directory.close(io);
                allocator.destroy(self);
                return .{ .failure = failure };
            },
        }
    }

    fn initCli(
        self: *Owner,
        cli_loader: Credentials.Loader,
        managed_status: Credentials.Status,
    ) error{OutOfMemory}!CreateResult {
        const initialized = try Credentials.BorrowedCliSource.init(
            self.allocator,
            self.io,
            cli_loader,
        );
        return switch (initialized) {
            .ready => |ready_source| ready: {
                self.state = .{ .codex_cli = ready_source };
                break :ready .{ .ready = self };
            },
            .failure => |status| failure: {
                const allocator = self.allocator;
                allocator.destroy(self);
                break :failure .{ .failure = .{
                    .managed = managed_status,
                    .codex_cli = status,
                } };
            },
        };
    }

    fn initCliAfterClose(
        self: *Owner,
        cli_loader: Credentials.Loader,
        directory: std.Io.Dir,
        managed_status: Credentials.Status,
    ) error{OutOfMemory}!CreateResult {
        directory.close(self.io);
        return self.initCli(cli_loader, managed_status);
    }

    /// No credential callback may be active during destruction.
    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        switch (self.state) {
            .codex_cli => |*cli_source| cli_source.deinit(),
            .managed => |*managed| {
                managed.source.deinit();
                managed.directory.close(self.io);
            },
        }
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn credentialSource(self: *Owner) ai.CodexCredentialSource {
        return switch (self.state) {
            .codex_cli => |*cli_source| cli_source.credentialSource(),
            .managed => |*managed| managed.source.credentialSource(),
        };
    }

    /// Reports the provenance of the credentials currently used. A managed
    /// runtime can report `.codex_cli` when canonical managed credentials were unusable.
    pub fn source(self: *const Owner) Credentials.Source {
        return switch (self.state) {
            .codex_cli => .codex_cli,
            .managed => |*managed| managed.source.source(),
        };
    }

    pub fn pinnedAccountId(self: *const Owner) []const u8 {
        return switch (self.state) {
            .codex_cli => |*cli_source| cli_source.pinned_account_id,
            .managed => |*managed| managed.source.pinnedAccountId(),
        };
    }

    /// Returns and clears publication state only for the managed composition.
    pub fn takePublicationOutcome(self: *Owner) ?CodexAuth.PublicationOutcome {
        return switch (self.state) {
            .codex_cli => null,
            .managed => |*managed| managed.source.takePublicationOutcome(),
        };
    }
};

fn validateStateRoot(path: []const u8) error{InvalidStateRoot}!void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes or
        !std.fs.path.isAbsolute(path) or std.mem.findScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path) or std.mem.eql(u8, path, "/"))
    {
        return error.InvalidStateRoot;
    }
}

const TestLoader = struct {
    value: Credentials.LoaderResult,

    pub fn load(
        self: *TestLoader,
        allocator: std.mem.Allocator,
        maximum_bytes: usize,
    ) error{OutOfMemory}!Credentials.LoaderResult {
        return switch (self.value) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes[0..@min(bytes.len, maximum_bytes)]) },
            .missing => .missing,
            .unreadable => .unreadable,
        };
    }
};

const TestTransport = struct {
    pub fn request(
        _: std.mem.Allocator,
        _: std.Io,
        _: *TestTransport,
        _: JsonTransport.Request,
    ) JsonTransport.Error!JsonTransport.Response {
        return error.ConnectionFailed;
    }
};

const TestNonce = struct {
    value: u8 = 0,

    fn source(self: *TestNonce) PrivateFileStore.NonceSource {
        return .{ .context = self, .fill_fn = fill };
    }

    fn fill(context: *anyopaque, bytes: []u8) PrivateFileStore.Error!void {
        const self: *TestNonce = @ptrCast(@alignCast(context));
        @memset(bytes, self.value);
        self.value +%= 1;
    }
};

const cli_json = "{\"tokens\":{\"access_token\":\"cli-access\",\"account_id\":\"cli-account\"}}";
const managed_file = "{\"codex\":{\"access_token\":\"managed-access\",\"refresh_token\":" ++
    "\"managed-refresh\",\"account_id\":\"managed-account\"}}";

fn createTestOwner(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    loader: *TestLoader,
    transport: *TestTransport,
    nonce: *TestNonce,
) !CreateResult {
    return Owner.create(
        allocator,
        std.testing.io,
        root,
        Credentials.Loader.from(loader),
        JsonTransport.Transport.from(transport),
        nonce.source(),
        .system,
    );
}

test "absent state root uses borrowed CLI without creating directories" {
    var loader: TestLoader = .{ .value = .{ .bytes = @constCast(cli_json) } };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    const result = try createTestOwner(std.testing.allocator, null, &loader, &transport, &nonce);
    const owner = switch (result) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer owner.deinit();
    try std.testing.expectEqual(Credentials.Source.codex_cli, owner.source());
    try std.testing.expectEqualStrings("cli-account", owner.pinnedAccountId());
    try std.testing.expectEqual(@as(?CodexAuth.PublicationOutcome, null), owner.takePublicationOutcome());
}

test "managed credentials take precedence and directory becomes private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = managed_file });
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o755));
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var loader: TestLoader = .{ .value = .{ .bytes = @constCast(cli_json) } };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    const result = try createTestOwner(std.testing.allocator, root, &loader, &transport, &nonce);
    const owner = switch (result) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer owner.deinit();
    try std.testing.expectEqual(Credentials.Source.managed, owner.source());
    try std.testing.expectEqualStrings("managed-account", owner.pinnedAccountId());
    try std.testing.expectEqual(CodexAuth.PublicationOutcome.none, owner.takePublicationOutcome().?);
    const stat = try tmp.dir.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);

    var acquired = try owner.credentialSource().acquire(std.testing.allocator, std.testing.io, null, .request);
    defer acquired.ready.deinit();
    try std.testing.expectEqualStrings("managed-account", acquired.ready.credential().account_id);
}

test "missing managed entry falls back to CLI inside stable managed owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var loader: TestLoader = .{ .value = .{ .bytes = @constCast(cli_json) } };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    const result = try createTestOwner(std.testing.allocator, root, &loader, &transport, &nonce);
    const owner = switch (result) {
        .ready => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer owner.deinit();
    try std.testing.expectEqual(Credentials.Source.codex_cli, owner.source());
    try std.testing.expect(owner.takePublicationOutcome() != null);
}

test "provided missing path is not created and reports managed unreadable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ base, "missing" });
    defer std.testing.allocator.free(missing);
    var loader: TestLoader = .{ .value = .missing };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    const result = try createTestOwner(std.testing.allocator, missing, &loader, &transport, &nonce);
    switch (result) {
        .ready => |owner| {
            owner.deinit();
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            try std.testing.expectEqual(Credentials.Status.unreadable, failure.managed);
            try std.testing.expectEqual(Credentials.Status.missing, failure.codex_cli);
        },
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "missing", .{}));
}

test "file and final symlink roots fall back to CLI" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "directory", .fromMode(0o700));
    try tmp.dir.symLink(std.testing.io, "directory", "link", .{});
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    inline for (.{ "file", "link" }) |name| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ base, name });
        defer std.testing.allocator.free(path);
        var loader: TestLoader = .{ .value = .{ .bytes = @constCast(cli_json) } };
        var transport: TestTransport = .{};
        var nonce: TestNonce = .{};
        const result = try createTestOwner(std.testing.allocator, path, &loader, &transport, &nonce);
        const owner = switch (result) {
            .ready => |value| value,
            .failure => return error.TestUnexpectedResult,
        };
        defer owner.deinit();
        try std.testing.expectEqual(Credentials.Source.codex_cli, owner.source());
    }
}

test "invalid provided state root is typed" {
    var loader: TestLoader = .{ .value = .missing };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    try std.testing.expectError(
        error.InvalidStateRoot,
        createTestOwner(std.testing.allocator, "relative", &loader, &transport, &nonce),
    );
}

fn exerciseOwnerAllocations(allocator: std.mem.Allocator) !void {
    var loader: TestLoader = .{ .value = .{ .bytes = @constCast(cli_json) } };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    const result = try createTestOwner(allocator, null, &loader, &transport, &nonce);
    switch (result) {
        .ready => |owner| owner.deinit(),
        .failure => return error.TestUnexpectedResult,
    }
}

test "owner releases every allocation on initialization OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnerAllocations, .{});
}

fn exerciseManagedOwnerAllocations(allocator: std.mem.Allocator, root: []const u8) !void {
    var loader: TestLoader = .{ .value = .{ .bytes = @constCast(cli_json) } };
    var transport: TestTransport = .{};
    var nonce: TestNonce = .{};
    const result = try createTestOwner(allocator, root, &loader, &transport, &nonce);
    switch (result) {
        .ready => |owner| owner.deinit(),
        .failure => return error.TestUnexpectedResult,
    }
}

test "managed owner releases every allocation on initialization OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = managed_file });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseManagedOwnerAllocations,
        .{root},
    );
}

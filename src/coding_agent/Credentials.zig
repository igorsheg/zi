const std = @import("std");
const builtin = @import("builtin");
const ai = @import("../ai/root.zig");
const BoundedJson = @import("../BoundedJson.zig");
const Model = @import("Model.zig");
const PrivateFileStore = @import("PrivateFileStore.zig");
const ZiPaths = @import("ZiPaths.zig");

pub const Store = struct {
    const credential = ai.credential;
    const auth_file_name = "auth.json";
    const lock_file_name = ".auth.lock";
    const max_document_bytes = 2 * 1024 * 1024;
    const max_provider_id_bytes = 256;
    pub const Boundary = PrivateFileStore.Boundary;
    pub const Faults = PrivateFileStore.Faults;

    pub const Error = error{
        OutOfMemory,
        InvalidCredentialFile,
        UnsupportedVersion,
        UnsafePath,
        ReadFailed,
        LockFailed,
        WriteFailed,
        CommitIndeterminate,
    };

    const Source = struct {
        version: u32,
        credentials: []const SourceEntry,
    };

    const SourceEntry = struct {
        provider_id: []const u8,
        type: enum { api_key, oauth },
        key: ?[]const u8 = null,
        access: ?[]const u8 = null,
        refresh: ?[]const u8 = null,
        expires_at_ms: ?u64 = null,
        account_id: ?[]const u8 = null,
    };

    pub const Snapshot = struct {
        arena: std.heap.ArenaAllocator,
        entries: []const credential.Entry,

        pub fn deinit(self: *Snapshot) void {
            wipeCredentials(self.entries);
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub const Mutation = struct {
        store: PrivateFileStore.Mutation,

        // ziglint-ignore: Z012 Z015 Z023
        pub fn deinit(self: *Mutation) void {
            self.store.deinit();
            self.* = undefined;
        }

        // ziglint-ignore: Z023 Z015 Z012
        pub fn load(self: *Mutation, allocator: std.mem.Allocator) Error!Snapshot {
            const source_text = self.store.readFileAlloc(
                allocator,
                auth_file_name,
                max_document_bytes,
            ) catch |failure| return mapReadFailure(failure);
            return decodeOptional(allocator, source_text);
        }

        // ziglint-ignore: Z012 Z015 Z023
        pub fn put(
            self: *Mutation,
            // ziglint-ignore: Z023
            allocator: std.mem.Allocator,
            entry: credential.Entry,
        ) Error!void {
            try validateEntry(entry);
            var current = try self.load(allocator);
            defer current.deinit();
            const replacing = find(current.entries, entry.provider_id);
            const count = current.entries.len + @intFromBool(replacing == null);
            if (count > credential.max_credentials) return error.InvalidCredentialFile;
            const updated = try allocator.alloc(credential.Entry, count);
            defer allocator.free(updated);
            var cursor: usize = 0;
            for (current.entries, 0..) |stored, index| {
                updated[cursor] = if (replacing == index) entry else stored;
                cursor += 1;
            }
            if (replacing == null) updated[cursor] = entry;

            try self.writeEntries(allocator, updated);
        }

        // ziglint-ignore: Z012 Z015 Z023
        pub fn remove(
            self: *Mutation,
            // ziglint-ignore: Z023
            allocator: std.mem.Allocator,
            provider_id: []const u8,
        ) Error!bool {
            var current = try self.load(allocator);
            defer current.deinit();
            const removing = find(current.entries, provider_id) orelse return false;
            const updated = try allocator.alloc(credential.Entry, current.entries.len - 1);
            defer allocator.free(updated);
            var cursor: usize = 0;
            for (current.entries, 0..) |entry, index| {
                if (index == removing) continue;
                updated[cursor] = entry;
                cursor += 1;
            }
            try self.writeEntries(allocator, updated);
            return true;
        }

        // ziglint-ignore: Z023
        fn writeEntries(self: *Mutation, allocator: std.mem.Allocator, entries: []const credential.Entry) Error!void {
            const encoded = try encode(allocator, entries);
            defer {
                std.crypto.secureZero(u8, encoded);
                allocator.free(encoded);
            }
            self.store.replace(auth_file_name, encoded) catch |failure| return mapWriteFailure(failure);
        }
    };

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
    ) Error!Snapshot {
        const source_text = PrivateFileStore.readFileAlloc(
            allocator,
            io,
            paths.home,
            paths.global_agent,
            auth_file_name,
            max_document_bytes,
        ) catch |failure| return mapReadFailure(failure);
        return decodeOptional(allocator, source_text);
    }

    pub fn beginMutation(io: std.Io, paths: *const ZiPaths) Error!Mutation {
        return beginMutationWithFaults(io, paths, .none());
    }

    fn beginMutationWithFaults(io: std.Io, paths: *const ZiPaths, faults: Faults) Error!Mutation {
        const store = PrivateFileStore.beginMutation(
            io,
            paths.home,
            paths.global_agent,
            lock_file_name,
            faults,
        ) catch |failure| return mapMutationFailure(failure);
        return .{ .store = store };
    }

    // ziglint-ignore: Z023
    pub fn put(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        entry: credential.Entry,
    ) Error!void {
        var mutation = try beginMutation(io, paths);
        defer mutation.deinit();
        return mutation.put(allocator, entry);
    }

    pub fn remove(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        provider_id: []const u8,
    ) Error!bool {
        var mutation = try beginMutation(io, paths);
        defer mutation.deinit();
        return mutation.remove(allocator, provider_id);
    }

    fn decodeOptional(allocator: std.mem.Allocator, maybe_source_text: ?[]u8) Error!Snapshot {
        const source_text = maybe_source_text orelse return empty(allocator);
        defer {
            std.crypto.secureZero(u8, source_text);
            allocator.free(source_text);
        }
        if (source_text.len > max_document_bytes) return error.InvalidCredentialFile;
        return decode(allocator, source_text);
    }

    fn mapReadFailure(failure: PrivateFileStore.Error) Error {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsafePath => error.UnsafePath,
            else => error.ReadFailed,
        };
    }

    fn mapMutationFailure(failure: PrivateFileStore.Error) Error {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsafePath => error.UnsafePath,
            else => error.LockFailed,
        };
    }

    fn mapWriteFailure(failure: PrivateFileStore.Error) Error {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsafePath => error.UnsafePath,
            error.CommitIndeterminate => error.CommitIndeterminate,
            else => error.WriteFailed,
        };
    }

    pub fn empty(allocator: std.mem.Allocator) Error!Snapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        return .{ .arena = arena, .entries = try arena.allocator().alloc(credential.Entry, 0) };
    }

    fn decode(allocator: std.mem.Allocator, source_text: []const u8) Error!Snapshot {
        BoundedJson.validate(allocator, source_text, .{
            .document_bytes = max_document_bytes,
            .value_bytes = credential.max_secret_bytes,
            .depth = 4,
            .collection_items = credential.max_credentials * 8,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidCredentialFile,
        };
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const source = std.json.parseFromSliceLeaky(Source, arena.allocator(), source_text, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
            .max_value_len = credential.max_secret_bytes,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidCredentialFile,
        };
        if (source.version != 1) return error.UnsupportedVersion;
        if (source.credentials.len > credential.max_credentials) return error.InvalidCredentialFile;
        const entries = try arena.allocator().alloc(credential.Entry, source.credentials.len);
        for (source.credentials, entries, 0..) |item, *entry, index| {
            entry.* = .{
                .provider_id = item.provider_id,
                .credential = switch (item.type) {
                    .api_key => .{ .api_key = .{ .key = item.key orelse return error.InvalidCredentialFile } },
                    .oauth => .{ .oauth = .{
                        .access = item.access orelse return error.InvalidCredentialFile,
                        .refresh = item.refresh orelse return error.InvalidCredentialFile,
                        .expires_at_ms = item.expires_at_ms orelse return error.InvalidCredentialFile,
                        .account_id = item.account_id,
                    } },
                },
            };
            if (item.type == .api_key and
                (item.access != null or item.refresh != null or item.expires_at_ms != null or item.account_id != null))
            {
                return error.InvalidCredentialFile;
            }
            if (item.type == .oauth and item.key != null) return error.InvalidCredentialFile;
            try validateEntry(entry.*);
            for (entries[0..index]) |previous| {
                if (std.mem.eql(u8, previous.provider_id, entry.provider_id)) return error.InvalidCredentialFile;
            }
        }
        return .{ .arena = arena, .entries = entries };
    }

    fn encode(allocator: std.mem.Allocator, entries: []const credential.Entry) Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer };
        json.beginObject() catch return error.OutOfMemory;
        try writeField(&json, "version", @as(u32, 1));
        json.objectField("credentials") catch return error.OutOfMemory;
        json.beginArray() catch return error.OutOfMemory;
        for (entries) |entry| {
            try validateEntry(entry);
            json.beginObject() catch return error.OutOfMemory;
            try writeField(&json, "provider_id", entry.provider_id);
            switch (entry.credential) {
                .api_key => |api_key| {
                    try writeField(&json, "type", "api_key");
                    try writeField(&json, "key", api_key.key);
                },
                .oauth => |oauth| {
                    try writeField(&json, "type", "oauth");
                    try writeField(&json, "access", oauth.access);
                    try writeField(&json, "refresh", oauth.refresh);
                    try writeField(&json, "expires_at_ms", oauth.expires_at_ms);
                    if (oauth.account_id) |account_id| try writeField(&json, "account_id", account_id);
                },
            }
            json.endObject() catch return error.OutOfMemory;
        }
        json.endArray() catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
        const encoded = output.toOwnedSlice() catch return error.OutOfMemory;
        if (encoded.len > max_document_bytes) {
            std.crypto.secureZero(u8, encoded);
            allocator.free(encoded);
            return error.InvalidCredentialFile;
        }
        return encoded;
    }

    fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) Error!void {
        json.objectField(name) catch return error.OutOfMemory;
        json.write(value) catch return error.OutOfMemory;
    }

    fn validateEntry(entry: credential.Entry) Error!void {
        if (entry.provider_id.len == 0 or entry.provider_id.len > max_provider_id_bytes or
            !std.unicode.utf8ValidateSlice(entry.provider_id) or
            std.mem.indexOfScalar(u8, entry.provider_id, 0) != null)
        {
            return error.InvalidCredentialFile;
        }
        switch (entry.credential) {
            .api_key => |api_key| try validateSecret(api_key.key),
            .oauth => |oauth| {
                try validateSecret(oauth.access);
                try validateSecret(oauth.refresh);
                if (oauth.account_id) |account_id| try validateSecret(account_id);
            },
        }
    }

    fn validateSecret(value: []const u8) Error!void {
        if (value.len == 0 or value.len > credential.max_secret_bytes or
            !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
        {
            return error.InvalidCredentialFile;
        }
    }

    fn find(entries: []const credential.Entry, provider_id: []const u8) ?usize {
        for (entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.provider_id, provider_id)) return index;
        }
        return null;
    }

    fn wipeCredentials(entries: []const credential.Entry) void {
        for (entries) |entry| switch (entry.credential) {
            .api_key => |api_key| std.crypto.secureZero(u8, @constCast(api_key.key)),
            .oauth => |oauth| {
                std.crypto.secureZero(u8, @constCast(oauth.access));
                std.crypto.secureZero(u8, @constCast(oauth.refresh));
                if (oauth.account_id) |account_id| std.crypto.secureZero(u8, @constCast(account_id));
            },
        };
    }

    fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
        const length = try temporary.dir.realPath(std.testing.io, buffer);
        return buffer[0..length];
    }

    test "credential store atomically inserts and replaces provider credentials" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();

        var empty_snapshot = try load(std.testing.allocator, std.testing.io, &paths);
        defer empty_snapshot.deinit();
        try std.testing.expectEqual(@as(usize, 0), empty_snapshot.entries.len);

        try put(std.testing.allocator, std.testing.io, &paths, .{
            .provider_id = "provider-a",
            .credential = .{ .api_key = .{ .key = "first-secret" } },
        });
        try put(std.testing.allocator, std.testing.io, &paths, .{
            .provider_id = "provider-b",
            .credential = .{ .oauth = .{
                .access = "access-token",
                .refresh = "refresh-token",
                .expires_at_ms = 42,
                .account_id = "account-id",
            } },
        });
        try put(std.testing.allocator, std.testing.io, &paths, .{
            .provider_id = "provider-a",
            .credential = .{ .api_key = .{ .key = "replacement-secret" } },
        });

        var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
        defer snapshot.deinit();
        try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
        try std.testing.expectEqualStrings("replacement-secret", snapshot.entries[0].credential.api_key.key);
        try std.testing.expectEqualStrings("access-token", snapshot.entries[1].credential.oauth.access);
        try std.testing.expectEqualStrings("refresh-token", snapshot.entries[1].credential.oauth.refresh);

        var agent_directory = try std.Io.Dir.openDirAbsolute(std.testing.io, paths.global_agent, .{});
        defer agent_directory.close(std.testing.io);
        const file = try agent_directory.openFile(std.testing.io, auth_file_name, .{
            .mode = .read_only,
            .allow_directory = false,
        });
        defer file.close(std.testing.io);
        const stat = try file.stat(std.testing.io);
        if (comptime builtin.os.tag != .windows) {
            try std.testing.expectEqual(@as(u16, 0), stat.permissions.toMode() & 0o077);
        }
        const encoded = try agent_directory.readFileAlloc(
            std.testing.io,
            auth_file_name,
            std.testing.allocator,
            .limited(max_document_bytes),
        );
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "first-secret") == null);

        try std.testing.expect(try remove(
            std.testing.allocator,
            std.testing.io,
            &paths,
            "provider-a",
        ));
        try std.testing.expect(!try remove(
            std.testing.allocator,
            std.testing.io,
            &paths,
            "provider-a",
        ));
        var after_remove = try load(std.testing.allocator, std.testing.io, &paths);
        defer after_remove.deinit();
        try std.testing.expectEqual(@as(usize, 1), after_remove.entries.len);
        try std.testing.expectEqualStrings("provider-b", after_remove.entries[0].provider_id);
    }

    test "credential store distinguishes failed and indeterminate replacement boundaries" {
        const Fault = struct {
            const Self = @This();
            fail_at: Boundary,

            fn boundary(context: *anyopaque, point: Boundary) anyerror!void {
                const self: *Self = @ptrCast(@alignCast(context));
                if (point == self.fail_at) return error.Injected;
            }

            // ziglint-ignore: Z020
            fn faults(self: *Self) Faults {
                // Self declared below if needed
                return .{ .context = self, .boundary_fn = boundary };
            }
        };
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        try put(std.testing.allocator, std.testing.io, &paths, .{
            .provider_id = "provider",
            .credential = .{ .api_key = .{ .key = "original" } },
        });

        var before_replace: Fault = .{ .fail_at = .after_write };
        var failed = try beginMutationWithFaults(std.testing.io, &paths, before_replace.faults());
        try std.testing.expectError(error.WriteFailed, failed.put(std.testing.allocator, .{
            .provider_id = "provider",
            .credential = .{ .api_key = .{ .key = "not-committed" } },
        }));
        failed.deinit();
        var original = try load(std.testing.allocator, std.testing.io, &paths);
        try std.testing.expectEqualStrings("original", original.entries[0].credential.api_key.key);
        original.deinit();

        var after_replace: Fault = .{ .fail_at = .after_replace };
        var indeterminate = try beginMutationWithFaults(std.testing.io, &paths, after_replace.faults());
        try std.testing.expectError(error.CommitIndeterminate, indeterminate.put(std.testing.allocator, .{
            .provider_id = "provider",
            .credential = .{ .api_key = .{ .key = "published" } },
        }));
        indeterminate.deinit();
        var published = try load(std.testing.allocator, std.testing.io, &paths);
        defer published.deinit();
        try std.testing.expectEqualStrings("published", published.entries[0].credential.api_key.key);
    }

    test "credential store rejects unknown fields and unsupported versions" {
        try std.testing.expectError(error.InvalidCredentialFile, decode(
            std.testing.allocator,
            "{\"version\":1,\"credentials\":[],\"unknown\":true}",
        ));
        try std.testing.expectError(error.UnsupportedVersion, decode(
            std.testing.allocator,
            "{\"version\":2,\"credentials\":[]}",
        ));
        const mixed_fields =
            \\{"version":1,"credentials":[
            \\  {"provider_id":"p","type":"api_key","key":"k","access":"mixed"}
            \\]}
        ;
        try std.testing.expectError(
            error.InvalidCredentialFile,
            decode(std.testing.allocator, mixed_fields),
        );
    }

    test "credential snapshot wipes parsed secrets" {
        const backing = try std.testing.allocator.alloc(u8, 4096);
        defer std.testing.allocator.free(backing);
        @memset(backing, 0xa5);
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const encoded =
            \\{"version":1,"credentials":[
            \\  {"provider_id":"p","type":"oauth","access":"wipe-access",
            \\   "refresh":"wipe-refresh","expires_at_ms":1,"account_id":"wipe-account"}
            \\]}
        ;
        var snapshot = try decode(fixed.allocator(), encoded);
        const oauth = snapshot.entries[0].credential.oauth;
        const secrets = [_][]const u8{ oauth.access, oauth.refresh, oauth.account_id.? };
        var offsets: [secrets.len]usize = undefined;
        var lengths: [secrets.len]usize = undefined;
        for (secrets, 0..) |secret, index| {
            offsets[index] = @intFromPtr(secret.ptr) - @intFromPtr(backing.ptr);
            lengths[index] = secret.len;
        }
        snapshot.deinit();
        for (offsets, lengths) |offset, length| {
            for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
};

pub const Manager = struct {
    const CredentialStore = Store;

    pub const Error = error{
        OutOfMemory,
        InvalidCredentialFile,
        UnsupportedVersion,
        UnsafePath,
        ReadFailed,
        LockFailed,
        WriteFailed,
        CommitIndeterminate,
        Cancelled,
        TimedOut,
        InvalidUrl,
        InvalidRequest,
        ConnectionFailed,
        InvalidResponse,
        ResponseTooLarge,
        ConsumerStopped,
        Rejected,
        InvalidModelConfiguration,
        AuthenticationUnavailable,
        RefreshUnavailable,
    };

    pub const LoginInputs = struct {
        provider_id: []const u8,
        method: ai.oauth.LoginMethod,
        interaction: ai.oauth.Interaction,
        now_ms: u64,
        cancellation: ?*const ai.model.CancellationToken = null,
    };

    pub const PersistentResolver = struct {
        allocator: std.mem.Allocator,
        paths: ZiPaths,
        // ziglint-ignore: Z012
        model_config: Model.Config,
        selection: ai.ModelIdentity,
        explicit_api_key: ?[]const u8,
        environment: ai.auth.Environment,
        clock_context: *anyopaque,
        now_ms_fn: *const fn (*anyopaque) u64,
        current: ?CredentialStore.Snapshot = null,

        // ziglint-ignore: Z012
        pub fn init(
            allocator: std.mem.Allocator,
            cwd: []const u8,
            home: []const u8,
            // ziglint-ignore: Z012
            model_config: Model.Config,
            selection: ai.ModelIdentity,
            explicit_api_key: ?[]const u8,
            environment: ai.auth.Environment,
            clock_context: *anyopaque,
            now_ms_fn: *const fn (*anyopaque) u64,
        ) !*PersistentResolver {
            const self = try allocator.create(PersistentResolver);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .paths = try ZiPaths.init(allocator, cwd, home),
                .model_config = model_config,
                .selection = selection,
                .explicit_api_key = explicit_api_key,
                .environment = environment,
                .clock_context = clock_context,
                .now_ms_fn = now_ms_fn,
            };
            return self;
        }

        // Heap destruction follows explicit field invalidation.
        // ziglint-ignore: Z030
        pub fn deinit(self: *PersistentResolver) void {
            const allocator = self.allocator;
            if (self.current) |*snapshot| snapshot.deinit();
            self.paths.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn resolver(self: *PersistentResolver) ai.auth.Resolver {
            return .{ .context = self, .resolve_fn = resolve };
        }

        // Context leads because this callback implements the erased resolver ABI.
        // ziglint-ignore: Z023
        fn resolve(
            context: *anyopaque,
            _: std.mem.Allocator, // ziglint-ignore: Z023
            _: std.mem.Allocator, // ziglint-ignore: Z023
            io: std.Io, // ziglint-ignore: Z023
            transport: ai.transport.Transport,
            control: ai.auth.RequestControl,
            policy: ai.auth.ProviderAuth,
            provider_id: []const u8,
            _: ai.auth.Inputs,
        ) ai.auth.ResolverError!ai.ModelAuth {
            const self: *PersistentResolver = @ptrCast(@alignCast(context));
            if (self.current) |*snapshot| snapshot.deinit();
            self.current = null;
            self.current = loadForRuntime(
                self.allocator,
                io,
                &self.paths,
                transport,
                .{
                    .model_config = self.model_config,
                    .selection = self.selection,
                    .explicit_api_key = self.explicit_api_key,
                    .now_ms = self.now_ms_fn(self.clock_context),
                    .cancellation = control.cancellation,
                    .deadline = control.deadline,
                },
            ) catch |failure| return mapResolverFailure(failure);
            return ai.auth.resolve(policy, provider_id, .{
                .explicit_api_key = self.explicit_api_key,
                .stored = self.current.?.entries,
                .environment = self.environment,
            }) catch return error.InvalidRequest;
        }
    };

    pub const Inputs = struct {
        // ziglint-ignore: Z012
        model_config: Model.Config,
        selection: ai.ModelIdentity,
        explicit_api_key: ?[]const u8 = null,
        now_ms: u64,
        cancellation: ?*const ai.model.CancellationToken = null,
        deadline: ?std.Io.Clock.Timestamp = null,
    };

    pub fn login(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        transport: ai.transport.Transport,
        // ziglint-ignore: Z012
        model_config: Model.Config,
        inputs: LoginInputs,
    ) Error!void {
        const provider = model_config.findProvider(inputs.provider_id) orelse
            return error.InvalidModelConfiguration;
        const oauth_policy = provider.auth.oauth orelse return error.InvalidModelConfiguration;
        const authenticator = oauth_policy.authenticator orelse return error.AuthenticationUnavailable;
        var authenticated = try authenticator.login(
            allocator,
            allocator,
            io,
            transport,
            .{
                .method = inputs.method,
                .interaction = inputs.interaction,
                .now_ms = inputs.now_ms,
                .cancellation = inputs.cancellation,
            },
        );
        defer authenticated.deinit();
        try CredentialStore.put(allocator, io, paths, .{
            .provider_id = provider.id,
            .credential = .{ .oauth = authenticated.credential },
        });
    }

    pub fn logout(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        provider_id: []const u8,
    ) Error!bool {
        return CredentialStore.remove(allocator, io, paths, provider_id);
    }

    pub fn loadForRuntime(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        transport: ai.transport.Transport,
        inputs: Inputs,
    ) Error!CredentialStore.Snapshot {
        if (inputs.explicit_api_key != null) return CredentialStore.empty(allocator);
        var snapshot = try CredentialStore.load(allocator, io, paths);
        var snapshot_live = true;
        errdefer if (snapshot_live) snapshot.deinit();
        if (!needsRefresh(snapshot.entries, inputs)) return snapshot;
        snapshot.deinit();
        snapshot_live = false;

        var mutation = try CredentialStore.beginMutation(io, paths);
        defer mutation.deinit();
        var current = try mutation.load(allocator);
        defer current.deinit();
        if (!needsRefresh(current.entries, inputs)) {
            return mutation.load(allocator);
        }

        const selected = inputs.model_config.resolve(inputs.selection) orelse
            return error.InvalidModelConfiguration;
        const provider = inputs.model_config.findProvider(selected.providerId()) orelse
            return error.InvalidModelConfiguration;
        const oauth_policy = provider.auth.oauth orelse return error.InvalidModelConfiguration;
        const refresher = oauth_policy.refresher orelse return error.RefreshUnavailable;
        const stored = findCredential(current.entries, provider.id) orelse
            return error.InvalidModelConfiguration;
        const existing = switch (stored) {
            .oauth => |oauth| oauth,
            .api_key => return error.InvalidModelConfiguration,
        };

        var refreshed = try refresher.refresh(
            allocator,
            allocator,
            io,
            transport,
            .{
                .credential = existing,
                .now_ms = inputs.now_ms,
                .cancellation = inputs.cancellation,
                .deadline = inputs.deadline,
            },
        );
        defer refreshed.deinit();
        try mutation.put(allocator, .{
            .provider_id = provider.id,
            .credential = .{ .oauth = refreshed.credential },
        });
        return mutation.load(allocator);
    }

    fn mapResolverFailure(failure: Error) ai.auth.ResolverError {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.TimedOut => error.TimedOut,
            error.InvalidCredentialFile,
            error.UnsupportedVersion,
            error.InvalidModelConfiguration,
            error.AuthenticationUnavailable,
            error.RefreshUnavailable,
            error.InvalidUrl,
            error.InvalidRequest,
            => error.InvalidRequest,
            error.UnsafePath,
            error.ReadFailed,
            error.LockFailed,
            error.WriteFailed,
            error.CommitIndeterminate,
            error.ConnectionFailed,
            error.InvalidResponse,
            error.ResponseTooLarge,
            error.ConsumerStopped,
            error.Rejected,
            => error.ProviderUnavailable,
        };
    }

    test "resolver failure mapping preserves control and classifies local versus operational failures" {
        const cases = [_]struct { source: Error, expected: ai.auth.ResolverError }{
            .{ .source = error.OutOfMemory, .expected = error.OutOfMemory },
            .{ .source = error.Cancelled, .expected = error.Cancelled },
            .{ .source = error.TimedOut, .expected = error.TimedOut },
            .{ .source = error.InvalidCredentialFile, .expected = error.InvalidRequest },
            .{ .source = error.UnsupportedVersion, .expected = error.InvalidRequest },
            .{ .source = error.InvalidModelConfiguration, .expected = error.InvalidRequest },
            .{ .source = error.AuthenticationUnavailable, .expected = error.InvalidRequest },
            .{ .source = error.RefreshUnavailable, .expected = error.InvalidRequest },
            .{ .source = error.InvalidUrl, .expected = error.InvalidRequest },
            .{ .source = error.InvalidRequest, .expected = error.InvalidRequest },
            .{ .source = error.UnsafePath, .expected = error.ProviderUnavailable },
            .{ .source = error.ReadFailed, .expected = error.ProviderUnavailable },
            .{ .source = error.LockFailed, .expected = error.ProviderUnavailable },
            .{ .source = error.WriteFailed, .expected = error.ProviderUnavailable },
            .{ .source = error.CommitIndeterminate, .expected = error.ProviderUnavailable },
            .{ .source = error.ConnectionFailed, .expected = error.ProviderUnavailable },
            .{ .source = error.InvalidResponse, .expected = error.ProviderUnavailable },
            .{ .source = error.ResponseTooLarge, .expected = error.ProviderUnavailable },
            .{ .source = error.ConsumerStopped, .expected = error.ProviderUnavailable },
            .{ .source = error.Rejected, .expected = error.ProviderUnavailable },
        };
        for (cases) |case| try std.testing.expectEqual(case.expected, mapResolverFailure(case.source));
    }

    fn needsRefresh(entries: []const ai.credential.Entry, inputs: Inputs) bool {
        const selected = inputs.model_config.resolve(inputs.selection) orelse return false;
        const provider = inputs.model_config.findProvider(selected.providerId()) orelse return false;
        const oauth_policy = provider.auth.oauth orelse return false;
        const stored = findCredential(entries, provider.id) orelse return false;
        const oauth = switch (stored) {
            .oauth => |value| value,
            .api_key => return false,
        };
        const refresh_at = oauth.expires_at_ms -| oauth_policy.refresh_skew_ms;
        return refresh_at <= inputs.now_ms;
    }

    fn findCredential(entries: []const ai.credential.Entry, provider_id: []const u8) ?ai.Credential {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.provider_id, provider_id)) return entry.credential;
        }
        return null;
    }

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

    test "expired Codex credentials refresh and persist under one store mutation" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, .{
            .provider_id = "openai-codex",
            .credential = .{ .oauth = .{
                .access = "expired-access",
                .refresh = "old-refresh",
                .expires_at_ms = 100,
                .account_id = "old-account",
            } },
        });

        const access = try testAccessToken(std.testing.allocator, "new-account");
        defer std.testing.allocator.free(access);
        const response_body = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"access_token\":\"{s}\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}}",
            .{access},
        );
        defer std.testing.allocator.free(response_body);
        const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{
            .status = 200,
            .body = response_body,
        } }};
        var fake = ai.transport_testing.FakeTransport.init(&exchanges);
        var snapshot = try loadForRuntime(
            std.testing.allocator,
            std.testing.io,
            &paths,
            fake.transport(),
            .{
                .model_config = Model.Config.builtin,
                .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
                .now_ms = 1000,
            },
        );
        defer snapshot.deinit();

        try std.testing.expectEqual(@as(usize, 1), snapshot.entries.len);
        const refreshed = snapshot.entries[0].credential.oauth;
        try std.testing.expectEqualStrings(access, refreshed.access);
        try std.testing.expectEqualStrings("new-refresh", refreshed.refresh);
        try std.testing.expectEqualStrings("new-account", refreshed.account_id.?);
        try std.testing.expectEqual(@as(u64, 3_601_000), refreshed.expires_at_ms);
        try std.testing.expectEqual(@as(usize, 1), fake.next_index);
    }

    test "failed OAuth refresh preserves the stored credential" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, .{
            .provider_id = "openai-codex",
            .credential = .{ .oauth = .{
                .access = "expired-access",
                .refresh = "preserved-refresh",
                .expires_at_ms = 1,
                .account_id = "preserved-account",
            } },
        });
        const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{
            .status = 400,
            .body = "{\"error\":\"invalid_grant\"}",
        } }};
        var fake = ai.transport_testing.FakeTransport.init(&exchanges);
        try std.testing.expectError(error.Rejected, loadForRuntime(
            std.testing.allocator,
            std.testing.io,
            &paths,
            fake.transport(),
            .{
                .model_config = Model.Config.builtin,
                .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
                .now_ms = 1000,
            },
        ));
        var stored = try CredentialStore.load(std.testing.allocator, std.testing.io, &paths);
        defer stored.deinit();
        const oauth = stored.entries[0].credential.oauth;
        try std.testing.expectEqualStrings("expired-access", oauth.access);
        try std.testing.expectEqualStrings("preserved-refresh", oauth.refresh);
        try std.testing.expectEqualStrings("preserved-account", oauth.account_id.?);
    }

    test "refresh control failures preserve stored OAuth credentials" {
        const FailingTransport = struct {
            const Self = @This();

            failure: ai.transport.Error,
            saw_cancellation: bool = false,
            saw_deadline: bool = false,

            pub fn exchange(
                self: *Self,
                _: std.mem.Allocator,
                _: std.Io,
                request: ai.transport.Request,
                _: ai.transport.Delivery,
            ) ai.transport.Error!ai.transport.Response {
                self.saw_cancellation = request.cancellation != null;
                self.saw_deadline = request.deadline != null;
                return self.failure;
            }
        };
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        const stored: ai.credential.Entry = .{
            .provider_id = "openai-codex",
            .credential = .{ .oauth = .{
                .access = "expired-access",
                .refresh = "preserved-refresh",
                .expires_at_ms = 1,
                .account_id = "preserved-account",
            } },
        };
        try CredentialStore.put(std.testing.allocator, std.testing.io, &paths, stored);

        var cancellation: ai.model.CancellationToken = .{};
        cancellation.cancel();
        var cancelled_transport: FailingTransport = .{ .failure = error.Cancelled };
        try std.testing.expectError(error.Cancelled, loadForRuntime(
            std.testing.allocator,
            std.testing.io,
            &paths,
            ai.transport.Transport.from(&cancelled_transport),
            .{
                .model_config = Model.Config.builtin,
                .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
                .now_ms = 1000,
                .cancellation = &cancellation,
            },
        ));
        try std.testing.expect(cancelled_transport.saw_cancellation);

        var deadline_transport: FailingTransport = .{ .failure = error.TimedOut };
        try std.testing.expectError(error.TimedOut, loadForRuntime(
            std.testing.allocator,
            std.testing.io,
            &paths,
            ai.transport.Transport.from(&deadline_transport),
            .{
                .model_config = Model.Config.builtin,
                .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
                .now_ms = 1000,
                .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
                    .raw = .fromMilliseconds(0),
                    .clock = .awake,
                }),
            },
        ));
        try std.testing.expect(deadline_transport.saw_deadline);

        var after = try CredentialStore.load(std.testing.allocator, std.testing.io, &paths);
        defer after.deinit();
        try std.testing.expectEqualStrings("expired-access", after.entries[0].credential.oauth.access);
        try std.testing.expectEqualStrings("preserved-refresh", after.entries[0].credential.oauth.refresh);
        try std.testing.expectEqualStrings("preserved-account", after.entries[0].credential.oauth.account_id.?);
    }

    test "fresh OAuth credentials do not contact the refresh transport" {
        const entries = [_]ai.credential.Entry{.{
            .provider_id = "openai-codex",
            .credential = .{ .oauth = .{
                .access = "fresh-access",
                .refresh = "fresh-refresh",
                .expires_at_ms = 1_000_000,
            } },
        }};
        try std.testing.expect(!needsRefresh(&entries, .{
            .model_config = Model.Config.builtin,
            .selection = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" },
            .now_ms = 1000,
        }));
    }
};

pub const AuthOperation = struct {
    const CredentialManager = Manager;
    pub const ModelConfigSnapshot = Model.Snapshot;
    pub const Limits = struct {
        max_facts: usize = 16,
        max_fact_bytes: usize = 16 * 1024,
        max_queued_fact_bytes: usize = 64 * 1024,
        max_answer_bytes: usize = 64 * 1024,
    };

    pub const StartError = error{
        OutOfMemory,
        InvalidPath,
        Cancelled,
        InvalidLimits,
        ThreadQuotaExceeded,
        SystemResources,
        LockedMemoryLimitExceeded,
        Unexpected,
    };

    pub const AnswerError = error{
        OutOfMemory,
        EmptyAnswer,
        AnswerTooLarge,
        NotAwaitingAnswer,
        Cancelled,
    };

    pub const Failure = enum {
        out_of_memory,
        invalid_credential_file,
        unsupported_version,
        unsafe_path,
        read_failed,
        lock_failed,
        write_failed,
        commit_indeterminate,
        timed_out,
        invalid_url,
        invalid_request,
        connection_failed,
        invalid_response,
        response_too_large,
        consumer_stopped,
        rejected,
        invalid_model_configuration,
        authentication_unavailable,
        refresh_unavailable,
    };

    pub const Outcome = union(enum) {
        succeeded,
        cancelled,
        failed: Failure,
    };

    /// Every string borrows an AuthOperation batch for the synchronous sink call.
    pub const Fact = union(enum) {
        auth_url: struct {
            url: []const u8,
            instructions: []const u8,
        },
        device_code: struct {
            user_code: []const u8,
            verification_uri: []const u8,
            interval_seconds: u64,
            expires_in_seconds: u64,
        },
        prompt: struct {
            message: []const u8,
            placeholder: ?[]const u8,
        },
    };

    const OwnedFact = union(enum) {
        auth_url: struct {
            url: []u8,
            instructions: []u8,
        },
        device_code: struct {
            user_code: []u8,
            verification_uri: []u8,
            interval_seconds: u64,
            expires_in_seconds: u64,
        },
        prompt: struct {
            message: []u8,
            placeholder: ?[]u8,
        },

        fn initEvent(
            allocator: std.mem.Allocator,
            event: ai.oauth.Event,
            max_bytes: usize,
        ) error{ OutOfMemory, FactTooLarge }!OwnedFact {
            return switch (event) {
                .auth_url => |value| result: {
                    try admitFactBytes(max_bytes, &.{ value.url, value.instructions });
                    const url = try allocator.dupe(u8, value.url);
                    errdefer allocator.free(url);
                    break :result .{ .auth_url = .{
                        .url = url,
                        .instructions = try allocator.dupe(u8, value.instructions),
                    } };
                },
                .device_code => |value| result: {
                    try admitFactBytes(max_bytes, &.{ value.user_code, value.verification_uri });
                    const user_code = try allocator.dupe(u8, value.user_code);
                    errdefer allocator.free(user_code);
                    break :result .{ .device_code = .{
                        .user_code = user_code,
                        .verification_uri = try allocator.dupe(u8, value.verification_uri),
                        .interval_seconds = value.interval_seconds,
                        .expires_in_seconds = value.expires_in_seconds,
                    } };
                },
            };
        }

        fn initPrompt(
            allocator: std.mem.Allocator,
            request: ai.oauth.Prompt,
            max_bytes: usize,
        ) error{ OutOfMemory, FactTooLarge }!OwnedFact {
            try admitFactBytes(max_bytes, &.{ request.message, request.placeholder orelse "" });
            const message = try allocator.dupe(u8, request.message);
            errdefer allocator.free(message);
            return .{ .prompt = .{
                .message = message,
                .placeholder = if (request.placeholder) |value| try allocator.dupe(u8, value) else null,
            } };
        }

        fn view(self: *const OwnedFact) Fact {
            return switch (self.*) {
                .auth_url => |value| .{ .auth_url = .{
                    .url = value.url,
                    .instructions = value.instructions,
                } },
                .device_code => |value| .{ .device_code = .{
                    .user_code = value.user_code,
                    .verification_uri = value.verification_uri,
                    .interval_seconds = value.interval_seconds,
                    .expires_in_seconds = value.expires_in_seconds,
                } },
                .prompt => |value| .{ .prompt = .{
                    .message = value.message,
                    .placeholder = value.placeholder,
                } },
            };
        }

        fn retainedBytes(self: *const OwnedFact) usize {
            return switch (self.*) {
                .auth_url => |value| value.url.len + value.instructions.len,
                .device_code => |value| value.user_code.len + value.verification_uri.len,
                .prompt => |value| value.message.len + if (value.placeholder) |text| text.len else 0,
            };
        }

        // ziglint-ignore: Z023
        fn deinit(self: *OwnedFact, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .auth_url => |value| {
                    allocator.free(value.instructions);
                    allocator.free(value.url);
                },
                .device_code => |value| {
                    allocator.free(value.verification_uri);
                    allocator.free(value.user_code);
                },
                .prompt => |value| {
                    if (value.placeholder) |text| allocator.free(text);
                    allocator.free(value.message);
                },
            }
            self.* = undefined;
        }
    };

    pub const Batch = struct {
        allocator: std.mem.Allocator,
        facts: std.ArrayList(OwnedFact),
        outcome: ?Outcome,

        pub fn len(self: *const Batch) usize {
            return self.facts.items.len;
        }

        // ziglint-ignore: Z012
        pub fn fact(self: *const Batch, index: usize) Fact {
            return self.facts.items[index].view();
        }

        pub fn deinit(self: *Batch) void {
            for (self.facts.items) |*fact_value| fact_value.deinit(self.allocator);
            self.facts.deinit(self.allocator);
            self.* = undefined;
        }
    };

    const TransportOwner = union(enum) {
        http: ai.transport.HttpTransport,
        borrowed: ai.transport.Transport,

        fn view(self: *TransportOwner) ai.transport.Transport {
            return switch (self.*) {
                .http => |*http| http.transport(),
                .borrowed => |transport| transport,
            };
        }
    };

    pub const Inputs = struct {
        startup_cwd: []const u8,
        home: []const u8,
        provider_id: []const u8,
        method: ai.oauth.LoginMethod,
        now_ms: u64,
        limits: Limits = .{},
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    paths: ZiPaths,
    snapshot: ModelConfigSnapshot,
    provider_id: []u8,
    method: ai.oauth.LoginMethod,
    now_ms: u64,
    limits: Limits,
    transport: TransportOwner,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    facts: std.ArrayList(OwnedFact) = .empty,
    queued_fact_bytes: usize = 0,
    pending_answer: ?[]u8 = null,
    awaiting_prompt: bool = false,
    cancellation: ai.model.CancellationToken = .{},
    finished: bool = false,
    outcome: Outcome = .cancelled,
    outcome_taken: bool = false,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
    ) StartError!*AuthOperation {
        return startOwned(allocator, io, inputs, .{ .http = ai.transport.HttpTransport.init(allocator) });
    }

    pub fn startWithTransport(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
        transport: ai.transport.Transport,
    ) StartError!*AuthOperation {
        return startOwned(allocator, io, inputs, .{ .borrowed = transport });
    }

    fn startOwned(
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: Inputs,
        transport: TransportOwner,
    ) StartError!*AuthOperation {
        if (inputs.limits.max_facts == 0 or
            inputs.limits.max_fact_bytes == 0 or
            inputs.limits.max_queued_fact_bytes == 0 or
            inputs.limits.max_answer_bytes == 0)
        {
            return error.InvalidLimits;
        }
        const self = try allocator.create(AuthOperation);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .paths = ZiPaths.init(allocator, inputs.startup_cwd, inputs.home) catch |failure| {
                return switch (failure) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidPath => error.InvalidPath,
                };
            },
            .snapshot = undefined,
            .provider_id = undefined,
            .method = inputs.method,
            .now_ms = inputs.now_ms,
            .limits = inputs.limits,
            .transport = transport,
            .thread = undefined,
        };
        errdefer self.paths.deinit();
        self.snapshot = try ModelConfigSnapshot.load(allocator, io, &self.paths);
        errdefer self.snapshot.deinit();
        self.provider_id = try allocator.dupe(u8, inputs.provider_id);
        errdefer allocator.free(self.provider_id);
        try self.facts.ensureTotalCapacity(allocator, inputs.limits.max_facts);
        errdefer self.facts.deinit(allocator);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    pub fn provider(self: *const AuthOperation) []const u8 {
        return self.provider_id;
    }

    pub fn loginMethod(self: *const AuthOperation) ai.oauth.LoginMethod {
        return self.method;
    }

    pub fn isAwaitingAnswer(self: *AuthOperation) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.awaiting_prompt and !self.finished and !self.cancellation.isCancelled();
    }

    pub fn answer(self: *AuthOperation, source: []const u8) AnswerError!void {
        const value = std.mem.trim(u8, source, " \t\r\n");
        if (value.len == 0) return error.EmptyAnswer;
        if (value.len > self.limits.max_answer_bytes) return error.AnswerTooLarge;
        const owned = try self.allocator.dupe(u8, value);
        var owned_live = true;
        defer if (owned_live) {
            std.crypto.secureZero(u8, owned);
            self.allocator.free(owned);
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cancellation.isCancelled()) return error.Cancelled;
        if (!self.awaiting_prompt or self.finished or self.pending_answer != null) return error.NotAwaitingAnswer;
        self.pending_answer = owned;
        owned_live = false;
        self.condition.broadcast(self.io);
    }

    pub fn requestCancel(self: *AuthOperation) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.finished or self.cancellation.isCancelled()) return false;
        self.cancellation.cancel();
        self.condition.broadcast(self.io);
        return true;
    }

    pub fn hasPending(self: *AuthOperation) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.facts.items.len != 0 or (self.finished and !self.outcome_taken);
    }

    pub fn takeBatch(self: *AuthOperation) error{OutOfMemory}!Batch {
        var replacement: std.ArrayList(OwnedFact) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, self.limits.max_facts);

        self.mutex.lockUncancelable(self.io);
        const facts = self.facts;
        self.facts = replacement;
        self.queued_fact_bytes = 0;
        const outcome = if (self.finished and !self.outcome_taken) value: {
            self.outcome_taken = true;
            break :value self.outcome;
        } else null;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        return .{ .allocator = self.allocator, .facts = facts, .outcome = outcome };
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *AuthOperation) void {
        _ = self.requestCancel();
        self.thread.join();
        if (self.pending_answer) |answer_value| wipeAndFree(self.allocator, answer_value);
        for (self.facts.items) |*fact_value| fact_value.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.allocator.free(self.provider_id);
        self.snapshot.deinit();
        self.paths.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn threadMain(self: *AuthOperation) void {
        const interaction: ai.oauth.Interaction = .{
            .context = self,
            .vtable = &.{ .notify = notify, .prompt = prompt },
        };
        const result = CredentialManager.login(
            self.allocator,
            self.io,
            &self.paths,
            self.transport.view(),
            self.snapshot.view(),
            .{
                .provider_id = self.provider_id,
                .method = self.method,
                .interaction = interaction,
                .now_ms = self.now_ms,
                .cancellation = &self.cancellation,
            },
        );
        const outcome: Outcome = if (result) |_| .succeeded else |failure| outcome: {
            if (self.cancellation.isCancelled() or failure == error.Cancelled) break :outcome .cancelled;
            break :outcome .{ .failed = mapFailure(failure) };
        };

        self.mutex.lockUncancelable(self.io);
        self.awaiting_prompt = false;
        if (self.pending_answer) |answer_value| {
            wipeAndFree(self.allocator, answer_value);
            self.pending_answer = null;
        }
        self.outcome = outcome;
        self.finished = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn notify(context: *anyopaque, event: ai.oauth.Event) anyerror!void {
        const self: *AuthOperation = @ptrCast(@alignCast(context));
        var owned = OwnedFact.initEvent(self.allocator, event, self.limits.max_fact_bytes) catch |failure| {
            return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.FactTooLarge => error.ConsumerStopped,
            };
        };
        try self.enqueue(&owned, false);
    }

    // Context leads because this callback implements the erased OAuth interaction ABI.
    // ziglint-ignore: Z023
    fn prompt(
        context: *anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023
        request: ai.oauth.Prompt,
    ) anyerror![]u8 {
        const self: *AuthOperation = @ptrCast(@alignCast(context));
        var owned = OwnedFact.initPrompt(self.allocator, request, self.limits.max_fact_bytes) catch |failure| {
            return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.FactTooLarge => error.ConsumerStopped,
            };
        };
        try self.enqueue(&owned, true);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.pending_answer == null and !self.cancellation.isCancelled()) {
            self.condition.wait(self.io, &self.mutex) catch continue;
        }
        if (self.cancellation.isCancelled()) return error.Cancelled;
        const answer_value = try copyPromptAnswer(
            allocator,
            self.allocator,
            self.pending_answer.?,
        );
        self.pending_answer = null;
        self.awaiting_prompt = false;
        return answer_value;
    }

    fn enqueue(self: *AuthOperation, owned: *OwnedFact, marks_prompt: bool) anyerror!void {
        var owned_live = true;
        defer if (owned_live) owned.deinit(self.allocator);
        const retained_bytes = owned.retainedBytes();
        if (retained_bytes > self.limits.max_queued_fact_bytes) return error.ConsumerStopped;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while ((self.facts.items.len >= self.limits.max_facts or
            retained_bytes > self.limits.max_queued_fact_bytes -| self.queued_fact_bytes) and
            !self.cancellation.isCancelled())
        {
            self.condition.wait(self.io, &self.mutex) catch continue;
        }
        if (self.cancellation.isCancelled()) return error.Cancelled;
        if (marks_prompt) self.awaiting_prompt = true;
        self.facts.appendAssumeCapacity(owned.*);
        self.queued_fact_bytes += retained_bytes;
        owned_live = false;
        self.condition.broadcast(self.io);
    }

    fn admitFactBytes(max_bytes: usize, values: []const []const u8) error{FactTooLarge}!void {
        var total: usize = 0;
        for (values) |value| {
            total = std.math.add(usize, total, value.len) catch return error.FactTooLarge;
            if (total > max_bytes) return error.FactTooLarge;
        }
    }

    fn copyPromptAnswer(
        output_allocator: std.mem.Allocator,
        mailbox_allocator: std.mem.Allocator,
        mailbox_value: []u8,
    ) error{OutOfMemory}![]u8 {
        const output = try output_allocator.dupe(u8, mailbox_value);
        wipeAndFree(mailbox_allocator, mailbox_value);
        return output;
    }

    fn wipeAndFree(allocator: std.mem.Allocator, value: []u8) void {
        std.crypto.secureZero(u8, value);
        allocator.rawFree(value, .of(u8), @returnAddress());
    }

    fn mapFailure(failure: CredentialManager.Error) Failure {
        return switch (failure) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidCredentialFile => .invalid_credential_file,
            error.UnsupportedVersion => .unsupported_version,
            error.UnsafePath => .unsafe_path,
            error.ReadFailed => .read_failed,
            error.LockFailed => .lock_failed,
            error.WriteFailed => .write_failed,
            error.CommitIndeterminate => .commit_indeterminate,
            error.Cancelled => unreachable,
            error.TimedOut => .timed_out,
            error.InvalidUrl => .invalid_url,
            error.InvalidRequest => .invalid_request,
            error.ConnectionFailed => .connection_failed,
            error.InvalidResponse => .invalid_response,
            error.ResponseTooLarge => .response_too_large,
            error.ConsumerStopped => .consumer_stopped,
            error.Rejected => .rejected,
            error.InvalidModelConfiguration => .invalid_model_configuration,
            error.AuthenticationUnavailable => .authentication_unavailable,
            error.RefreshUnavailable => .refresh_unavailable,
        };
    }

    fn testAccessToken(allocator: std.mem.Allocator) ![]u8 {
        const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"account\"}}";
        const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
        defer allocator.free(encoded);
        _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
        return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
    }

    test "browser OAuth publishes bounded owned prompts and accepts an asynchronous answer" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..root_length];
        const access = try testAccessToken(std.testing.allocator);
        defer std.testing.allocator.free(access);
        const body = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_in\":3600}}",
            .{access},
        );
        defer std.testing.allocator.free(body);
        const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{ .status = 200, .body = body } }};
        var fake = ai.transport_testing.FakeTransport.init(&exchanges);
        const operation = try startWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root,
            .home = root,
            .provider_id = "openai-codex",
            .method = .browser,
            .now_ms = 1000,
        }, fake.transport());
        defer operation.deinit();

        var saw_url = false;
        var saw_prompt = false;
        var succeeded = false;
        for (0..5_000) |_| {
            if (operation.hasPending()) {
                var batch = try operation.takeBatch();
                defer batch.deinit();
                for (0..batch.len()) |index| switch (batch.fact(index)) {
                    .auth_url => |fact_value| {
                        saw_url = fact_value.url.len != 0;
                        try std.testing.expect(std.mem.find(u8, fact_value.url, "answer-secret") == null);
                    },
                    .prompt => {
                        saw_prompt = true;
                        try operation.answer("answer-secret");
                    },
                    .device_code => return error.UnexpectedDeviceCode,
                };
                if (batch.outcome) |outcome| {
                    try std.testing.expect(outcome == .succeeded);
                    succeeded = true;
                    break;
                }
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(saw_url);
        try std.testing.expect(saw_prompt);
        try std.testing.expect(succeeded);

        const journal_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, ".zi/agent/auth.json" });
        defer std.testing.allocator.free(journal_path);
        const stored = try std.Io.Dir.readFileAlloc(
            .cwd(),
            std.testing.io,
            journal_path,
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(stored);
        try std.testing.expect(std.mem.find(u8, stored, "answer-secret") == null);
    }

    test "device OAuth cancellation interrupts a blocked poll without prompting" {
        const BlockingDeviceTransport = struct {
            calls: usize = 0,

            // ziglint-ignore: Z020
            pub fn exchange(
                // ziglint-ignore: Z020
                self: *@This(),
                allocator: std.mem.Allocator,
                io: std.Io,
                request: ai.transport.Request,
                _: ai.transport.Delivery,
            ) ai.transport.Error!ai.transport.Response {
                self.calls += 1;
                if (self.calls == 1) {
                    return .{
                        .status = 200,
                        .body = try allocator.dupe(
                            u8,
                            "{\"device_auth_id\":\"device\",\"user_code\":\"CODE\",\"interval\":5}",
                        ),
                    };
                }
                while (request.cancellation) |cancellation| {
                    if (cancellation.isCancelled()) return error.Cancelled;
                    io.sleep(.fromMilliseconds(1), .awake) catch return error.Cancelled;
                } else return error.InvalidRequest;
            }
        };

        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
        var transport: BlockingDeviceTransport = .{};
        const operation = try startWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root_buffer[0..root_length],
            .home = root_buffer[0..root_length],
            .provider_id = "openai-codex",
            .method = .device_code,
            .now_ms = 0,
        }, ai.transport.Transport.from(&transport));
        defer operation.deinit();

        var saw_device = false;
        var cancelled = false;
        for (0..5_000) |_| {
            if (operation.hasPending()) {
                var batch = try operation.takeBatch();
                defer batch.deinit();
                for (0..batch.len()) |index| switch (batch.fact(index)) {
                    .device_code => {
                        saw_device = true;
                        try std.testing.expect(operation.requestCancel());
                    },
                    .auth_url, .prompt => return error.UnexpectedInteraction,
                };
                if (batch.outcome) |outcome| {
                    try std.testing.expect(outcome == .cancelled);
                    cancelled = true;
                    break;
                }
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(saw_device);
        try std.testing.expect(cancelled);
    }

    test "OAuth prompt answers move into the callback allocator" {
        var mailbox_backing: [64]u8 = undefined;
        var output_backing: [64]u8 = undefined;
        var mailbox = std.heap.FixedBufferAllocator.init(&mailbox_backing);
        var output = std.heap.FixedBufferAllocator.init(&output_backing);
        const mailbox_value = try mailbox.allocator().dupe(u8, "provider-answer");
        const copied_answer = try copyPromptAnswer(output.allocator(), mailbox.allocator(), mailbox_value);
        defer output.allocator().free(copied_answer);

        try std.testing.expect(output.ownsSlice(copied_answer));
        try std.testing.expectEqualStrings("provider-answer", copied_answer);
        for (mailbox_backing[0.."provider-answer".len]) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }

    test "OAuth fact and answer bounds reject data without retaining it" {
        try std.testing.expectError(error.FactTooLarge, admitFactBytes(3, &.{"four"}));
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
        var fake = ai.transport_testing.FakeTransport.init(&.{});
        const operation = try startWithTransport(std.testing.allocator, std.testing.io, .{
            .startup_cwd = root_buffer[0..root_length],
            .home = root_buffer[0..root_length],
            .provider_id = "missing-provider",
            .method = .browser,
            .now_ms = 0,
            .limits = .{ .max_answer_bytes = 3 },
        }, fake.transport());
        defer operation.deinit();
        try std.testing.expectError(error.AnswerTooLarge, operation.answer("four"));
    }
};

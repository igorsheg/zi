const std = @import("std");
const PrivateFileStore = @import("PrivateFileStore.zig");

pub const managed_name = "auth.json";
pub const max_depth: usize = 32;
pub const max_tokens: usize = 8192;
pub const max_string_size: usize = 64 * 1024;
pub const max_provider_size: usize = 128;

pub const Error = error{
    Invalid,
    TooLarge,
    Busy,
    NotRegular,
    IoFailure,
    OutOfMemory,
    Canceled,
    Poisoned,
    InvalidProvider,
    InvalidValue,
    TooDeep,
    TooManyTokens,
    StringTooLarge,
};

/// Move-only owned lookup result. `value` is canonical JSON and includes no newline.
pub const Result = union(enum) {
    missing,
    corrupt,
    value: []u8,

    pub fn deinit(result: *Result, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .value => |bytes| {
                std.crypto.secureZero(u8, bytes);
                allocator.free(bytes);
            },
            else => {},
        }
        result.* = undefined;
    }
};

pub const OrphanName = struct {
    buffer: [PrivateFileStore.max_name_size * 2]u8 = @splat(0),
    len: usize = 0,

    pub fn bytes(name: *const OrphanName) []const u8 {
        return name.buffer[0..name.len];
    }
};

pub const UncertainTake = struct {
    /// Retained because the caller cannot know whether removal was published.
    value: []u8,
    cause: MutationCause,
    orphan_name: ?OrphanName,
};

/// Move-only owned result from `take`. A malformed store is returned as an error.
pub const TakeResult = union(enum) {
    missing,
    value: []u8,
    not_published: MutationFailure,
    uncertain: UncertainTake,

    pub fn deinit(result: *TakeResult, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .value => |bytes| wipeFree(allocator, bytes),
            .uncertain => |outcome| wipeFree(allocator, outcome.value),
            .missing, .not_published => {},
        }
        result.* = undefined;
    }
};

pub const MutationCause = enum {
    invalid,
    too_large,
    busy,
    not_regular,
    io_failure,
    out_of_memory,
    canceled,
    poisoned,
    invalid_provider,
    invalid_value,
    too_deep,
    too_many_tokens,
    string_too_large,
};

pub const MutationFailure = struct {
    cause: MutationCause,
    orphan_name: ?OrphanName,
};

pub const SetResult = union(enum) {
    published,
    not_published: MutationFailure,
    uncertain: MutationFailure,
};

pub const DeleteResult = union(enum) {
    missing,
    deleted,
    not_published: MutationFailure,
    uncertain: MutationFailure,
};

pub const CallbackError = error{
    OutOfMemory,
    Canceled,
    OperationFailed,
};

/// Move-only callback decision. `.write` transfers allocator ownership to the store call.
pub const Decision = union(enum) {
    keep,
    remove,
    write: []u8,

    pub fn deinit(decision: *Decision, allocator: std.mem.Allocator) void {
        switch (decision.*) {
            .write => |bytes| wipeFree(allocator, bytes),
            .keep, .remove => {},
        }
        decision.* = undefined;
    }
};

/// Erased synchronous update policy. `current` is canonical provider JSON borrowed
/// only for the duration of `call`. Allocations in the returned decision use `allocator`.
pub const UpdateCallback = struct {
    context: *anyopaque,
    call_fn: *const fn (std.mem.Allocator, *anyopaque, ?[]const u8) CallbackError!Decision,

    pub fn call(
        callback: UpdateCallback,
        allocator: std.mem.Allocator,
        current: ?[]const u8,
    ) CallbackError!Decision {
        return callback.call_fn(allocator, callback.context, current);
    }
};

/// Move-only action. A write retains the callback-owned provider JSON so the
/// caller can adopt it in memory regardless of publication knowledge.
pub const UpdateAction = union(enum) {
    remove,
    write: []u8,

    pub fn deinit(action: *UpdateAction, allocator: std.mem.Allocator) void {
        switch (action.*) {
            .write => |bytes| wipeFree(allocator, bytes),
            .remove => {},
        }
        action.* = undefined;
    }
};

pub const UpdateFailure = struct {
    action: UpdateAction,
    cause: MutationCause,
    orphan_name: ?OrphanName,
};

/// Move-only locked update result. Deinitialize exactly once.
pub const UpdateResult = union(enum) {
    unchanged,
    published: UpdateAction,
    not_published: UpdateFailure,
    uncertain: UpdateFailure,

    pub fn deinit(result: *UpdateResult, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .published => |*action| action.deinit(allocator),
            .not_published, .uncertain => |*failure| failure.action.deinit(allocator),
            .unchanged => {},
        }
        result.* = undefined;
    }
};

/// Schema-free credentials stored in the managed `auth.json` private file.
/// The private store, nonce context, directory, and I/O must outlive this value.
pub const Store = struct {
    private: PrivateFileStore.Store,
    nonce_source: PrivateFileStore.NonceSource,
    commit_ops: PrivateFileStore.CommitOps = .standard,

    pub fn init(private: PrivateFileStore.Store, nonce_source: PrivateFileStore.NonceSource) Store {
        return .{ .private = private, .nonce_source = nonce_source };
    }

    pub fn get(store: Store, allocator: std.mem.Allocator, provider: []const u8) Error!Result {
        try validateProvider(provider);
        var read = try store.private.read(allocator, managed_name);
        defer wipeRead(allocator, &read);
        const bytes = switch (read) {
            .missing => return .missing,
            .bytes => |value| value,
        };
        scanBounds(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.TooLarge,
            else => return .corrupt,
        };
        var parsed = parseValue(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .corrupt,
        };
        defer deinitParsed(&parsed);
        if (parsed.value != .object) return .corrupt;
        const value = parsed.value.object.get(provider) orelse return .missing;
        return .{ .value = try canonicalValue(allocator, value, false) };
    }

    /// Replaces one provider. Missing or malformed current content is treated as `{}`.
    pub fn set(
        store: Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        value_json: []const u8,
    ) Error!SetResult {
        try validateProvider(provider);
        var value = try parseObject(allocator, value_json);
        defer deinitParsed(&value);
        var transaction = try store.private.begin(managed_name);
        defer transaction.deinit();
        store.setLocked(allocator, provider, &value, &transaction) catch |err| {
            return mutationSetResult(&transaction, err);
        };
        return .published;
    }

    fn setLocked(
        store: Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        value: *OwnedParsed,
        transaction: *PrivateFileStore.Transaction,
    ) Error!void {
        var read = try transaction.readCurrent(allocator);
        defer wipeRead(allocator, &read);
        var current = parseRoot(allocator, read) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try parseEmpty(allocator),
        };
        defer deinitParsed(&current);
        if (current.value.object.getPtr(provider)) |existing| {
            wipeValue(existing.*);
            existing.* = value.value;
        } else {
            const owned_provider = try current.arena.allocator().dupe(u8, provider);
            try current.value.object.put(current.arena.allocator(), owned_provider, value.value);
        }
        const encoded = try canonicalValue(allocator, current.value, true);
        defer wipeFree(allocator, encoded);
        try scanBounds(allocator, encoded);
        try transaction.replaceWithOps(encoded, store.nonce_source, store.commit_ops);
    }

    /// Deletes one provider. Returns false for a missing file or key.
    /// Malformed current content is refused with `error.InvalidValue`.
    pub fn delete(store: Store, allocator: std.mem.Allocator, provider: []const u8) Error!DeleteResult {
        try validateProvider(provider);
        var transaction = try store.private.begin(managed_name);
        defer transaction.deinit();
        return store.deleteLocked(allocator, provider, &transaction) catch |err|
            mutationDeleteResult(&transaction, err);
    }

    fn deleteLocked(
        store: Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        transaction: *PrivateFileStore.Transaction,
    ) Error!DeleteResult {
        var read = try transaction.readCurrent(allocator);
        defer wipeRead(allocator, &read);
        if (read == .missing) return .missing;
        var current = parseRoot(allocator, read) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        defer deinitParsed(&current);
        const discarded = current.value.object.fetchSwapRemove(provider) orelse return .missing;
        std.crypto.secureZero(u8, @constCast(discarded.key));
        wipeValue(discarded.value);
        const encoded = try canonicalValue(allocator, current.value, true);
        defer wipeFree(allocator, encoded);
        try scanBounds(allocator, encoded);
        try transaction.replaceWithOps(encoded, store.nonce_source, store.commit_ops);
        return .deleted;
    }

    /// Runs one caller policy while holding the managed file's intrinsic lock.
    /// `error.Busy` is returned directly; this function never waits or retries.
    pub fn update(
        store: Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        callback: UpdateCallback,
    ) (Error || CallbackError)!UpdateResult {
        try validateProvider(provider);
        var transaction = try store.private.begin(managed_name);
        defer transaction.deinit();
        return store.updateLocked(allocator, provider, callback, &transaction);
    }

    fn updateLocked(
        store: Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        callback: UpdateCallback,
        transaction: *PrivateFileStore.Transaction,
    ) (Error || CallbackError)!UpdateResult {
        var read = try transaction.readCurrent(allocator);
        defer wipeRead(allocator, &read);
        var current = try parseRoot(allocator, read);
        defer deinitParsed(&current);

        var current_json: ?[]u8 = null;
        defer if (current_json) |bytes| wipeFree(allocator, bytes);
        if (current.value.object.get(provider)) |value| {
            current_json = try canonicalValue(allocator, value, false);
        }

        const decision = try callback.call(allocator, current_json);
        switch (decision) {
            .keep => return .unchanged,
            .remove => {
                const action: UpdateAction = .remove;
                if (current.value.object.fetchSwapRemove(provider)) |discarded| {
                    std.crypto.secureZero(u8, @constCast(discarded.key));
                    wipeValue(discarded.value);
                }
                return store.publishUpdate(allocator, action, &current, transaction);
            },
            .write => |owned_json| {
                const action: UpdateAction = .{ .write = owned_json };
                var value = parseObject(allocator, owned_json) catch |err| {
                    return updateFailureResult(transaction, action, err);
                };
                defer deinitParsed(&value);
                var inserted = false;
                const slot = if (current.value.object.getPtr(provider)) |existing| existing else slot: {
                    const owned_provider = current.arena.allocator().dupe(u8, provider) catch {
                        return updateFailureResult(transaction, action, error.OutOfMemory);
                    };
                    current.value.object.put(current.arena.allocator(), owned_provider, .null) catch {
                        return updateFailureResult(transaction, action, error.OutOfMemory);
                    };
                    inserted = true;
                    break :slot current.value.object.getPtr(provider).?;
                };
                wipeValue(slot.*);
                slot.* = value.value;
                defer if (inserted) {
                    const discarded = current.value.object.fetchSwapRemove(provider).?;
                    std.crypto.secureZero(u8, @constCast(discarded.key));
                } else {
                    slot.* = .null;
                };
                return store.publishUpdate(allocator, action, &current, transaction);
            },
        }
    }

    fn publishUpdate(
        store: Store,
        allocator: std.mem.Allocator,
        action: UpdateAction,
        current: *OwnedParsed,
        transaction: *PrivateFileStore.Transaction,
    ) UpdateResult {
        const encoded = canonicalValue(allocator, current.value, true) catch |err| {
            return updateFailureResult(transaction, action, err);
        };
        defer wipeFree(allocator, encoded);
        scanBounds(allocator, encoded) catch |err| {
            return updateFailureResult(transaction, action, err);
        };
        transaction.replaceWithOps(encoded, store.nonce_source, store.commit_ops) catch |err| {
            return updateFailureResult(transaction, action, err);
        };
        return .{ .published = action };
    }

    /// Atomically removes and returns the provider value as canonical owned JSON.
    /// `.uncertain` retains that value when publication cannot be determined.
    pub fn take(store: Store, allocator: std.mem.Allocator, provider: []const u8) Error!TakeResult {
        try validateProvider(provider);
        var transaction = try store.private.begin(managed_name);
        defer transaction.deinit();
        return store.takeLocked(allocator, provider, &transaction) catch |err|
            .{ .not_published = mutationFailure(&transaction, err) };
    }

    fn takeLocked(
        store: Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        transaction: *PrivateFileStore.Transaction,
    ) Error!TakeResult {
        var read = try transaction.readCurrent(allocator);
        defer wipeRead(allocator, &read);
        if (read == .missing) return .missing;
        var current = parseRoot(allocator, read) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        defer deinitParsed(&current);
        const value = current.value.object.get(provider) orelse return .missing;
        const removed = try canonicalValue(allocator, value, false);
        errdefer wipeFree(allocator, removed);
        const discarded = current.value.object.fetchSwapRemove(provider) orelse unreachable;
        std.crypto.secureZero(u8, @constCast(discarded.key));
        wipeValue(discarded.value);
        const encoded = try canonicalValue(allocator, current.value, true);
        defer wipeFree(allocator, encoded);
        try scanBounds(allocator, encoded);
        transaction.replaceWithOps(encoded, store.nonce_source, store.commit_ops) catch |err| {
            if (transaction.mutationState() != .uncertain) return err;
            return .{ .uncertain = .{
                .value = removed,
                .cause = mutationCause(err),
                .orphan_name = captureOrphan(transaction),
            } };
        };
        return .{ .value = removed };
    }
};

const OwnedParsed = struct {
    backing: std.mem.Allocator,
    wiping: *WipingAllocator,
    arena: *std.heap.ArenaAllocator,
    value: std.json.Value,
};

const WipingAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(wiping: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = wiping, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const wiping: *WipingAllocator = @ptrCast(@alignCast(context));
        return wiping.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        if (new_len < memory.len) return false;
        const wiping: *WipingAllocator = @ptrCast(@alignCast(context));
        return wiping.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const wiping: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        wiping.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn parseRoot(
    allocator: std.mem.Allocator,
    read: PrivateFileStore.ReadResult,
) Error!OwnedParsed {
    const bytes = switch (read) {
        .missing => return parseEmpty(allocator),
        .bytes => |value| value,
    };
    var parsed = try parseValue(allocator, bytes);
    errdefer deinitParsed(&parsed);
    if (parsed.value != .object) return error.InvalidValue;
    return parsed;
}

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) Error!OwnedParsed {
    var parsed = try parseValue(allocator, bytes);
    errdefer deinitParsed(&parsed);
    if (parsed.value != .object) return error.InvalidValue;
    return parsed;
}

fn parseValue(allocator: std.mem.Allocator, bytes: []const u8) Error!OwnedParsed {
    if (bytes.len > PrivateFileStore.max_file_size) return error.TooLarge;
    try scanBounds(allocator, bytes);
    const wiping = allocator.create(WipingAllocator) catch return error.OutOfMemory;
    wiping.* = .{ .backing = allocator };
    errdefer allocator.destroy(wiping);
    var parsed = std.json.parseFromSlice(std.json.Value, wiping.allocator(), bytes, .{
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
        .parse_numbers = true,
        .max_value_len = max_string_size,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidValue,
    };
    errdefer parsed.deinit();
    try validateNumbers(parsed.value);
    return .{
        .backing = allocator,
        .wiping = wiping,
        .arena = parsed.arena,
        .value = parsed.value,
    };
}

fn parseEmpty(allocator: std.mem.Allocator) Error!OwnedParsed {
    return parseValue(allocator, "{}");
}

fn validateNumbers(value: std.json.Value) Error!void {
    switch (value) {
        .number_string => return error.InvalidValue,
        .float => |number| if (!std.math.isFinite(number)) return error.InvalidValue,
        .array => |array| for (array.items) |item| try validateNumbers(item),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try validateNumbers(entry.value_ptr.*);
        },
        else => {},
    }
}

fn deinitParsed(parsed: *OwnedParsed) void {
    wipeValue(parsed.value);
    const owned: std.json.Parsed(std.json.Value) = .{
        .arena = parsed.arena,
        .value = parsed.value,
    };
    owned.deinit();
    parsed.backing.destroy(parsed.wiping);
    parsed.* = undefined;
}

fn wipeValue(value: std.json.Value) void {
    switch (value) {
        .string => |bytes| std.crypto.secureZero(u8, @constCast(bytes)),
        .number_string => |bytes| std.crypto.secureZero(u8, @constCast(bytes)),
        .array => |array| for (array.items) |item| wipeValue(item),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                std.crypto.secureZero(u8, @constCast(entry.key_ptr.*));
                wipeValue(entry.value_ptr.*);
            }
        },
        else => {},
    }
}

fn captureOrphan(transaction: *const PrivateFileStore.Transaction) ?OrphanName {
    const bytes = transaction.orphanName() orelse return null;
    var result: OrphanName = .{ .len = bytes.len };
    @memcpy(result.buffer[0..bytes.len], bytes);
    return result;
}

fn mutationFailure(transaction: *const PrivateFileStore.Transaction, err: Error) MutationFailure {
    return .{ .cause = mutationCause(err), .orphan_name = captureOrphan(transaction) };
}

fn mutationSetResult(transaction: *const PrivateFileStore.Transaction, err: Error) SetResult {
    const failure = mutationFailure(transaction, err);
    return switch (transaction.mutationState()) {
        .not_published => .{ .not_published = failure },
        .uncertain, .published => .{ .uncertain = failure },
    };
}

fn mutationDeleteResult(transaction: *const PrivateFileStore.Transaction, err: Error) DeleteResult {
    const failure = mutationFailure(transaction, err);
    return switch (transaction.mutationState()) {
        .not_published => .{ .not_published = failure },
        .uncertain, .published => .{ .uncertain = failure },
    };
}

fn updateFailureResult(
    transaction: *const PrivateFileStore.Transaction,
    action: UpdateAction,
    err: Error,
) UpdateResult {
    const failure: UpdateFailure = .{
        .action = action,
        .cause = mutationCause(err),
        .orphan_name = captureOrphan(transaction),
    };
    return switch (transaction.mutationState()) {
        .not_published => .{ .not_published = failure },
        .uncertain, .published => .{ .uncertain = failure },
    };
}

fn mutationCause(err: Error) MutationCause {
    return switch (err) {
        error.Invalid => .invalid,
        error.TooLarge => .too_large,
        error.Busy => .busy,
        error.NotRegular => .not_regular,
        error.IoFailure => .io_failure,
        error.OutOfMemory => .out_of_memory,
        error.Canceled => .canceled,
        error.Poisoned => .poisoned,
        error.InvalidProvider => .invalid_provider,
        error.InvalidValue => .invalid_value,
        error.TooDeep => .too_deep,
        error.TooManyTokens => .too_many_tokens,
        error.StringTooLarge => .string_too_large,
    };
}

fn validateProvider(provider: []const u8) Error!void {
    if (provider.len == 0 or provider.len > max_provider_size) return error.InvalidProvider;
    if (!(std.ascii.isAlphanumeric(provider[0]) or provider[0] == '_')) return error.InvalidProvider;
    for (provider[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.' => true,
        else => false,
    })) return error.InvalidProvider;
}

fn scanBounds(allocator: std.mem.Allocator, bytes: []const u8) Error!void {
    if (bytes.len > PrivateFileStore.max_file_size) return error.TooLarge;
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(allocator, .alloc_if_needed, max_string_size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.StringTooLarge,
            else => return error.InvalidValue,
        };
        defer switch (token) {
            .allocated_string => |value| {
                std.crypto.secureZero(u8, value);
                allocator.free(value);
            },
            .allocated_number => |value| {
                std.crypto.secureZero(u8, value);
                allocator.free(value);
            },
            else => {},
        };
        tokens += 1;
        if (tokens > max_tokens) return error.TooManyTokens;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > max_depth) return error.TooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidValue;
                depth -= 1;
            },
            .end_of_document => {
                if (depth == 0) return;
                return error.InvalidValue;
            },
            else => {},
        }
    }
}

fn canonicalValue(allocator: std.mem.Allocator, value: std.json.Value, newline: bool) Error![]u8 {
    var scratch: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var counter: LimitedCounter = .init(&scratch, PrivateFileStore.max_file_size);
    writeCanonical(allocator, &counter.writer, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.TooLarge,
    };
    if (newline) counter.writer.writeByte('\n') catch return error.TooLarge;
    const length = counter.fullCount();
    if (length > PrivateFileStore.max_file_size) return error.TooLarge;
    const result = allocator.alloc(u8, length) catch return error.OutOfMemory;
    errdefer {
        std.crypto.secureZero(u8, result);
        allocator.free(result);
    }
    var writer: std.Io.Writer = .fixed(result);
    writeCanonical(allocator, &writer, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => unreachable,
    };
    if (newline) writer.writeByte('\n') catch unreachable;
    return result;
}

const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

fn writeCanonical(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) WriteError!void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try writeValue(allocator, &json, value);
}

fn writeValue(allocator: std.mem.Allocator, json: *std.json.Stringify, value: std.json.Value) WriteError!void {
    switch (value) {
        .null => try json.write(null),
        .bool => |inner| try json.write(inner),
        .integer => |inner| try json.write(inner),
        .float => |inner| {
            std.debug.assert(std.math.isFinite(inner));
            try json.beginWriteRaw();
            var buffer: [64]u8 = undefined;
            defer std.crypto.secureZero(u8, &buffer);
            const bytes = formatJanssonReal(&buffer, inner);
            try json.writer.writeAll(bytes);
            json.endWriteRaw();
        },
        .number_string => unreachable,
        .string => |inner| try json.write(inner),
        .array => |inner| {
            try json.beginArray();
            for (inner.items) |item| try writeValue(allocator, json, item);
            try json.endArray();
        },
        .object => |inner| {
            const keys = try allocator.alloc([]const u8, inner.count());
            defer allocator.free(keys);
            var iterator = inner.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
            std.sort.pdq([]const u8, keys, {}, lessString);
            try json.beginObject();
            for (keys) |key| {
                try json.objectField(key);
                try writeValue(allocator, json, inner.get(key).?);
            }
            try json.endObject();
        },
    }
}

fn formatJanssonReal(buffer: *[64]u8, value: f64) []const u8 {
    std.debug.assert(std.math.isFinite(value));
    var scientific_buffer: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &scientific_buffer);
    const scientific = std.fmt.bufPrint(&scientific_buffer, "{e}", .{value}) catch unreachable;
    const exponent_at = std.mem.indexOfScalar(u8, scientific, 'e').?;
    const exponent = std.fmt.parseInt(i16, scientific[exponent_at + 1 ..], 10) catch unreachable;
    const mantissa = scientific[0..exponent_at];
    const negative = mantissa[0] == '-';
    const unsigned = if (negative) mantissa[1..] else mantissa;
    var digits: [24]u8 = undefined;
    defer std.crypto.secureZero(u8, &digits);
    var digits_len: usize = 0;
    for (unsigned) |byte| if (byte != '.') {
        digits[digits_len] = byte;
        digits_len += 1;
    };
    const decpt: i16 = exponent + 1;
    if (decpt <= -4 or decpt > 16) return std.fmt.bufPrint(
        buffer,
        "{s}e{d}",
        .{ mantissa, exponent },
    ) catch unreachable;

    var writer: std.Io.Writer = .fixed(buffer);
    if (negative) writer.writeByte('-') catch unreachable;
    if (decpt <= 0) {
        writer.writeAll("0.") catch unreachable;
        writer.splatByteAll('0', @intCast(-decpt)) catch unreachable;
        writer.writeAll(digits[0..digits_len]) catch unreachable;
    } else {
        const point: usize = @intCast(decpt);
        if (point >= digits_len) {
            writer.writeAll(digits[0..digits_len]) catch unreachable;
            writer.splatByteAll('0', point - digits_len) catch unreachable;
            writer.writeAll(".0") catch unreachable;
        } else {
            writer.writeAll(digits[0..point]) catch unreachable;
            writer.writeByte('.') catch unreachable;
            writer.writeAll(digits[point..digits_len]) catch unreachable;
        }
    }
    return writer.buffered();
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

const LimitedCounter = struct {
    count: usize = 0,
    limit: usize,
    exceeded: bool = false,
    writer: std.Io.Writer,

    fn init(buffer: []u8, limit: usize) LimitedCounter {
        return .{ .limit = limit, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn fullCount(counter: *const LimitedCounter) usize {
        return counter.count + counter.writer.end;
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const counter: *LimitedCounter = @alignCast(@fieldParentPtr("writer", writer));
        var written = std.math.mul(usize, data[data.len - 1].len, splat) catch return error.WriteFailed;
        for (data[0 .. data.len - 1]) |bytes| {
            written = std.math.add(usize, written, bytes.len) catch return error.WriteFailed;
        }
        const buffered = std.math.add(usize, counter.count, writer.end) catch return error.WriteFailed;
        const total = std.math.add(usize, buffered, written) catch return error.WriteFailed;
        if (total > counter.limit) return error.WriteFailed;
        counter.count = total;
        writer.end = 0;
        return written;
    }
};

fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

fn wipeRead(allocator: std.mem.Allocator, read: *PrivateFileStore.ReadResult) void {
    switch (read.*) {
        .bytes => |bytes| std.crypto.secureZero(u8, bytes),
        .missing => {},
    }
    read.deinit(allocator);
}

fn testSource(state: *u8) PrivateFileStore.NonceSource {
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) PrivateFileStore.Error!void {
            const value: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, value.*);
            value.* +%= 1;
        }
    };
    return .{ .context = state, .fill_fn = Source.fill };
}

test "set get delete take preserve unknown and sort recursively" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 1;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));

    _ = try store.set(std.testing.allocator, "zeta", "{\"z\":1,\"a\":{\"d\":4,\"b\":2}}");
    _ = try store.set(std.testing.allocator, "alpha", "{\"token\":\"secret\",\"unknown\":true}");
    var result = try store.get(std.testing.allocator, "zeta");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\n  \"a\": {\n    \"b\": 2,\n    \"d\": 4\n  },\n  \"z\": 1\n}", result.value);

    var taken = try store.take(std.testing.allocator, "alpha");
    defer taken.deinit(std.testing.allocator);
    try std.testing.expect(taken == .value);
    var absent = try store.get(std.testing.allocator, "alpha");
    defer absent.deinit(std.testing.allocator);
    try std.testing.expect(absent == .missing);
    try std.testing.expect((try store.delete(std.testing.allocator, "alpha")) == .missing);

    var file = try private.read(std.testing.allocator, managed_name);
    defer file.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "{\n  \"zeta\": {\n    \"a\": {\n      \"b\": 2,\n      \"d\": 4\n    },\n    \"z\": 1\n  }\n}\n",
        file.bytes,
    );
    const target = try temporary.dir.openFile(io, managed_name, .{ .follow_symlinks = false });
    defer target.close(io);
    if (std.Io.File.Permissions.has_executable_bit) {
        const stat = try target.stat(io);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "corrupt get is typed set replaces and delete refuses" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 7;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    var transaction = try private.begin(managed_name);
    try transaction.replace("not json", testSource(&nonce));
    transaction.deinit();
    const store = Store.init(private, testSource(&nonce));
    var corrupt = try store.get(std.testing.allocator, "openai");
    defer corrupt.deinit(std.testing.allocator);
    try std.testing.expect(corrupt == .corrupt);
    const refused = try store.delete(std.testing.allocator, "openai");
    try std.testing.expect(refused == .not_published);
    try std.testing.expectEqual(MutationCause.invalid_value, refused.not_published.cause);
    _ = try store.set(std.testing.allocator, "openai", "{\"key\":\"value\"}");
    try std.testing.expect((try store.delete(std.testing.allocator, "openai")) == .deleted);
}

test "duplicate keys use last and provider and value are validated" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 2;
    const store = Store.init(PrivateFileStore.Store.init(io, temporary.dir), testSource(&nonce));
    _ = try store.set(std.testing.allocator, "openai", "{\"x\":1,\"x\":2}");
    var result = try store.get(std.testing.allocator, "openai");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\n  \"x\": 2\n}", result.value);
    try std.testing.expectError(error.InvalidProvider, store.set(std.testing.allocator, "../bad", "{}"));
    try std.testing.expectError(error.InvalidValue, store.set(std.testing.allocator, "good", "[]"));
}

fn exerciseCanonicalAllocations(allocator: std.mem.Allocator) !void {
    var parsed = try parseObject(allocator, "{\"z\":{\"secret\":\"value\"},\"a\":[1,true,null]}");
    defer deinitParsed(&parsed);
    const bytes = try canonicalValue(allocator, parsed.value, true);
    wipeFree(allocator, bytes);
}

test "canonical parsing and serialization free every allocation on OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCanonicalAllocations,
        .{},
    );
}

test "credential mutations use intrinsic lock" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 5;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));
    var transaction = try private.begin(managed_name);
    defer transaction.deinit();
    try std.testing.expectError(error.Busy, store.set(std.testing.allocator, "openai", "{}"));
}

fn repeatedArray(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"a\":[");
    for (0..count) |index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.writeByte('0');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

test "assembled root bounds are checked before publication" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 11;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));

    var nested: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer nested.deinit();
    for (0..max_depth) |_| try nested.writer.writeAll("{\"x\":");
    try nested.writer.writeByte('0');
    for (0..max_depth) |_| try nested.writer.writeByte('}');
    const deep = try store.set(std.testing.allocator, "deep", nested.written());
    try std.testing.expect(deep == .not_published);
    try std.testing.expectEqual(MutationCause.too_deep, deep.not_published.cause);
    var missing = try private.read(std.testing.allocator, managed_name);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing == .missing);

    const first = try repeatedArray(std.testing.allocator, 4100);
    defer std.testing.allocator.free(first);
    const second = try repeatedArray(std.testing.allocator, 4100);
    defer std.testing.allocator.free(second);
    _ = try store.set(std.testing.allocator, "first", first);
    const excessive = try store.set(std.testing.allocator, "second", second);
    try std.testing.expect(excessive == .not_published);
    try std.testing.expectEqual(MutationCause.too_many_tokens, excessive.not_published.cause);
    var absent = try store.get(std.testing.allocator, "second");
    defer absent.deinit(std.testing.allocator);
    try std.testing.expect(absent == .missing);
}

test "numbers match integer and finite real JSON semantics" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 12;
    const store = Store.init(PrivateFileStore.Store.init(io, temporary.dir), testSource(&nonce));
    _ = try store.set(std.testing.allocator, "numbers", "{\"real\":1e0,\"negative_zero\":-0.0,\"integer\":1}");
    var result = try store.get(std.testing.allocator, "numbers");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "{\n  \"integer\": 1,\n  \"negative_zero\": -0.0,\n  \"real\": 1.0\n}",
        result.value,
    );
    try std.testing.expectError(
        error.InvalidValue,
        store.set(std.testing.allocator, "overflow", "{\"n\":9223372036854775808}"),
    );
    try std.testing.expectError(
        error.InvalidValue,
        store.set(std.testing.allocator, "nonfinite", "{\"n\":1e400}"),
    );

    _ = try store.set(
        std.testing.allocator,
        "extremes",
        "{\"a\":1e20,\"b\":1e-7,\"c\":5e-324,\"d\":1.7976931348623157e308}",
    );
    var extremes = try store.get(std.testing.allocator, "extremes");
    defer extremes.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "{\n  \"a\": 1e20,\n  \"b\": 1e-7,\n  \"c\": 5e-324,\n" ++
            "  \"d\": 1.7976931348623157e308\n}",
        extremes.value,
    );
}

test "delete and take of final provider persist empty object" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 13;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));
    _ = try store.set(std.testing.allocator, "only", "{\"token\":\"one\"}");
    try std.testing.expect((try store.delete(std.testing.allocator, "only")) == .deleted);
    var empty = try private.read(std.testing.allocator, managed_name);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}\n", empty.bytes);

    _ = try store.set(std.testing.allocator, "only", "{\"token\":\"two\"}");
    var taken = try store.take(std.testing.allocator, "only");
    defer taken.deinit(std.testing.allocator);
    try std.testing.expect(taken == .value);
    var empty_again = try private.read(std.testing.allocator, managed_name);
    defer empty_again.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}\n", empty_again.bytes);
}

test "take retains removed value and orphan name when publication is uncertain" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 14;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const standard = Store.init(private, testSource(&nonce));
    _ = try standard.set(std.testing.allocator, "only", "{\"token\":\"secret\"}");
    const Failing = struct {
        fn rename(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: []const u8,
        ) PrivateFileStore.Error!void {
            return error.IoFailure;
        }

        fn cleanup(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
        ) (PrivateFileStore.Error || error{FileNotFound})!void {
            return error.IoFailure;
        }
    };
    const failing: Store = .{
        .private = private,
        .nonce_source = testSource(&nonce),
        .commit_ops = .{
            .rename_fn = Failing.rename,
            .delete_temp_fn = Failing.cleanup,
        },
    };
    var result = try failing.take(std.testing.allocator, "only");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .uncertain);
    try std.testing.expectEqualStrings("{\n  \"token\": \"secret\"\n}", result.uncertain.value);
    try std.testing.expectEqual(MutationCause.io_failure, result.uncertain.cause);
    const orphan = result.uncertain.orphan_name.?;
    try std.testing.expect(std.mem.startsWith(u8, orphan.bytes(), ".zi-tmp-auth.json-"));

    var unchanged = try standard.get(std.testing.allocator, "only");
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expect(unchanged == .value);
    var cleanup = try private.begin(managed_name);
    defer cleanup.deinit();
    try std.testing.expect(try cleanup.cleanupOrphan(orphan.bytes()));
}

fn failingRename(comptime failure: PrivateFileStore.Error) *const fn (
    std.Io,
    ?*anyopaque,
    std.Io.Dir,
    []const u8,
    []const u8,
) PrivateFileStore.Error!void {
    return struct {
        fn call(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: []const u8,
        ) PrivateFileStore.Error!void {
            return failure;
        }
    }.call;
}

test "uncertain take preserves every exact commit cause" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 18;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const standard = Store.init(private, testSource(&nonce));
    _ = try standard.set(std.testing.allocator, "only", "{\"token\":\"secret\"}");

    inline for (.{
        .{ error.Invalid, MutationCause.invalid },
        .{ error.TooLarge, MutationCause.too_large },
        .{ error.Busy, MutationCause.busy },
        .{ error.NotRegular, MutationCause.not_regular },
        .{ error.IoFailure, MutationCause.io_failure },
        .{ error.OutOfMemory, MutationCause.out_of_memory },
        .{ error.Canceled, MutationCause.canceled },
        .{ error.Poisoned, MutationCause.poisoned },
    }) |case| {
        const failing: Store = .{
            .private = private,
            .nonce_source = testSource(&nonce),
            .commit_ops = .{ .rename_fn = failingRename(case[0]) },
        };
        var outcome = try failing.take(std.testing.allocator, "only");
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expect(outcome == .uncertain);
        try std.testing.expectEqual(case[1], outcome.uncertain.cause);
        try std.testing.expect(outcome.uncertain.orphan_name == null);
        try std.testing.expectEqualStrings(
            "{\n  \"token\": \"secret\"\n}",
            outcome.uncertain.value,
        );
    }
}

fn exerciseMutationAllocations(allocator: std.mem.Allocator, store: Store) !void {
    const result = try store.set(allocator, "oom", "{\"secret\":\"value\",\"nested\":{\"x\":1}}");
    switch (result) {
        .published => {},
        .not_published => |failure| {
            if (failure.cause == .out_of_memory) return error.OutOfMemory;
            return error.UnexpectedMutationFailure;
        },
        .uncertain => return error.UnexpectedMutationFailure,
    }
}

test "set mutation frees every allocation on OOM" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 15;
    const store = Store.init(PrivateFileStore.Store.init(io, temporary.dir), testSource(&nonce));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMutationAllocations,
        .{store},
    );
}

test "set and delete distinguish not-published and uncertain failures" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 16;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const standard = Store.init(private, testSource(&nonce));
    _ = try standard.set(std.testing.allocator, "only", "{\"token\":\"old\"}");
    const FailWrite = struct {
        fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
    };
    const before: Store = .{
        .private = private,
        .nonce_source = testSource(&nonce),
        .commit_ops = .{ .write_fn = FailWrite.write },
    };
    const set_before = try before.set(std.testing.allocator, "only", "{\"token\":\"new\"}");
    try std.testing.expect(set_before == .not_published);
    try std.testing.expectEqual(MutationCause.io_failure, set_before.not_published.cause);
    const delete_before = try before.delete(std.testing.allocator, "only");
    try std.testing.expect(delete_before == .not_published);

    const FailRename = struct {
        fn rename(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: []const u8,
        ) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
    };
    const uncertain: Store = .{
        .private = private,
        .nonce_source = testSource(&nonce),
        .commit_ops = .{ .rename_fn = FailRename.rename },
    };
    const set_uncertain = try uncertain.set(std.testing.allocator, "only", "{\"token\":\"new\"}");
    try std.testing.expect(set_uncertain == .uncertain);
    try std.testing.expectEqual(MutationCause.io_failure, set_uncertain.uncertain.cause);
    const delete_uncertain = try uncertain.delete(std.testing.allocator, "only");
    try std.testing.expect(delete_uncertain == .uncertain);
}

const FreeObserver = struct {
    backing: std.mem.Allocator,
    saw_secret: bool = false,

    fn allocator(observer: *FreeObserver) std.mem.Allocator {
        return .{ .ptr = observer, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const observer: *FreeObserver = @ptrCast(@alignCast(context));
        return observer.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        if (new_len < memory.len) return false;
        const observer: *FreeObserver = @ptrCast(@alignCast(context));
        return observer.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const observer: *FreeObserver = @ptrCast(@alignCast(context));
        if (std.mem.indexOf(u8, memory, "arena-residue") != null or
            std.mem.indexOf(u8, memory, "callback-residue") != null)
        {
            observer.saw_secret = true;
        }
        observer.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "JSON arena frees wipe overwritten and partial secrets" {
    var observer: FreeObserver = .{ .backing = std.testing.allocator };
    var valid = try parseObject(
        observer.allocator(),
        "{\"duplicate\":\"arena-residue\",\"duplicate\":\"replacement\"}",
    );
    deinitParsed(&valid);
    try std.testing.expectError(
        error.InvalidValue,
        parseObject(observer.allocator(), "{\"partial\":\"arena-residue\","),
    );
    try std.testing.expect(!observer.saw_secret);
}

fn exerciseDeleteAllocations(allocator: std.mem.Allocator, store: Store) !void {
    _ = try store.set(std.testing.allocator, "oom-delete", "{\"secret\":\"delete\"}");
    const result = try store.delete(allocator, "oom-delete");
    switch (result) {
        .deleted, .missing => {},
        .not_published => |failure| {
            if (failure.cause == .out_of_memory) return error.OutOfMemory;
            return error.UnexpectedMutationFailure;
        },
        .uncertain => return error.UnexpectedMutationFailure,
    }
}

fn exerciseTakeAllocations(allocator: std.mem.Allocator, store: Store) !void {
    _ = try store.set(std.testing.allocator, "oom-take", "{\"secret\":\"take\"}");
    var result = try store.take(allocator, "oom-take");
    defer result.deinit(allocator);
    switch (result) {
        .value, .missing => {},
        .not_published => |failure| {
            if (failure.cause == .out_of_memory) return error.OutOfMemory;
            return error.UnexpectedMutationFailure;
        },
        .uncertain => return error.UnexpectedMutationFailure,
    }
}

test "delete and take mutations free every allocation on OOM" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 17;
    const store = Store.init(PrivateFileStore.Store.init(io, temporary.dir), testSource(&nonce));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeleteAllocations,
        .{store},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTakeAllocations,
        .{store},
    );
}

const UpdateTestContext = struct {
    private: PrivateFileStore.Store,
    calls: usize = 0,
    lock_held: bool = false,
    expected_current: ?[]const u8 = null,
    decision: enum { keep, remove, write } = .keep,

    fn callback(
        allocator: std.mem.Allocator,
        context_ptr: *anyopaque,
        current: ?[]const u8,
    ) CallbackError!Decision {
        const context: *UpdateTestContext = @ptrCast(@alignCast(context_ptr));
        context.calls += 1;
        if (context.private.begin(managed_name)) |nested_value| {
            var nested = nested_value;
            nested.deinit();
        } else |err| {
            context.lock_held = err == error.Busy;
        }
        if (context.expected_current) |expected| {
            if (current == null or !std.mem.eql(u8, expected, current.?)) return error.OperationFailed;
        } else if (current != null) return error.OperationFailed;
        return switch (context.decision) {
            .keep => .keep,
            .remove => .remove,
            .write => .{ .write = allocator.dupe(u8, "{\"token\":\"new\",\"n\":1}") catch
                return error.OutOfMemory },
        };
    }

    fn erased(context: *UpdateTestContext) UpdateCallback {
        return .{ .context = context, .call_fn = callback };
    }
};

test "locked update calls policy once with canonical current and keep does not write" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 31;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));
    _ = try store.set(std.testing.allocator, "openai", "{\"z\":2,\"token\":\"old\"}");
    var before = try private.read(std.testing.allocator, managed_name);
    defer before.deinit(std.testing.allocator);

    var context: UpdateTestContext = .{
        .private = private,
        .expected_current = "{\n  \"token\": \"old\",\n  \"z\": 2\n}",
    };
    var result = try store.update(std.testing.allocator, "openai", context.erased());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .unchanged);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expect(context.lock_held);
    var after = try private.read(std.testing.allocator, managed_name);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(before.bytes, after.bytes);
}

test "locked update leaves missing decisions to caller and publishes write and remove" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 41;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));

    var context: UpdateTestContext = .{ .private = private, .decision = .write };
    var written = try store.update(std.testing.allocator, "codex", context.erased());
    defer written.deinit(std.testing.allocator);
    try std.testing.expect(written == .published);
    try std.testing.expect(written.published == .write);
    try std.testing.expectEqualStrings("{\"token\":\"new\",\"n\":1}", written.published.write);
    try std.testing.expect(context.lock_held);

    var current = try store.get(std.testing.allocator, "codex");
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\n  \"n\": 1,\n  \"token\": \"new\"\n}", current.value);

    context.expected_current = current.value;
    context.decision = .remove;
    context.lock_held = false;
    var removed = try store.update(std.testing.allocator, "codex", context.erased());
    defer removed.deinit(std.testing.allocator);
    try std.testing.expect(removed == .published);
    try std.testing.expect(removed.published == .remove);
    try std.testing.expect(context.lock_held);
    var absent = try store.get(std.testing.allocator, "codex");
    defer absent.deinit(std.testing.allocator);
    try std.testing.expect(absent == .missing);
}

test "locked update refuses malformed root before callback and returns Busy directly" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 51;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    var seed = try private.begin(managed_name);
    try seed.replace("bad", testSource(&nonce));
    seed.deinit();
    const store = Store.init(private, testSource(&nonce));
    var context: UpdateTestContext = .{ .private = private };
    try std.testing.expectError(
        error.InvalidValue,
        store.update(std.testing.allocator, "codex", context.erased()),
    );
    try std.testing.expectEqual(@as(usize, 0), context.calls);

    var transaction = try private.begin(managed_name);
    defer transaction.deinit();
    try std.testing.expectError(
        error.Busy,
        store.update(std.testing.allocator, "codex", context.erased()),
    );
    try std.testing.expectEqual(@as(usize, 0), context.calls);
}

test "locked update reports publication state and retains write action" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 61;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const FailWrite = struct {
        fn call(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
    };
    const FailRename = struct {
        fn call(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: []const u8,
        ) PrivateFileStore.Error!void {
            return error.IoFailure;
        }

        fn cleanup(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
        ) (PrivateFileStore.Error || error{FileNotFound})!void {
            return error.IoFailure;
        }
    };
    var context: UpdateTestContext = .{ .private = private, .decision = .write };
    const before: Store = .{
        .private = private,
        .nonce_source = testSource(&nonce),
        .commit_ops = .{ .write_fn = FailWrite.call },
    };
    var not_published = try before.update(std.testing.allocator, "codex", context.erased());
    defer not_published.deinit(std.testing.allocator);
    try std.testing.expect(not_published == .not_published);
    try std.testing.expect(not_published.not_published.action == .write);
    try std.testing.expectEqual(MutationCause.io_failure, not_published.not_published.cause);

    const during: Store = .{
        .private = private,
        .nonce_source = testSource(&nonce),
        .commit_ops = .{
            .rename_fn = FailRename.call,
            .delete_temp_fn = FailRename.cleanup,
        },
    };
    var uncertain = try during.update(std.testing.allocator, "codex", context.erased());
    defer uncertain.deinit(std.testing.allocator);
    try std.testing.expect(uncertain == .uncertain);
    try std.testing.expect(uncertain.uncertain.action == .write);
    try std.testing.expectEqual(MutationCause.io_failure, uncertain.uncertain.cause);
    try std.testing.expect(uncertain.uncertain.orphan_name != null);
}

fn allocationUpdateCallback(
    allocator: std.mem.Allocator,
    _: *anyopaque,
    _: ?[]const u8,
) CallbackError!Decision {
    return .{ .write = allocator.dupe(u8, "{\"secret\":\"callback-residue\"}") catch
        return error.OutOfMemory };
}

fn exerciseUpdateAllocations(allocator: std.mem.Allocator, store: Store) !void {
    var context: u8 = 0;
    var result = try store.update(allocator, "oom-update", .{
        .context = &context,
        .call_fn = allocationUpdateCallback,
    });
    defer result.deinit(allocator);
    switch (result) {
        .unchanged, .published => {},
        .not_published => |failure| {
            if (failure.cause == .out_of_memory) return error.OutOfMemory;
            return error.UnexpectedMutationFailure;
        },
        .uncertain => return error.UnexpectedMutationFailure,
    }
}

test "locked update frees every allocation on OOM and wipes callback current and root bytes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 71;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const store = Store.init(private, testSource(&nonce));
    _ = try store.set(
        std.testing.allocator,
        "other",
        "{\"secret\":\"arena-residue\"}",
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseUpdateAllocations,
        .{store},
    );

    var observer: FreeObserver = .{ .backing = std.testing.allocator };
    var context: u8 = 0;
    var result = try store.update(observer.allocator(), "other", .{
        .context = &context,
        .call_fn = allocationUpdateCallback,
    });
    result.deinit(observer.allocator());
    try std.testing.expect(!observer.saw_secret);
}

test "locked update callback errors are typed and invalid writes retain owned action" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 81;
    const store = Store.init(PrivateFileStore.Store.init(io, temporary.dir), testSource(&nonce));
    const Callbacks = struct {
        fn fail(_: std.mem.Allocator, _: *anyopaque, _: ?[]const u8) CallbackError!Decision {
            return error.OperationFailed;
        }

        fn invalid(
            allocator: std.mem.Allocator,
            _: *anyopaque,
            _: ?[]const u8,
        ) CallbackError!Decision {
            return .{ .write = allocator.dupe(u8, "not json") catch return error.OutOfMemory };
        }
    };
    var context: u8 = 0;
    try std.testing.expectError(error.OperationFailed, store.update(std.testing.allocator, "codex", .{
        .context = &context,
        .call_fn = Callbacks.fail,
    }));
    var invalid = try store.update(std.testing.allocator, "codex", .{
        .context = &context,
        .call_fn = Callbacks.invalid,
    });
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expect(invalid == .not_published);
    try std.testing.expectEqual(MutationCause.invalid_value, invalid.not_published.cause);
    try std.testing.expectEqualStrings("not json", invalid.not_published.action.write);
}

const UpdateFaultStage = enum { write, sync, rename, dir_sync };

fn updateFaultOps(stage: UpdateFaultStage) PrivateFileStore.CommitOps {
    const Failing = struct {
        fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
        fn sync(_: std.Io, _: ?*anyopaque, _: std.Io.File) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
        fn rename(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: []const u8,
        ) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
        fn dirSync(_: std.Io, _: ?*anyopaque, _: std.Io.Dir) PrivateFileStore.Error!void {
            return error.IoFailure;
        }
    };
    return switch (stage) {
        .write => .{ .write_fn = Failing.write },
        .sync => .{ .sync_fn = Failing.sync },
        .rename => .{ .rename_fn = Failing.rename },
        .dir_sync => .{ .dir_sync_fn = Failing.dirSync },
    };
}

const MatrixDecision = struct {
    remove: bool,

    fn call(
        allocator: std.mem.Allocator,
        context_ptr: *anyopaque,
        _: ?[]const u8,
    ) CallbackError!Decision {
        const context: *MatrixDecision = @ptrCast(@alignCast(context_ptr));
        if (context.remove) return .remove;
        return .{ .write = allocator.dupe(u8, "{\"token\":\"matrix\"}") catch
            return error.OutOfMemory };
    }
};

test "locked update remove and write publication fault matrix" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var nonce: u8 = 91;
    const private = PrivateFileStore.Store.init(io, temporary.dir);
    const standard = Store.init(private, testSource(&nonce));
    const stages = [_]UpdateFaultStage{ .write, .sync, .rename, .dir_sync };
    const names = [_][]const u8{ "write-fault", "sync-fault", "rename-fault", "dir-fault" };

    inline for (.{ false, true }) |remove| {
        for (stages, names) |stage, base_name| {
            var name_buffer: [32]u8 = undefined;
            const provider = std.fmt.bufPrint(
                &name_buffer,
                "{s}-{s}",
                .{ base_name, if (remove) "remove" else "write" },
            ) catch unreachable;
            if (remove) _ = try standard.set(std.testing.allocator, provider, "{\"old\":true}");
            var decision: MatrixDecision = .{ .remove = remove };
            const failing: Store = .{
                .private = private,
                .nonce_source = testSource(&nonce),
                .commit_ops = updateFaultOps(stage),
            };
            var result = try failing.update(std.testing.allocator, provider, .{
                .context = &decision,
                .call_fn = MatrixDecision.call,
            });
            defer result.deinit(std.testing.allocator);
            switch (stage) {
                .write, .sync => try std.testing.expect(result == .not_published),
                .rename, .dir_sync => try std.testing.expect(result == .uncertain),
            }
            const failure = switch (result) {
                .not_published => |value| value,
                .uncertain => |value| value,
                else => unreachable,
            };
            try std.testing.expectEqual(MutationCause.io_failure, failure.cause);
            try std.testing.expect(if (remove)
                failure.action == .remove
            else
                failure.action == .write);
        }
    }
}

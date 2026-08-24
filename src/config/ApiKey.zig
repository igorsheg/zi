const std = @import("std");

pub const maximum_secret_bytes: usize = 8 * 1024;

pub const Error = error{
    OutOfMemory,
    Cancelled,
    SecretTooLong,
    InvalidHeaderValue,
};

/// Borrowed environment view. Resolution never consults ambient process state.
/// The context and returned slice must remain valid for the synchronous call.
pub const Environment = struct {
    context: *const anyopaque,
    get_fn: *const fn (*const anyopaque, []const u8) ?[]const u8,

    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        return self.get_fn(self.context, name);
    }

    pub fn from(implementation: anytype) Environment {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Environment.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn get(context: *const anyopaque, name: []const u8) ?[]const u8 {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.get(name);
            }
        };
        return .{ .context = implementation, .get_fn = Adapter.get };
    }
};

/// Receives the final owned secret synchronously. It must not retain `value`.
pub const RedactionNotifier = struct {
    context: *anyopaque,
    register_fn: *const fn (*anyopaque, []const u8) error{ OutOfMemory, Cancelled }!void,

    pub fn register(self: RedactionNotifier, value: []const u8) error{ OutOfMemory, Cancelled }!void {
        return self.register_fn(self.context, value);
    }

    pub fn from(implementation: anytype) RedactionNotifier {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("RedactionNotifier.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn register(context: *anyopaque, value: []const u8) error{ OutOfMemory, Cancelled }!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.register(value);
            }
        };
        return .{ .context = implementation, .register_fn = Adapter.register };
    }
};

pub const Options = struct {
    /// Already-resolved provider config value. This layer only interprets its leading `$`.
    inline_value: ?[]const u8 = null,
    fallback_env_name: ?[]const u8 = null,
    environment: Environment,
    redaction_notifier: ?RedactionNotifier = null,
};

/// Allocator-owned, move-only API key. Do not copy it. Call `deinit` exactly
/// once with the allocator passed to `resolve`.
pub const Secret = struct {
    value: []u8,

    pub fn deinit(self: *Secret, allocator: std.mem.Allocator) void {
        @memset(self.value, 0);
        allocator.free(self.value);
        self.* = undefined;
    }
};

/// Resolves hax's generic-provider key precedence and returns an owned value.
///
/// Safety is deliberately narrower than hax: because provider keys become HTTP
/// header values, ASCII controls (including NUL, CR, LF, and DEL) are rejected.
/// The selected borrowed value is validated and copied before notification.
/// Allocation failure therefore causes no notification. If notification reports
/// cancellation or OOM, the owned copy is freed and that error wins.
pub fn resolve(allocator: std.mem.Allocator, options: Options) Error!?Secret {
    const selected = select(options) orelse return null;
    if (selected.len > maximum_secret_bytes) return error.SecretTooLong;
    for (selected) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidHeaderValue;
    }

    const owned = allocator.dupe(u8, selected) catch return error.OutOfMemory;
    errdefer {
        @memset(owned, 0);
        allocator.free(owned);
    }
    if (options.redaction_notifier) |notifier| try notifier.register(owned);
    return .{ .value = owned };
}

fn select(options: Options) ?[]const u8 {
    if (options.inline_value) |inline_value| {
        if (inline_value.len != 0) {
            if (inline_value[0] != '$') return inline_value;
            if (inline_value.len >= 2 and inline_value[1] == '$') return inline_value[1..];
            if (inline_value.len == 1) return selectFallback(options);
            const resolved = options.environment.get(inline_value[1..]);
            if (resolved) |value| if (value.len != 0) return value;
        }
    }
    return selectFallback(options);
}

fn selectFallback(options: Options) ?[]const u8 {
    if (options.fallback_env_name) |name| {
        if (options.environment.get(name)) |value| if (value.len != 0) return value;
    }
    return null;
}

const TestEnvironment = struct {
    entries: []const Entry,
    const Entry = struct { name: []const u8, value: []const u8 };

    fn get(self: *const TestEnvironment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};

fn expectValue(expected: []const u8, environment: *TestEnvironment, options: Options) !void {
    var actual_options = options;
    actual_options.environment = Environment.from(environment);
    var secret = (try resolve(std.testing.allocator, actual_options)).?;
    defer secret.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, secret.value);
}

test "inline literal and escaped dollar win without environment lookup" {
    var environment: TestEnvironment = .{ .entries = &.{.{ .name = "FALLBACK", .value = "fallback" }} };
    try expectValue("inline", &environment, .{
        .inline_value = "inline",
        .fallback_env_name = "FALLBACK",
        .environment = undefined,
    });

    try expectValue("$literal", &environment, .{
        .inline_value = "$$literal",
        .fallback_env_name = "FALLBACK",
        .environment = undefined,
    });
}

test "named inline environment value wins over fallback" {
    var environment: TestEnvironment = .{ .entries = &.{
        .{ .name = "NAMED", .value = "named" },
        .{ .name = "FALLBACK", .value = "fallback" },
    } };
    try expectValue("named", &environment, .{
        .inline_value = "$NAMED",
        .fallback_env_name = "FALLBACK",
        .environment = undefined,
    });
}

test "empty inline forms and empty or unset named values fall through" {
    const cases = [_]?[]const u8{ null, "", "$EMPTY", "$UNSET", "$" };
    for (cases) |inline_value| {
        var environment: TestEnvironment = .{ .entries = &.{
            .{ .name = "", .value = "must-not-win" },
            .{ .name = "EMPTY", .value = "" },
            .{ .name = "FALLBACK", .value = "fallback" },
        } };
        try expectValue("fallback", &environment, .{
            .inline_value = inline_value,
            .fallback_env_name = "FALLBACK",
            .environment = undefined,
        });
    }
}

test "empty fallback is missing" {
    var environment: TestEnvironment = .{ .entries = &.{.{ .name = "EMPTY", .value = "" }} };
    const missing = try resolve(std.testing.allocator, .{
        .inline_value = "$UNSET",
        .fallback_env_name = "EMPTY",
        .environment = Environment.from(&environment),
    });
    try std.testing.expect(missing == null);
}

test "selected value is bounded and header safe" {
    var maximum = [_]u8{'a'} ** maximum_secret_bytes;
    var environment: TestEnvironment = .{ .entries = &.{} };
    try expectValue(&maximum, &environment, .{
        .inline_value = &maximum,
        .environment = undefined,
    });

    var oversized = [_]u8{'a'} ** (maximum_secret_bytes + 1);
    try std.testing.expectError(error.SecretTooLong, resolve(std.testing.allocator, .{
        .inline_value = &oversized,
        .environment = Environment.from(&environment),
    }));

    const invalid = [_][]const u8{ "nul\x00value", "line\rvalue", "line\nvalue", "tab\tvalue", "del\x7fvalue" };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidHeaderValue, resolve(std.testing.allocator, .{
            .inline_value = value,
            .environment = Environment.from(&environment),
        }));
    }
}

test "result owns selected bytes after source buffers mutate" {
    var inline_value = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var environment: TestEnvironment = .{ .entries = &.{} };
    var secret = (try resolve(std.testing.allocator, .{
        .inline_value = &inline_value,
        .environment = Environment.from(&environment),
    })).?;
    defer secret.deinit(std.testing.allocator);
    @memset(&inline_value, 'x');
    try std.testing.expectEqualStrings("secret", secret.value);
}

const TestNotifier = struct {
    calls: usize = 0,
    source_pointer: [*]const u8,
    saw_owned_copy: bool = false,
    failure: ?error{ OutOfMemory, Cancelled } = null,

    fn register(self: *TestNotifier, value: []const u8) error{ OutOfMemory, Cancelled }!void {
        self.calls += 1;
        self.saw_owned_copy = value.ptr != self.source_pointer;
        if (self.failure) |failure| return failure;
    }
};

test "redaction observes owned value and its error releases the copy" {
    var source = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var environment: TestEnvironment = .{ .entries = &.{} };
    var notifier: TestNotifier = .{ .source_pointer = source[0..].ptr };
    var secret = (try resolve(std.testing.allocator, .{
        .inline_value = &source,
        .environment = Environment.from(&environment),
        .redaction_notifier = RedactionNotifier.from(&notifier),
    })).?;
    secret.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, notifier.calls);
    try std.testing.expect(notifier.saw_owned_copy);

    notifier.failure = error.Cancelled;
    try std.testing.expectError(error.Cancelled, resolve(std.testing.allocator, .{
        .inline_value = &source,
        .environment = Environment.from(&environment),
        .redaction_notifier = RedactionNotifier.from(&notifier),
    }));

    notifier.failure = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, resolve(std.testing.allocator, .{
        .inline_value = &source,
        .environment = Environment.from(&environment),
        .redaction_notifier = RedactionNotifier.from(&notifier),
    }));
}

test "allocation OOM happens before redaction notification" {
    var environment: TestEnvironment = .{ .entries = &.{} };
    var notifier: TestNotifier = .{ .source_pointer = "secret".ptr };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resolve(failing.allocator(), .{
        .inline_value = "secret",
        .environment = Environment.from(&environment),
        .redaction_notifier = RedactionNotifier.from(&notifier),
    }));
    try std.testing.expectEqual(0, notifier.calls);
}

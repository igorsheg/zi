const std = @import("std");
const ai = @import("ai/root.zig");
const config = @import("config/root.zig");

const Definition = config.ProviderDefinitions.Definition;

pub const maximum_header_bytes: usize = 16 * 1024;

pub const WarningKind = enum {
    missing_environment,
    invalid_resolved_value,
    protocol_owned,
    duplicate,
};

pub const Warning = struct {
    kind: WarningKind,
    name: []u8,
    environment_name: ?[]u8 = null,
};

/// Allocator-owned header resolution. Move this value, never copy it. Header
/// values sourced from the environment are privileged. Credential header names
/// remain privileged through `Transport.Header.isPrivileged` regardless of source.
pub const Resolution = struct {
    headers: []ai.Transport.Header,
    warnings: []Warning,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        for (self.headers) |header| deinitHeader(allocator, header);
        allocator.free(self.headers);
        for (self.warnings) |warning| deinitWarning(allocator, warning);
        allocator.free(self.warnings);
        self.* = undefined;
    }
};

/// Resolves one selected provider definition without ambient environment access.
/// Every returned byte belongs to `allocator` and remains valid until `deinit`.
pub fn resolve(
    allocator: std.mem.Allocator,
    definition: ?Definition,
    environment: config.ApiKey.Environment,
) !Resolution {
    const source = if (definition) |value| value.extra_headers orelse &.{} else &.{};
    if (source.len > ai.JsonTransport.maximum_headers) return error.InvalidHeaderValue;
    var source_bytes: usize = 0;
    for (source) |header| {
        source_bytes = std.math.add(usize, source_bytes, header.name.len) catch
            return error.InvalidHeaderValue;
        source_bytes = std.math.add(usize, source_bytes, header.value.len) catch
            return error.InvalidHeaderValue;
        if (source_bytes > maximum_header_bytes) return error.InvalidHeaderValue;
    }
    var headers: std.ArrayList(ai.Transport.Header) = .empty;
    defer headers.deinit(allocator);
    errdefer for (headers.items) |header| deinitHeader(allocator, header);
    var warnings: std.ArrayList(Warning) = .empty;
    defer warnings.deinit(allocator);
    errdefer for (warnings.items) |warning| deinitWarning(allocator, warning);

    var retained_bytes: usize = 0;
    for (source) |header| {
        if (ai.Transport.headerIsProtocolOwned(header.name)) {
            try appendWarning(allocator, &warnings, .protocol_owned, header.name, null);
            continue;
        }
        var duplicate = false;
        for (headers.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, header.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try appendWarning(allocator, &warnings, .duplicate, header.name, null);
            continue;
        }

        const resolved = resolveValue(header.value, environment) orelse {
            try appendWarning(
                allocator,
                &warnings,
                .missing_environment,
                header.name,
                if (header.value.len > 1) header.value[1..] else "",
            );
            continue;
        };
        if (resolved.value.len == 0 or !headerValueValid(resolved.value)) {
            try appendWarning(allocator, &warnings, .invalid_resolved_value, header.name, null);
            continue;
        }
        if (headers.items.len == ai.JsonTransport.maximum_headers) return error.InvalidHeaderValue;
        retained_bytes = std.math.add(usize, retained_bytes, header.name.len) catch
            return error.InvalidHeaderValue;
        retained_bytes = std.math.add(usize, retained_bytes, resolved.value.len) catch
            return error.InvalidHeaderValue;
        if (retained_bytes > maximum_header_bytes) return error.InvalidHeaderValue;

        const name = try allocator.dupe(u8, header.name);
        const value = allocator.dupe(u8, resolved.value) catch |err| {
            allocator.free(name);
            return err;
        };
        headers.append(allocator, .{
            .name = name,
            .value = value,
            .privileged = resolved.privileged,
        }) catch |err| {
            allocator.free(name);
            std.crypto.secureZero(u8, value);
            allocator.free(value);
            return err;
        };
    }
    const owned_headers = try headers.toOwnedSlice(allocator);
    errdefer {
        for (owned_headers) |header| deinitHeader(allocator, header);
        allocator.free(owned_headers);
    }
    return .{
        .headers = owned_headers,
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

pub fn findDefinition(definitions: []const Definition, id: []const u8) ?Definition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.id, id)) return definition;
    }
    return null;
}

fn appendWarning(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList(Warning),
    kind: WarningKind,
    name: []const u8,
    environment_name: ?[]const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    const owned_environment = if (environment_name) |value|
        allocator.dupe(u8, value) catch |err| {
            allocator.free(owned_name);
            return err;
        }
    else
        null;
    warnings.append(allocator, .{
        .kind = kind,
        .name = owned_name,
        .environment_name = owned_environment,
    }) catch |err| {
        allocator.free(owned_name);
        if (owned_environment) |value| allocator.free(value);
        return err;
    };
}

fn deinitWarning(allocator: std.mem.Allocator, warning: Warning) void {
    allocator.free(warning.name);
    if (warning.environment_name) |value| allocator.free(value);
}

fn deinitHeader(allocator: std.mem.Allocator, header: ai.Transport.Header) void {
    allocator.free(header.name);
    const value = @constCast(header.value);
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

const ResolvedValue = struct {
    value: []const u8,
    privileged: bool,
};

fn resolveValue(value: []const u8, environment: config.ApiKey.Environment) ?ResolvedValue {
    if (value.len == 0 or value[0] != '$') return .{ .value = value, .privileged = false };
    if (value.len >= 2 and value[1] == '$') return .{ .value = value[1..], .privileged = false };
    const resolved = environment.get(value[1..]) orelse return null;
    return if (resolved.len == 0) null else .{ .value = resolved, .privileged = true };
}

fn headerValueValid(value: []const u8) bool {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

const TestEnvironment = struct {
    entries: []const Entry,

    const Entry = struct { name: []const u8, value: []const u8 };

    pub fn get(self: *const TestEnvironment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
    }
};

test "provider headers resolve escapes and retain independent warnings" {
    const environment: TestEnvironment = .{ .entries = &.{
        .{ .name = "TOKEN", .value = "secret" },
        .{ .name = "BAD", .value = "line\nbreak" },
    } };
    var missing_name = "X-Missing".*;
    var missing_value = "$MISSING".*;
    var source = [_]config.ProviderDefinitions.Header{
        .{ .name = @constCast("X-Token"), .value = @constCast("$TOKEN") },
        .{ .name = @constCast("X-Literal"), .value = @constCast("$$cash") },
        .{ .name = &missing_name, .value = &missing_value },
        .{ .name = @constCast("Content-Type"), .value = @constCast("text/plain") },
        .{ .name = @constCast("X-Bad"), .value = @constCast("$BAD") },
        .{ .name = @constCast("x-token"), .value = @constCast("duplicate") },
    };
    const definition: Definition = .{
        .id = @constCast("gateway"),
        .extra_headers = &source,
    };
    var resolution = try resolve(
        std.testing.allocator,
        definition,
        config.ApiKey.Environment.from(&environment),
    );
    defer resolution.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), resolution.headers.len);
    try std.testing.expectEqualStrings("X-Token", resolution.headers[0].name);
    try std.testing.expectEqualStrings("secret", resolution.headers[0].value);
    try std.testing.expect(resolution.headers[0].isPrivileged());
    try std.testing.expectEqualStrings("$cash", resolution.headers[1].value);
    try std.testing.expect(!resolution.headers[1].isPrivileged());
    try std.testing.expectEqual(@as(usize, 4), resolution.warnings.len);
    @memset(&missing_name, 'x');
    @memset(&missing_value, 'x');
    try std.testing.expectEqualStrings("X-Missing", resolution.warnings[0].name);
    try std.testing.expectEqualStrings("MISSING", resolution.warnings[0].environment_name.?);
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const environment: TestEnvironment = .{ .entries = &.{.{ .name = "TOKEN", .value = "secret" }} };
    const source = [_]config.ProviderDefinitions.Header{
        .{ .name = @constCast("X-Token"), .value = @constCast("$TOKEN") },
        .{ .name = @constCast("X-Missing"), .value = @constCast("$MISSING") },
    };
    const definition: Definition = .{
        .id = @constCast("gateway"),
        .extra_headers = @constCast(&source),
    };
    var resolution = try resolve(allocator, definition, config.ApiKey.Environment.from(&environment));
    defer resolution.deinit(allocator);
}

test "provider header resolution checks every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

const std = @import("std");
const Effort = @import("Effort.zig");
const ModelMeta = @import("ModelMeta.zig");

pub const maximum_input_bytes: usize = 4 * 1024 * 1024;
pub const maximum_models: usize = 4_096;
pub const maximum_id_bytes: usize = 1_024;
pub const maximum_description_bytes: usize = 16 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 65_536;
pub const maximum_json_work: usize = 262_144;

pub const Limits = struct {
    max_input_bytes: usize = maximum_input_bytes,
    max_models: usize = maximum_models,
    max_id_bytes: usize = maximum_id_bytes,
    max_description_bytes: usize = maximum_description_bytes,
    max_json_depth: usize = maximum_json_depth,
    max_json_fields: usize = maximum_json_fields,
    max_json_work: usize = maximum_json_work,
};

pub const default_limits: Limits = .{};

pub const Error = error{
    OutOfMemory,
    InvalidResponse,
    ResponseTooLarge,
};

pub const ListedModel = struct {
    id: []u8,
    description: ?[]u8 = null,
    metadata: ModelMeta.Metadata = .{},
};

/// Owns every model id and description. `deinit` invalidates the whole list.
pub const OwnedList = struct {
    allocator: std.mem.Allocator,
    models: []ListedModel,

    pub fn deinit(self: *OwnedList) void {
        for (self.models) |model| {
            self.allocator.free(model.id);
            if (model.description) |description| self.allocator.free(description);
        }
        self.allocator.free(self.models);
        self.* = undefined;
    }
};

/// Parses the exact object returned by the Codex model catalog endpoint.
/// Unknown members and wrong-shaped optional fields are ignored, matching
/// hax while the complete document remains bounded.
pub fn parse(
    allocator: std.mem.Allocator,
    json: []const u8,
    limits: Limits,
) Error!OwnedList {
    try validateLimits(limits);
    if (json.len > limits.max_input_bytes) return error.ResponseTooLarge;
    if (!std.unicode.utf8ValidateSlice(json)) return error.InvalidResponse;
    try validateJsonWork(json, limits);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();

    const root = valueObject(parsed.value) orelse return error.InvalidResponse;
    const models_value = root.get("models") orelse return error.InvalidResponse;
    if (models_value != .array) return error.InvalidResponse;
    const entries = models_value.array.items;
    if (entries.len > limits.max_models) return error.ResponseTooLarge;

    var result: std.ArrayList(ListedModel) = .empty;
    errdefer deinitModels(allocator, &result);
    try result.ensureTotalCapacity(allocator, entries.len);

    var slug_count: usize = 0;
    for (entries) |entry_value| {
        const entry = valueObject(entry_value) orelse continue;
        const slug = optionalString(entry, "slug");
        if (slug == null or slug.?.len == 0) continue;
        if (slug.?.len > limits.max_id_bytes) return error.ResponseTooLarge;
        slug_count += 1;

        const visibility = optionalString(entry, "visibility");
        if (visibility != null and std.mem.eql(u8, visibility.?, "hide")) continue;

        var listed: ListedModel = .{
            .id = allocator.dupe(u8, slug.?) catch return error.OutOfMemory,
        };
        errdefer {
            allocator.free(listed.id);
            if (listed.description) |description| allocator.free(description);
        }
        try parseMetadata(allocator, entry, limits, &listed);
        result.appendAssumeCapacity(listed);
    }
    if (entries.len != 0 and slug_count == 0) return error.InvalidResponse;
    return .{
        .allocator = allocator,
        .models = result.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_input_bytes == 0 or limits.max_input_bytes > maximum_input_bytes or
        limits.max_models == 0 or limits.max_models > maximum_models or
        limits.max_id_bytes == 0 or limits.max_id_bytes > maximum_id_bytes or
        limits.max_description_bytes == 0 or
        limits.max_description_bytes > maximum_description_bytes or
        limits.max_json_depth == 0 or limits.max_json_depth > maximum_json_depth or
        limits.max_json_fields == 0 or limits.max_json_fields > maximum_json_fields or
        limits.max_json_work == 0 or limits.max_json_work > maximum_json_work)
    {
        return error.InvalidResponse;
    }
}

fn validateJsonWork(json: []const u8, limits: Limits) Error!void {
    var depth: usize = 0;
    var fields: usize = 0;
    var work: usize = 0;
    var in_string = false;
    var escaped = false;
    for (json) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                work += 1;
                if (depth > limits.max_json_depth) return error.ResponseTooLarge;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidResponse;
                depth -= 1;
            },
            ':' => {
                fields += 1;
                work += 1;
                if (fields > limits.max_json_fields) return error.ResponseTooLarge;
            },
            ',' => work += 1,
            else => {},
        }
        if (work > limits.max_json_work) return error.ResponseTooLarge;
    }
    if (in_string or depth != 0) return error.InvalidResponse;
}

fn parseMetadata(
    allocator: std.mem.Allocator,
    entry: std.json.ObjectMap,
    limits: Limits,
    listed: *ListedModel,
) Error!void {
    const context = positiveIntegerOrFallback(entry, "context_window", "max_context_window");
    listed.metadata.context_window = context;

    if (entry.get("input_modalities")) |modalities_value| {
        if (modalities_value == .array) {
            listed.metadata.image_input = .no;
            for (modalities_value.array.items) |modality_value| {
                if (modality_value == .string and
                    std.mem.eql(u8, modality_value.string, "image"))
                {
                    listed.metadata.image_input = .yes;
                }
            }
        }
    }

    if (optionalString(entry, "description")) |description| {
        if (description.len > limits.max_description_bytes) return error.ResponseTooLarge;
        if (description.len != 0) {
            listed.description = allocator.dupe(u8, description) catch return error.OutOfMemory;
        }
    }

    listed.metadata.efforts = try parseEfforts(entry);
}

fn positiveIntegerOrFallback(
    object: std.json.ObjectMap,
    primary_name: []const u8,
    fallback_name: []const u8,
) u64 {
    if (positiveInteger(object.get(primary_name))) |value| return value;
    return positiveInteger(object.get(fallback_name)) orelse 0;
}

fn positiveInteger(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0) return null;
    return @intCast(present.integer);
}

fn parseEfforts(entry: std.json.ObjectMap) Error!Effort.Set {
    const levels_value = entry.get("supported_reasoning_levels") orelse return .{};
    if (levels_value != .array) return .{};
    if (levels_value.array.items.len == 0) return Effort.Set.init(&.{}) catch unreachable;

    var result = Effort.Set.init(&.{"none"}) catch unreachable;
    for (levels_value.array.items) |level| {
        const effort = switch (level) {
            .string => |value| value,
            .object => |object| optionalString(object, "effort") orelse continue,
            else => continue,
        };
        if (std.mem.eql(u8, effort, "ultra")) continue;
        result.add(effort) catch continue;
    }
    return result;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn deinitModels(allocator: std.mem.Allocator, models: *std.ArrayList(ListedModel)) void {
    for (models.items) |model| {
        allocator.free(model.id);
        if (model.description) |description| allocator.free(description);
    }
    models.deinit(allocator);
}

const golden_catalog =
    \\{"models":[
    \\ {"slug":"gpt-5.4","context_window":272000,"max_context_window":1000000,
    \\  "input_modalities":["text","image"],"description":"Strong model for everyday coding.",
    \\  "supported_reasoning_levels":[{"effort":"high"},{"effort":"low"},
    \\   {"effort":"ultra"},{"effort":"xhigh"},{"effort":"max"},{"effort":"medium"}]},
    \\ {"slug":"legacy","max_context_window":400000,"input_modalities":["text"],
    \\  "supported_reasoning_levels":["low","custom"]},
    \\ {"slug":"hidden","visibility":"hide"},
    \\ {"slug":""}
    \\]}
;

test "golden hax Codex catalog behavior" {
    var list = try parse(std.testing.allocator, golden_catalog, .{});
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.models.len);

    const modern = list.models[0];
    try std.testing.expectEqualStrings("gpt-5.4", modern.id);
    try std.testing.expectEqualStrings("Strong model for everyday coding.", modern.description.?);
    try std.testing.expectEqual(@as(u64, 272_000), modern.metadata.context_window);
    try std.testing.expectEqual(ModelMeta.Support.yes, modern.metadata.image_input);
    const expected = [_][]const u8{ "none", "high", "low", "xhigh", "max", "medium" };
    try expectEfforts(&modern.metadata.efforts, &expected);

    const legacy = list.models[1];
    try std.testing.expectEqual(@as(u64, 400_000), legacy.metadata.context_window);
    try std.testing.expectEqual(ModelMeta.Support.no, legacy.metadata.image_input);
    const legacy_expected = [_][]const u8{ "none", "low", "custom" };
    try expectEfforts(&legacy.metadata.efforts, &legacy_expected);
}

test "effort metadata preserves absent and known empty" {
    var list = try parse(
        std.testing.allocator,
        "{\"models\":[{\"slug\":\"absent\"},{\"slug\":\"empty\",\"supported_reasoning_levels\":[]}]}",
        .{},
    );
    defer list.deinit();
    try std.testing.expect(!list.models[0].metadata.efforts.known);
    try std.testing.expect(list.models[1].metadata.efforts.known);
    try std.testing.expectEqual(@as(u8, 0), list.models[1].metadata.efforts.count);
}

test "catalog skips malformed entries and tolerates optional field drift like hax" {
    inline for (.{ "[]", "{}", "{\"models\":{}}" }) |fixture| {
        try std.testing.expectError(error.InvalidResponse, parse(std.testing.allocator, fixture, .{}));
    }

    try std.testing.expectError(
        error.InvalidResponse,
        parse(
            std.testing.allocator,
            "{\"models\":[null,{\"slug\":7},{\"slug\":\"\"}]}",
            .{},
        ),
    );

    var list = try parse(
        std.testing.allocator,
        "{\"models\":[null,{\"slug\":7},{\"slug\":\"x\",\"visibility\":false," ++
            "\"context_window\":1.5,\"input_modalities\":[7],\"description\":false," ++
            "\"supported_reasoning_levels\":[{}]},{\"slug\":\"x\"}]}",
        .{},
    );
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.models.len);
    try std.testing.expectEqualStrings("x", list.models[0].id);
    try std.testing.expectEqual(ModelMeta.Support.no, list.models[0].metadata.image_input);
    try std.testing.expect(list.models[0].metadata.efforts.known);
    try std.testing.expectEqual(@as(usize, 1), list.models[0].metadata.efforts.count);

    var duplicate_key = try parse(
        std.testing.allocator,
        "{\"models\":[{\"slug\":\"old\"}],\"models\":[]}",
        .{},
    );
    defer duplicate_key.deinit();
    try std.testing.expectEqual(@as(usize, 0), duplicate_key.models.len);
}

test "unknown fields are forward compatible and only hidden models is valid" {
    var list = try parse(
        std.testing.allocator,
        "{\"new_root\":true,\"models\":[{\"slug\":\"x\",\"visibility\":\"hide\",\"new\":{\"x\":1}}]}",
        .{},
    );
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.models.len);
}

test "input text and configured bounds are enforced" {
    const invalid_utf8 = [_]u8{ '{', '"', 'm', 'o', 'd', 'e', 'l', 's', '"', ':', '[', 0xff, ']', '}' };
    try std.testing.expectError(error.InvalidResponse, parse(std.testing.allocator, &invalid_utf8, .{}));
    try std.testing.expectError(
        error.ResponseTooLarge,
        parse(std.testing.allocator, "{\"models\":[]}", .{ .max_input_bytes = 4 }),
    );
    try std.testing.expectError(
        error.ResponseTooLarge,
        parse(std.testing.allocator, "{\"models\":[{\"slug\":\"long\"}]}", .{ .max_id_bytes = 3 }),
    );
    try std.testing.expectError(
        error.ResponseTooLarge,
        parse(
            std.testing.allocator,
            "{\"models\":[{\"slug\":\"x\",\"description\":\"long\"}]}",
            .{ .max_description_bytes = 3 },
        ),
    );
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var list = try parse(allocator, golden_catalog, .{});
    list.deinit();
}

test "all parser allocations are released on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

fn expectEfforts(actual: *const Effort.Set, expected: []const []const u8) !void {
    try std.testing.expect(actual.known);
    try std.testing.expectEqual(expected.len, actual.count);
    for (expected, 0..) |effort, index| {
        try std.testing.expectEqualStrings(effort, actual.valueAt(index));
    }
}

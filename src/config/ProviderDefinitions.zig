const std = @import("std");
const Document = @import("Document.zig");

pub const maximum_definitions: usize = 4096;
pub const maximum_warnings: usize = Document.maximum_fields;
pub const maximum_retained_bytes: usize = 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    TooManyDefinitions,
    TooManyWarnings,
    RetainedDataTooLarge,
};

pub const Documents = struct {
    config: ?*const Document = null,
    state: ?*const Document = null,
};

pub const Api = enum {
    openai_completions,
    openai_responses,
    anthropic_messages,
    catalog,

    pub fn id(self: Api) []const u8 {
        return switch (self) {
            .openai_completions => "openai-completions",
            .openai_responses => "openai-responses",
            .anthropic_messages => "anthropic-messages",
            .catalog => "catalog",
        };
    }
};

pub const TriState = enum { auto, off, on };
pub const CacheTtl = enum { five_minutes, one_hour };

pub const ModelApi = struct {
    pattern: []u8,
    api: Api,

    fn deinit(self: *ModelApi, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }
};

pub const Header = struct {
    name: []u8,
    /// The written value is retained. `$VAR` is deliberately not resolved here.
    value: []u8,

    fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        std.crypto.secureZero(u8, self.value);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const WarningReason = enum {
    invalid_provider_id,
    dotted_name,
    unknown_field,
    wrong_dialect,
    non_scalar,
    invalid_api,
    invalid_boolean,
    invalid_integer,
    invalid_cache_ttl,
    expected_object,
    invalid_model_api,
    invalid_header_name,
    invalid_header_value,
};

pub const Warning = struct {
    provider: []u8,
    field: ?[]u8,
    reason: WarningReason,

    pub fn deinit(self: *Warning, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        if (self.field) |field| allocator.free(field);
        self.* = undefined;
    }

    fn retainedBytes(self: *const Warning) usize {
        return self.provider.len + if (self.field) |field| field.len else 0;
    }
};

/// Owned syntax-level definition. Missing and malformed values both produce a
/// null typed field; malformed values additionally produce a warning. Empty
/// scalar strings remain present. Structured values also retain canonical JSON
/// so later provider layers can preserve members they do not interpret.
pub const Definition = struct {
    id: []u8,
    api: ?Api = null,
    /// True when `api` was present but could not be parsed.
    api_invalid: bool = false,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    api_key_env: ?[]u8 = null,
    display_name: ?[]u8 = null,
    catalog_id: ?[]u8 = null,
    sort_models: ?bool = null,
    model_apis: ?[]ModelApi = null,
    /// True when a nonempty model_apis object was declared, even if all rules were invalid.
    model_apis_declared_nonempty: bool = false,
    model_apis_json: ?[]u8 = null,
    cache: ?TriState = null,
    cache_ttl: ?CacheTtl = null,
    send_cache_key: ?TriState = null,
    request_cost: ?TriState = null,
    reasoning_format: ?[]u8 = null,
    reasoning_roundtrip: ?[]u8 = null,
    max_tokens: ?u64 = null,
    thinking_mode: ?[]u8 = null,
    thinking_budget: ?u64 = null,
    version: ?[]u8 = null,
    extra_body_json: ?[]u8 = null,
    extra_headers: ?[]Header = null,
    extra_headers_json: ?[]u8 = null,

    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.api_key) |value| std.crypto.secureZero(u8, value);
        if (self.extra_headers_json) |value| std.crypto.secureZero(u8, value);
        inline for (.{
            &self.base_url,
            &self.api_key,
            &self.api_key_env,
            &self.display_name,
            &self.catalog_id,
            &self.reasoning_format,
            &self.reasoning_roundtrip,
            &self.thinking_mode,
            &self.version,
            &self.model_apis_json,
            &self.extra_body_json,
            &self.extra_headers_json,
        }) |value| if (value.*) |bytes| allocator.free(bytes);
        if (self.model_apis) |rules| {
            for (rules) |*rule| rule.deinit(allocator);
            allocator.free(rules);
        }
        if (self.extra_headers) |headers| {
            for (headers) |*header| header.deinit(allocator);
            allocator.free(headers);
        }
        self.* = undefined;
    }

    pub fn retainedBytes(self: *const Definition) usize {
        var total = self.id.len;
        inline for (.{
            self.base_url,
            self.api_key,
            self.api_key_env,
            self.display_name,
            self.catalog_id,
            self.reasoning_format,
            self.reasoning_roundtrip,
            self.thinking_mode,
            self.version,
            self.model_apis_json,
            self.extra_body_json,
            self.extra_headers_json,
        }) |value| {
            if (value) |bytes| total += bytes.len;
        }
        if (self.model_apis) |rules| {
            for (rules) |rule| total += rule.pattern.len;
        }
        if (self.extra_headers) |headers| {
            for (headers) |header| total += header.name.len + header.value.len;
        }
        return total;
    }
};

const WipingAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        if (new_len < memory.len) return false;
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
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
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const Owner = struct {
    parent_allocator: std.mem.Allocator,
    wiping_allocator: WipingAllocator,
    arena: std.heap.ArenaAllocator,
};

pub const Enumeration = struct {
    definitions: []Definition,
    warnings: []Warning,
    owner: *Owner,

    pub fn deinit(self: *Enumeration) void {
        const owner = self.owner;
        const parent_allocator = owner.parent_allocator;
        owner.arena.deinit();
        owner.* = undefined;
        parent_allocator.destroy(owner);
        self.* = undefined;
    }
};

/// Enumerates config names first, then names seen only in state. Values use the
/// normal persistent-tier precedence: state before config. Recipe overlay and
/// provider behavior are deliberately outside this module.
pub fn enumerate(parent_allocator: std.mem.Allocator, documents: Documents) Error!Enumeration {
    const owner = try parent_allocator.create(Owner);
    errdefer parent_allocator.destroy(owner);
    owner.parent_allocator = parent_allocator;
    owner.wiping_allocator = .{ .backing = parent_allocator };
    owner.arena = .init(owner.wiping_allocator.allocator());
    errdefer owner.arena.deinit();
    const allocator = owner.arena.allocator();

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    if (documents.config) |document| try appendNames(allocator, document, &names, &seen);
    if (documents.state) |document| try appendNames(allocator, document, &names, &seen);
    if (names.items.len > maximum_definitions) return error.TooManyDefinitions;

    var definitions: std.ArrayList(Definition) = .empty;
    errdefer {
        for (definitions.items) |*definition| definition.deinit(allocator);
        definitions.deinit(allocator);
    }
    var warnings: std.ArrayList(Warning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(allocator);
        warnings.deinit(allocator);
    }

    for (names.items) |name| {
        if (name.len == 0 or name.len > 63) {
            try appendWarning(allocator, &warnings, name, null, .invalid_provider_id);
            continue;
        }
        if (std.mem.indexOfScalar(u8, name, '.') != null) {
            try appendWarning(allocator, &warnings, name, null, .dotted_name);
            continue;
        }
        var valid = true;
        for (name) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) {
                valid = false;
                break;
            }
        }
        if (!valid) {
            try appendWarning(allocator, &warnings, name, null, .invalid_provider_id);
            continue;
        }
        var definition = try parseDefinition(allocator, documents, name, &warnings);
        errdefer definition.deinit(allocator);
        try definitions.append(allocator, definition);
    }

    var retained: usize = 0;
    for (definitions.items) |*definition| try addRetained(&retained, definition.retainedBytes());
    for (warnings.items) |*warning| try addRetained(&retained, warning.retainedBytes());

    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned_definitions) |*definition| definition.deinit(allocator);
        allocator.free(owned_definitions);
    }
    const owned_warnings = try warnings.toOwnedSlice(allocator);
    return .{ .definitions = owned_definitions, .warnings = owned_warnings, .owner = owner };
}

fn appendNames(
    allocator: std.mem.Allocator,
    document: *const Document,
    names: *std.ArrayList([]u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const keys = try document.objectKeys(allocator, "providers");
    defer Document.freeObjectKeys(allocator, keys);
    for (keys) |key| {
        if (seen.contains(key)) continue;
        const copy = try allocator.dupe(u8, key);
        errdefer allocator.free(copy);
        try seen.put(allocator, copy, {});
        try names.append(allocator, copy);
    }
}

const Field = struct { name: []const u8, dialects: u8 };
const chat: u8 = 1;
const responses: u8 = 2;
const anthropic: u8 = 4;
const config_defined: u8 = 8;
const any_wire: u8 = chat | responses | anthropic;
const fields = [_]Field{
    .{ .name = "api", .dialects = chat | responses | config_defined },
    .{ .name = "base_url", .dialects = any_wire },
    .{ .name = "api_key", .dialects = any_wire },
    .{ .name = "api_key_env", .dialects = config_defined },
    .{ .name = "display_name", .dialects = any_wire },
    .{ .name = "catalog_id", .dialects = config_defined },
    .{ .name = "sort_models", .dialects = config_defined },
    .{ .name = "model_apis", .dialects = any_wire },
    .{ .name = "cache", .dialects = chat | anthropic },
    .{ .name = "cache_ttl", .dialects = chat | anthropic },
    .{ .name = "send_cache_key", .dialects = chat | responses },
    .{ .name = "request_cost", .dialects = chat },
    .{ .name = "reasoning_format", .dialects = chat },
    .{ .name = "reasoning_roundtrip", .dialects = chat },
    .{ .name = "max_tokens", .dialects = anthropic },
    .{ .name = "thinking_mode", .dialects = anthropic },
    .{ .name = "thinking_budget", .dialects = anthropic },
    .{ .name = "version", .dialects = anthropic },
    .{ .name = "extra_body", .dialects = any_wire },
    .{ .name = "extra_headers", .dialects = any_wire },
};

fn parseDefinition(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    warnings: *std.ArrayList(Warning),
) !Definition {
    var result: Definition = .{ .id = try allocator.dupe(u8, name) };
    errdefer result.deinit(allocator);

    result.api = try apiMember(allocator, documents, name, warnings);
    result.api_invalid = nodeFor(documents, name, "api") != null and result.api == null;
    result.model_apis_declared_nonempty = hasModelApis(documents, name);
    const routes_wires = result.model_apis_declared_nonempty or result.api == .catalog;
    try warnMembers(allocator, documents, name, result.api, routes_wires, warnings);

    result.base_url = try stringMember(allocator, documents, name, "base_url", warnings);
    result.api_key = try stringMember(allocator, documents, name, "api_key", warnings);
    result.api_key_env = try stringMember(allocator, documents, name, "api_key_env", warnings);
    result.display_name = try stringMember(allocator, documents, name, "display_name", warnings);
    result.catalog_id = try stringMember(allocator, documents, name, "catalog_id", warnings);
    result.sort_models = try boolMember(allocator, documents, name, "sort_models", warnings);
    try parseModelApis(allocator, documents, name, &result, warnings);
    result.cache = try triStateMember(allocator, documents, name, "cache", warnings);
    result.cache_ttl = try cacheTtlMember(allocator, documents, name, warnings);
    result.send_cache_key = try triStateMember(allocator, documents, name, "send_cache_key", warnings);
    result.request_cost = try triStateMember(allocator, documents, name, "request_cost", warnings);
    result.reasoning_format = try stringMember(allocator, documents, name, "reasoning_format", warnings);
    result.reasoning_roundtrip = try stringMember(allocator, documents, name, "reasoning_roundtrip", warnings);
    result.max_tokens = try integerMember(allocator, documents, name, "max_tokens", warnings);
    result.thinking_mode = try stringMember(allocator, documents, name, "thinking_mode", warnings);
    result.thinking_budget = try integerMember(allocator, documents, name, "thinking_budget", warnings);
    result.version = try stringMember(allocator, documents, name, "version", warnings);
    try parseExtraBody(allocator, documents, name, &result, warnings);
    try parseHeaders(allocator, documents, name, &result, warnings);
    return result;
}

fn nodeFor(documents: Documents, name: []const u8, leaf: []const u8) ?*const std.json.Value {
    var buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "providers.{s}.{s}", .{ name, leaf }) catch return null;
    if (documents.state) |document| if (document.lookup(key)) |value| return value;
    if (documents.config) |document| if (document.lookup(key)) |value| return value;
    return null;
}

fn scalarNodeFor(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    leaf: []const u8,
    warnings: *std.ArrayList(Warning),
) !?*const std.json.Value {
    var buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "providers.{s}.{s}", .{ name, leaf }) catch return null;
    if (documents.state) |document| if (document.lookup(key)) |value| {
        if (scalarShaped(value)) return value;
        try appendWarning(allocator, warnings, name, leaf, .non_scalar);
    };
    if (documents.config) |document| return document.lookup(key);
    return null;
}

fn scalarShaped(value: *const std.json.Value) bool {
    return switch (value.*) {
        .string, .integer, .float, .bool => true,
        else => false,
    };
}

fn hasModelApis(documents: Documents, name: []const u8) bool {
    const node = nodeFor(documents, name, "model_apis") orelse return false;
    return node.* == .object and node.object.count() != 0;
}

fn stringMember(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    leaf: []const u8,
    warnings: *std.ArrayList(Warning),
) !?[]u8 {
    const node = try scalarNodeFor(allocator, documents, name, leaf, warnings) orelse return null;
    const scalar = Document.scalarString(allocator, node) catch return error.OutOfMemory;
    return scalar orelse {
        try appendWarning(allocator, warnings, name, leaf, .non_scalar);
        return null;
    };
}

fn apiMember(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    warnings: *std.ArrayList(Warning),
) !?Api {
    const node = try scalarNodeFor(allocator, documents, name, "api", warnings) orelse return null;
    const text = try scalarProbe(allocator, node) orelse {
        try appendWarning(allocator, warnings, name, "api", .non_scalar);
        return null;
    };
    defer allocator.free(text);
    const parsed = parseApi(text, true) orelse {
        try appendWarning(allocator, warnings, name, "api", .invalid_api);
        return null;
    };
    return parsed;
}

fn boolMember(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    leaf: []const u8,
    warnings: *std.ArrayList(Warning),
) !?bool {
    const node = try scalarNodeFor(allocator, documents, name, leaf, warnings) orelse return null;
    const parsed = parseBoolean(node) orelse {
        try appendWarning(allocator, warnings, name, leaf, .invalid_boolean);
        return null;
    };
    return parsed;
}

fn triStateMember(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    leaf: []const u8,
    warnings: *std.ArrayList(Warning),
) !?TriState {
    const node = try scalarNodeFor(allocator, documents, name, leaf, warnings) orelse return null;
    if (node.* == .string and std.ascii.eqlIgnoreCase(node.string, "auto")) return .auto;
    const parsed = parseBoolean(node) orelse {
        try appendWarning(allocator, warnings, name, leaf, .invalid_boolean);
        return null;
    };
    return if (parsed) .on else .off;
}

fn cacheTtlMember(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    warnings: *std.ArrayList(Warning),
) !?CacheTtl {
    const node = try scalarNodeFor(allocator, documents, name, "cache_ttl", warnings) orelse return null;
    const text = try scalarProbe(allocator, node) orelse {
        try appendWarning(allocator, warnings, name, "cache_ttl", .non_scalar);
        return null;
    };
    defer allocator.free(text);
    if (std.ascii.eqlIgnoreCase(text, "5m")) return .five_minutes;
    if (std.ascii.eqlIgnoreCase(text, "1h")) return .one_hour;
    try appendWarning(allocator, warnings, name, "cache_ttl", .invalid_cache_ttl);
    return null;
}

fn integerMember(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    leaf: []const u8,
    warnings: *std.ArrayList(Warning),
) !?u64 {
    const node = try scalarNodeFor(allocator, documents, name, leaf, warnings) orelse return null;
    const text = try scalarProbe(allocator, node) orelse {
        try appendWarning(allocator, warnings, name, leaf, .non_scalar);
        return null;
    };
    defer allocator.free(text);
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n\x0b\x0c");
    const number = std.fmt.parseInt(i64, trimmed, 10) catch {
        try appendWarning(allocator, warnings, name, leaf, .invalid_integer);
        return null;
    };
    if (number < 1 or number > std.math.maxInt(i32)) {
        try appendWarning(allocator, warnings, name, leaf, .invalid_integer);
        return null;
    }
    return @intCast(number);
}

fn parseModelApis(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    result: *Definition,
    warnings: *std.ArrayList(Warning),
) !void {
    const node = nodeFor(documents, name, "model_apis") orelse return;
    result.model_apis_json = try canonicalJson(allocator, node);
    if (node.* != .object) {
        try appendWarning(allocator, warnings, name, "model_apis", .expected_object);
        return;
    }
    var rules: std.ArrayList(ModelApi) = .empty;
    errdefer {
        for (rules.items) |*rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }
    var iterator = node.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) {
            try appendWarning(allocator, warnings, name, "model_apis", .invalid_model_api);
            continue;
        }
        const api = parseApi(entry.value_ptr.string, false) orelse {
            try appendWarning(allocator, warnings, name, "model_apis", .invalid_model_api);
            continue;
        };
        const pattern = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(pattern);
        try rules.append(allocator, .{ .pattern = pattern, .api = api });
    }
    result.model_apis = try rules.toOwnedSlice(allocator);
}

fn parseExtraBody(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    result: *Definition,
    warnings: *std.ArrayList(Warning),
) !void {
    const node = nodeFor(documents, name, "extra_body") orelse return;
    result.extra_body_json = try canonicalJson(allocator, node);
    if (node.* != .object) try appendWarning(allocator, warnings, name, "extra_body", .expected_object);
}

fn parseHeaders(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    result: *Definition,
    warnings: *std.ArrayList(Warning),
) !void {
    const node = nodeFor(documents, name, "extra_headers") orelse return;
    result.extra_headers_json = try canonicalJson(allocator, node);
    if (node.* != .object) {
        try appendWarning(allocator, warnings, name, "extra_headers", .expected_object);
        return;
    }
    var headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers.items) |*header| header.deinit(allocator);
        headers.deinit(allocator);
    }
    var iterator = node.object.iterator();
    while (iterator.next()) |entry| {
        const header_name = entry.key_ptr.*;
        if (!headerNameValid(header_name)) {
            try appendWarning(allocator, warnings, name, "extra_headers", .invalid_header_name);
            continue;
        }
        if (entry.value_ptr.* != .string or !headerValueValid(entry.value_ptr.string)) {
            try appendWarning(allocator, warnings, name, "extra_headers", .invalid_header_value);
            continue;
        }
        const owned_name = try allocator.dupe(u8, header_name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, entry.value_ptr.string);
        errdefer allocator.free(owned_value);
        try headers.append(allocator, .{ .name = owned_name, .value = owned_value });
    }
    result.extra_headers = try headers.toOwnedSlice(allocator);
}

fn warnMembers(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
    api: ?Api,
    routes_wires: bool,
    warnings: *std.ArrayList(Warning),
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var iterator = seen.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit(allocator);
    }
    const ordered = [_]?*const Document{ documents.state, documents.config };
    for (ordered) |possible| if (possible) |document| {
        var buffer: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buffer, "providers.{s}", .{name}) catch return;
        const members = try document.objectKeys(allocator, prefix);
        defer Document.freeObjectKeys(allocator, members);
        for (members) |member| {
            if (seen.contains(member)) continue;
            const member_copy = try allocator.dupe(u8, member);
            errdefer allocator.free(member_copy);
            try seen.put(allocator, member_copy, {});
            const field = findField(member) orelse {
                try appendWarning(allocator, warnings, name, member, .unknown_field);
                continue;
            };
            const dialect = if (routes_wires)
                any_wire | config_defined
            else
                dialectFor(api orelse .openai_completions) | config_defined;
            if (field.dialects & dialect == 0)
                try appendWarning(allocator, warnings, name, member, .wrong_dialect);
        }
    };
}

fn dialectFor(api: Api) u8 {
    return switch (api) {
        .openai_completions, .catalog => chat,
        .openai_responses => responses,
        .anthropic_messages => anthropic,
    };
}

fn findField(name: []const u8) ?Field {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field;
    return null;
}

fn parseApi(text: []const u8, allow_catalog: bool) ?Api {
    if (std.ascii.eqlIgnoreCase(text, "openai-completions") or std.ascii.eqlIgnoreCase(text, "chat"))
        return .openai_completions;
    if (std.ascii.eqlIgnoreCase(text, "openai-responses") or std.ascii.eqlIgnoreCase(text, "responses"))
        return .openai_responses;
    if (std.ascii.eqlIgnoreCase(text, "anthropic-messages")) return .anthropic_messages;
    if (allow_catalog and std.ascii.eqlIgnoreCase(text, "catalog")) return .catalog;
    return null;
}

fn parseBoolean(value: *const std.json.Value) ?bool {
    return switch (value.*) {
        .bool => |boolean| boolean,
        .integer => |number| if (number == 1) true else if (number == 0) false else null,
        .float => |number| if (number == 1) true else if (number == 0) false else null,
        .string => |text| if (std.ascii.eqlIgnoreCase(text, "1") or
            std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or
            std.ascii.eqlIgnoreCase(text, "on")) true else if (std.ascii.eqlIgnoreCase(text, "0") or
            std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "no") or
            std.ascii.eqlIgnoreCase(text, "off")) false else null,
        else => null,
    };
}

fn scalarProbe(allocator: std.mem.Allocator, node: *const std.json.Value) !?[]u8 {
    return Document.scalarString(allocator, node);
}

fn canonicalJson(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, node.*, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn headerNameValid(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
            return false;
    }
    return true;
}

fn headerValueValid(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if ((byte < ' ' and byte != '\t') or byte == 0x7f) return false;
    return true;
}

fn appendWarning(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList(Warning),
    provider: []const u8,
    field: ?[]const u8,
    reason: WarningReason,
) !void {
    if (warnings.items.len == maximum_warnings) return error.TooManyWarnings;
    const owned_provider = try allocator.dupe(u8, provider);
    errdefer allocator.free(owned_provider);
    const owned_field = if (field) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_field) |value| allocator.free(value);
    try warnings.append(allocator, .{ .provider = owned_provider, .field = owned_field, .reason = reason });
}

fn addRetained(total: *usize, amount: usize) Error!void {
    total.* = std.math.add(usize, total.*, amount) catch return error.RetainedDataTooLarge;
    if (total.* > maximum_retained_bytes) return error.RetainedDataTooLarge;
}

test "enumeration preserves order, overlays fields, and rejects dotted ids" {
    var config = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"alpha\":{\"base_url\":\"config\",\"api_key\":7}," ++
            "\"bad.name\":{},\"gamma\":{}},\"providers.flat\":{\"display_name\":\"Flat\"}}",
        .{},
    );
    defer config.deinit();
    var state = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"alpha\":{\"base_url\":\"state\",\"api_key\":[]},\"delta\":{}}," ++
            "\"providers.flat.base_url\":\"flat-url\"}",
        .{},
    );
    defer state.deinit();
    var result = try enumerate(std.testing.allocator, .{ .config = &config, .state = &state });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.definitions.len);
    try std.testing.expectEqualStrings("alpha", result.definitions[0].id);
    try std.testing.expectEqualStrings("state", result.definitions[0].base_url.?);
    try std.testing.expectEqualStrings("7", result.definitions[0].api_key.?);
    try std.testing.expectEqualStrings("gamma", result.definitions[1].id);
    try std.testing.expectEqualStrings("flat", result.definitions[2].id);
    try std.testing.expectEqualStrings("flat-url", result.definitions[2].base_url.?);
    try std.testing.expectEqualStrings("delta", result.definitions[3].id);
    try std.testing.expect(result.warnings.len >= 1);
    var saw_dotted = false;
    for (result.warnings) |warning| if (warning.reason == .dotted_name) {
        saw_dotted = true;
    };
    try std.testing.expect(saw_dotted);
}

test "structured fields use state before config and keep compact JSON" {
    var config = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"gateway\":{\"api\":\"responses\",\"model_apis\":{" ++
            "\"claude-*\":\"anthropic-messages\"},\"extra_body\":{\"temperature\":0}," ++
            "\"extra_headers\":{\"Authorization\":\"$TOKEN\"}}}}",
        .{},
    );
    defer config.deinit();
    var state = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"gateway\":{\"extra_body\":{\"temperature\":1}," ++
            "\"extra_headers\":{\"X-Test\":\"ok\"}}}}",
        .{},
    );
    defer state.deinit();
    var result = try enumerate(std.testing.allocator, .{ .config = &config, .state = &state });
    defer result.deinit();
    const definition = &result.definitions[0];
    try std.testing.expectEqualStrings("{\"temperature\":1}", definition.extra_body_json.?);
    try std.testing.expectEqualStrings("{\"X-Test\":\"ok\"}", definition.extra_headers_json.?);
    try std.testing.expectEqual(@as(usize, 1), definition.extra_headers.?.len);
    try std.testing.expectEqualStrings("ok", definition.extra_headers.?[0].value);
    try std.testing.expectEqual(@as(usize, 1), definition.model_apis.?.len);
    try std.testing.expect(definition.model_apis.?[0].api == .anthropic_messages);
}

test "malformed and dialect-specific members warn without dropping definition" {
    var document = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"p\":{\"api\":\"openai-responses\",\"cache_ttl\":\"day\"," ++
            "\"max_tokens\":[],\"extra_body\":2,\"extra_headers\":{\"Bad Name\":\"x\"," ++
            "\"X-Empty\":\"\"},\"future\":true}}}",
        .{},
    );
    defer document.deinit();
    var result = try enumerate(std.testing.allocator, .{ .config = &document });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.definitions.len);
    try std.testing.expect(result.definitions[0].cache_ttl == null);
    try std.testing.expect(result.definitions[0].max_tokens == null);
    try std.testing.expect(result.definitions[0].extra_body_json != null);
    try std.testing.expect(result.warnings.len >= 6);
}

fn exerciseEnumerationAllocations(allocator: std.mem.Allocator) !void {
    var document = try Document.parse(allocator, "{\"providers\":{\"p\":{\"api_key\":\"secret\",\"model_apis\":{" ++
        "\"*\":\"chat\"},\"extra_headers\":{\"X-Key\":\"$KEY\"}}}}", .{});
    defer document.deinit();
    var result = try enumerate(allocator, .{ .config = &document });
    defer result.deinit();
}

test "enumeration is allocation-failure safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseEnumerationAllocations,
        .{},
    );
}

test "definition count is bounded atomically" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try json.appendSlice(std.testing.allocator, "{\"providers\":{");
    for (0..maximum_definitions + 1) |index| {
        if (index != 0) try json.append(std.testing.allocator, ',');
        var buffer: [32]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buffer, "\"p{d}\":{{}}", .{index});
        try json.appendSlice(std.testing.allocator, entry);
    }
    try json.appendSlice(std.testing.allocator, "}}");
    var document = try Document.parse(std.testing.allocator, json.items, .{});
    defer document.deinit();
    try std.testing.expectError(
        error.TooManyDefinitions,
        enumerate(std.testing.allocator, .{ .config = &document }),
    );
}

test "provider ids accept 63 bytes and reject 64 before field lookup" {
    const valid_id = "a" ** 63;
    const invalid_id = "b" ** 64;
    const json = "{\"providers\":{\"" ++ valid_id ++
        "\":{\"reasoning_roundtrip\":\"reasoning_content\"},\"" ++ invalid_id ++ "\":{}}}";
    var document = try Document.parse(std.testing.allocator, json, .{});
    defer document.deinit();
    var result = try enumerate(std.testing.allocator, .{ .config = &document });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.definitions.len);
    try std.testing.expectEqualStrings(valid_id, result.definitions[0].id);
    try std.testing.expectEqualStrings(
        "reasoning_content",
        result.definitions[0].reasoning_roundtrip.?,
    );
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(result.warnings[0].reason == .invalid_provider_id);
    try std.testing.expectEqualStrings(invalid_id, result.warnings[0].provider);
}

test "provider ids use registry ASCII grammar" {
    var document = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"bad space\":{},\"bad!\":{},\"café\":{},\"good_id-2\":{}}}",
        .{},
    );
    defer document.deinit();
    var result = try enumerate(std.testing.allocator, .{ .config = &document });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.definitions.len);
    try std.testing.expectEqualStrings("good_id-2", result.definitions[0].id);
    try std.testing.expectEqual(@as(usize, 3), result.warnings.len);
    for (result.warnings) |warning| try std.testing.expect(warning.reason == .invalid_provider_id);
}

test "invalid api and raw nonempty model APIs remain explicit" {
    var document = try Document.parse(
        std.testing.allocator,
        "{\"providers\":{\"p\":{\"api\":\"soap\",\"model_apis\":{\"*\":\"soap\"}}}}",
        .{},
    );
    defer document.deinit();
    var result = try enumerate(std.testing.allocator, .{ .config = &document });
    defer result.deinit();
    try std.testing.expect(result.definitions[0].api == null);
    try std.testing.expect(result.definitions[0].api_invalid);
    try std.testing.expect(result.definitions[0].model_apis_declared_nonempty);
    try std.testing.expectEqual(@as(usize, 0), result.definitions[0].model_apis.?.len);
}

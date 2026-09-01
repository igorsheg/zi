const std = @import("std");
const Document = @import("Document.zig");
const PromptValue = @import("PromptValue.zig");
const SecureOpen = @import("SecureOpen.zig");

/// At most this many definitions may be considered by one enumeration.
pub const maximum_presets: usize = 1024;
/// Aggregate value bytes and result-array element storage retained by one
/// enumeration, excluding allocator bookkeeping and spare ArrayList capacity.
pub const maximum_retained_bytes: usize = 1024 * 1024;

pub const Error = error{ OutOfMemory, TooManyPresets, RetainedDataTooLarge };

pub const PromptRoots = struct {
    secure_open: SecureOpen.Capability,
    config_root: ?[]const u8 = null,
    home: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

pub const Documents = struct {
    state: ?*const Document = null,
    config: ?*const Document = null,
};

/// Preset names are 1..63 bytes. The first byte is an ASCII letter or digit;
/// later bytes may additionally be '.', '-', or '_'. Non-ASCII is rejected.
pub fn nameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return false;
    }
    return true;
}

pub const InvalidReason = enum {
    invalid_name,
    not_object,
    unknown_field,
    non_scalar,
    missing_provider,
    invalid_tint,
    prompt_unresolved,
    prompt_read,
    prompt_unreadable,
    prompt_non_regular,
    prompt_too_large,
    prompt_invalid_path,
};

/// Allocator-owned invalid-definition report. `field` is absent when the
/// defect concerns the definition as a whole.
pub const Invalid = struct {
    name: []u8,
    field: ?[]u8,
    reason: InvalidReason,

    pub fn deinit(self: *Invalid, allocator: std.mem.Allocator) void {
        wipeFree(allocator, self.name);
        if (self.field) |field| wipeFree(allocator, field);
        self.* = undefined;
    }
};

/// An optional owned value preserves missing versus explicitly empty.
pub const OptionalValue = struct {
    value: ?[]u8 = null,

    pub fn deinit(self: *OptionalValue, allocator: std.mem.Allocator) void {
        if (self.value) |value| wipeFree(allocator, value);
        self.* = undefined;
    }
};

/// Owned, move-only and already validated instructions for applying a preset.
/// Applying this plan is deliberately left to the caller: this module does not
/// mutate Store or check whether the provider exists. Missing model and effort
/// mean reset to the caller's default; missing prompts mean clear the prior
/// preset's prompt value. Tint and description are metadata, not tier writes.
pub const Plan = struct {
    name: []u8,
    provider: []u8,
    model: OptionalValue,
    effort: OptionalValue,
    system_prompt: OptionalValue,
    system_prompt_append: OptionalValue,
    tint: OptionalValue,
    description: OptionalValue,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        wipeFree(allocator, self.name);
        wipeFree(allocator, self.provider);
        self.model.deinit(allocator);
        self.effort.deinit(allocator);
        self.system_prompt.deinit(allocator);
        self.system_prompt_append.deinit(allocator);
        self.tint.deinit(allocator);
        self.description.deinit(allocator);
        self.* = undefined;
    }

    pub fn retainedBytes(self: *const Plan) usize {
        var total = self.name.len + self.provider.len;
        inline for (.{
            self.model,
            self.effort,
            self.system_prompt,
            self.system_prompt_append,
            self.tint,
            self.description,
        }) |item| {
            if (item.value) |value| total += value.len;
        }
        return total;
    }
};

/// Non-owning view into a bounded Enumeration. Pointer payloads remain valid
/// only until that enumeration is mutated or deinitialized.
pub const BorrowedLookup = union(enum) {
    missing,
    invalid: *const Invalid,
    plan: *const Plan,
};

pub const Lookup = union(enum) {
    missing,
    invalid: Invalid,
    plan: Plan,

    pub fn deinit(self: *Lookup, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .missing => {},
            .invalid => |*invalid| invalid.deinit(allocator),
            .plan => |*plan| plan.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const Enumeration = struct {
    plans: []Plan,
    invalid: []Invalid,

    pub fn deinit(self: *Enumeration, allocator: std.mem.Allocator) void {
        for (self.plans) |*plan| plan.deinit(allocator);
        allocator.free(self.plans);
        for (self.invalid) |*item| item.deinit(allocator);
        allocator.free(self.invalid);
        self.* = undefined;
    }
};

/// Looks up one literal preset name. Nested objects are tried in state then
/// config. Only then is dotted lookup tried in state then config; an exact
/// flat root member still wins within a document. Nested non-objects therefore
/// fall through to a config nested object, but mask lower flat fallbacks.
/// Selected definitions never merge fields.
pub fn lookup(
    allocator: std.mem.Allocator,
    io: std.Io,
    documents: Documents,
    roots: PromptRoots,
    name: []const u8,
) Error!Lookup {
    if (name.len > maximum_retained_bytes) return error.RetainedDataTooLarge;
    const selected = try selectNode(allocator, documents, name) orelse return .missing;
    if (selected.* != .object) return .{
        .invalid = try makeInvalid(allocator, name, null, .not_object),
    };
    var result = try validateNode(allocator, io, roots, name, selected);
    errdefer result.deinit(allocator);
    switch (result) {
        .plan => |*plan| if (plan.retainedBytes() > maximum_retained_bytes)
            return error.RetainedDataTooLarge,
        .invalid => |*invalid| if (itemBytes(invalid) > maximum_retained_bytes)
            return error.RetainedDataTooLarge,
        .missing => unreachable,
    }
    return result;
}

/// Returns valid plans in config source order followed by unseen state names.
/// Invalid definitions are returned separately in the same encounter order.
/// The result is atomic: a bound or allocation error returns no partial lists.
pub fn enumerate(
    allocator: std.mem.Allocator,
    io: std.Io,
    documents: Documents,
    roots: PromptRoots,
) Error!Enumeration {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    if (documents.config) |config| try appendNames(allocator, config, &names, &seen);
    if (documents.state) |state| try appendNames(allocator, state, &names, &seen);
    if (names.items.len > maximum_presets) return error.TooManyPresets;

    var plans: std.ArrayList(Plan) = .empty;
    errdefer {
        for (plans.items) |*plan| plan.deinit(allocator);
        plans.deinit(allocator);
    }
    var invalid: std.ArrayList(Invalid) = .empty;
    errdefer {
        for (invalid.items) |*item| item.deinit(allocator);
        invalid.deinit(allocator);
    }
    var retained: usize = 0;
    for (names.items) |name| {
        var result = try lookup(allocator, io, documents, roots, name);
        switch (result) {
            .missing => {
                // A name came from one of the documents, so only non-object
                // definitions can arrive here.
                var item = try makeInvalid(allocator, name, null, .not_object);
                errdefer item.deinit(allocator);
                try addRetained(&retained, itemBytes(&item));
                try addRetained(&retained, @sizeOf(Invalid));
                try invalid.append(allocator, item);
            },
            .invalid => |item| {
                var owned = item;
                result = undefined;
                errdefer owned.deinit(allocator);
                try addRetained(&retained, itemBytes(&owned));
                try addRetained(&retained, @sizeOf(Invalid));
                try invalid.append(allocator, owned);
            },
            .plan => |plan| {
                var owned = plan;
                result = undefined;
                errdefer owned.deinit(allocator);
                try addRetained(&retained, owned.retainedBytes());
                try addRetained(&retained, @sizeOf(Plan));
                try plans.append(allocator, owned);
            },
        }
    }
    const owned_plans = try plans.toOwnedSlice(allocator);
    errdefer {
        for (owned_plans) |*plan| plan.deinit(allocator);
        allocator.free(owned_plans);
    }
    const owned_invalid = try invalid.toOwnedSlice(allocator);
    return .{ .plans = owned_plans, .invalid = owned_invalid };
}

const ValidationFailure = error{OutOfMemory};

fn validateNode(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: PromptRoots,
    name: []const u8,
    node: *const std.json.Value,
) ValidationFailure!Lookup {
    const object = &node.object;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!fieldAllowed(key)) return .{ .invalid = try makeInvalid(allocator, name, key, .unknown_field) };
        const probe = Document.scalarString(allocator, entry.value_ptr) catch return error.OutOfMemory;
        if (probe) |value| wipeFree(allocator, value) else return .{
            .invalid = try makeInvalid(allocator, name, key, .non_scalar),
        };
    }

    const provider = try scalarMember(allocator, object, "provider");
    if (provider == null or provider.?.len == 0) {
        if (provider) |value| wipeFree(allocator, value);
        return .{ .invalid = try makeInvalid(allocator, name, "provider", .missing_provider) };
    }
    errdefer wipeFree(allocator, provider.?);

    var model: OptionalValue = .{ .value = try scalarMember(allocator, object, "model") };
    errdefer model.deinit(allocator);
    var effort: OptionalValue = .{ .value = try scalarMember(allocator, object, "effort") };
    errdefer effort.deinit(allocator);
    var tint: OptionalValue = .{ .value = try scalarMember(allocator, object, "tint") };
    errdefer tint.deinit(allocator);
    if (tint.value) |value| {
        if (!tintValid(value)) {
            const invalid = try makeInvalid(allocator, name, "tint", .invalid_tint);
            wipeFree(allocator, provider.?);
            model.deinit(allocator);
            effort.deinit(allocator);
            tint.deinit(allocator);
            return .{ .invalid = invalid };
        }
    }
    var description: OptionalValue = .{ .value = try scalarMember(allocator, object, "description") };
    errdefer description.deinit(allocator);

    const prompt_result = try promptMember(allocator, io, roots, object, "system_prompt");
    var system_prompt = switch (prompt_result) {
        .value => |value| OptionalValue{ .value = value },
        .invalid => |reason| {
            const invalid = try makeInvalid(allocator, name, "system_prompt", reason);
            wipeFree(allocator, provider.?);
            model.deinit(allocator);
            effort.deinit(allocator);
            tint.deinit(allocator);
            description.deinit(allocator);
            return .{ .invalid = invalid };
        },
    };
    errdefer system_prompt.deinit(allocator);
    const append_result = try promptMember(allocator, io, roots, object, "system_prompt_append");
    var system_prompt_append = switch (append_result) {
        .value => |value| OptionalValue{ .value = value },
        .invalid => |reason| {
            const invalid = try makeInvalid(allocator, name, "system_prompt_append", reason);
            wipeFree(allocator, provider.?);
            model.deinit(allocator);
            effort.deinit(allocator);
            tint.deinit(allocator);
            description.deinit(allocator);
            system_prompt.deinit(allocator);
            return .{ .invalid = invalid };
        },
    };
    errdefer system_prompt_append.deinit(allocator);
    const owned_name = try allocator.dupe(u8, name);

    return .{ .plan = .{
        .name = owned_name,
        .provider = provider.?,
        .model = model,
        .effort = effort,
        .system_prompt = system_prompt,
        .system_prompt_append = system_prompt_append,
        .tint = tint,
        .description = description,
    } };
}

const PromptResult = union(enum) { value: ?[]u8, invalid: InvalidReason };

fn promptMember(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: PromptRoots,
    object: *const std.json.ObjectMap,
    key: []const u8,
) ValidationFailure!PromptResult {
    const raw = object.getPtr(key) orelse return .{ .value = null };
    const scalar = (Document.scalarString(allocator, raw) catch return error.OutOfMemory).?;
    var resolved = PromptValue.resolve(
        allocator,
        io,
        roots.secure_open,
        scalar,
        roots.config_root,
        roots.home,
        roots.cwd,
    ) catch |err| {
        wipeFree(allocator, scalar);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unresolved => .{ .invalid = .prompt_unresolved },
            error.Read => .{ .invalid = .prompt_read },
            error.Unreadable => .{ .invalid = .prompt_unreadable },
            error.NonRegular => .{ .invalid = .prompt_non_regular },
            error.TooLarge => .{ .invalid = .prompt_too_large },
            error.InvalidPath => .{ .invalid = .prompt_invalid_path },
        };
    };
    resolved.deinit(allocator);
    return .{ .value = scalar };
}

fn selectNode(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
) Error!?*const std.json.Value {
    if (documents.state) |state| if (nestedObject(state, name)) |node| return node;
    if (documents.config) |config| if (nestedObject(config, name)) |node| return node;

    const flat = std.mem.concat(allocator, u8, &.{ "presets.", name }) catch return error.OutOfMemory;
    defer allocator.free(flat);
    if (documents.state) |state| if (state.lookup(flat)) |node| return node;
    if (documents.config) |config| if (config.lookup(flat)) |node| return node;
    return null;
}

fn nestedObject(document: *const Document, name: []const u8) ?*const std.json.Value {
    const presets = document.parsed.value.object.getPtr("presets") orelse return null;
    const object = switch (presets.*) {
        .object => |*value| value,
        else => return null,
    };
    const node = object.getPtr(name) orelse return null;
    return if (node.* == .object) node else null;
}

fn appendNames(
    allocator: std.mem.Allocator,
    document: *const Document,
    names: *std.ArrayList([]u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const keys = try document.objectKeys(allocator, "presets");
    defer Document.freeObjectKeys(allocator, keys);
    for (keys) |name| try appendName(allocator, names, seen, name);
}

fn appendName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (seen.contains(name)) return;
    if (names.items.len == maximum_presets) return error.TooManyPresets;
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try seen.put(allocator, owned, {});
    errdefer _ = seen.remove(owned);
    try names.append(allocator, owned);
}

fn scalarMember(allocator: std.mem.Allocator, object: *const std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.getPtr(key) orelse return null;
    return Document.scalarString(allocator, value);
}

fn fieldAllowed(field: []const u8) bool {
    inline for (.{
        "provider",
        "model",
        "effort",
        "system_prompt",
        "system_prompt_append",
        "tint",
        "description",
    }) |allowed| {
        if (std.mem.eql(u8, field, allowed)) return true;
    }
    return false;
}

fn tintValid(tint: []const u8) bool {
    inline for (.{ "teal", "violet", "rose", "sage" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(tint, allowed)) return true;
    }
    return false;
}

fn makeInvalid(
    allocator: std.mem.Allocator,
    name: []const u8,
    field: ?[]const u8,
    reason: InvalidReason,
) !Invalid {
    const owned_name = try allocator.dupe(u8, name);
    errdefer wipeFree(allocator, owned_name);
    return .{
        .name = owned_name,
        .field = if (field) |value| try allocator.dupe(u8, value) else null,
        .reason = reason,
    };
}

fn itemBytes(item: *const Invalid) usize {
    return item.name.len + if (item.field) |field| field.len else 0;
}

fn addRetained(total: *usize, amount: usize) Error!void {
    total.* = std.math.add(usize, total.*, amount) catch return error.RetainedDataTooLarge;
    if (total.* > maximum_retained_bytes) return error.RetainedDataTooLarge;
}

fn wipeFree(allocator: std.mem.Allocator, value: []u8) void {
    @memset(value, 0);
    allocator.free(value);
}

const TestSecureOpen = struct {
    directory: ?std.Io.Dir = null,
    base: []const u8 = "",

    fn relative(self: *TestSecureOpen, path: []const u8) SecureOpen.Error![]const u8 {
        if (self.directory == null or !std.mem.startsWith(u8, path, self.base) or
            path.len <= self.base.len or path[self.base.len] != '/') return error.FileNotFound;
        return path[self.base.len + 1 ..];
    }

    pub fn statAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File.Stat {
        const sub_path = try self.relative(path);
        return self.directory.?.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Failed,
        };
    }

    pub fn openAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File {
        const sub_path = try self.relative(path);
        return self.directory.?.openFile(io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Failed,
        };
    }
};

fn unavailableSecureOpen() SecureOpen.Capability {
    const Static = struct {
        var implementation: TestSecureOpen = .{};
    };
    return SecureOpen.Capability.from(&Static.implementation);
}

fn parseTest(bytes: []const u8) !Document {
    return Document.parse(std.testing.allocator, bytes, .{});
}

fn expectPlan(result: *Lookup) !*Plan {
    return switch (result.*) {
        .plan => |*plan| plan,
        else => error.TestUnexpectedResult,
    };
}

test "nested and flat lookup, literal dotted names, state precedence and fallback" {
    var config = try parseTest(
        "{\"presets\":{\"work.prod\":{\"provider\":\"config\",\"model\":\"nested\"}}," ++
            "\"presets.flat\":{\"provider\":\"flat\"}}",
    );
    defer config.deinit();
    var state = try parseTest(
        "{\"presets\":{\"work.prod\":{\"provider\":\"state\"},\"flat\":12}}",
    );
    defer state.deinit();

    var work = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        "work.prod",
    );
    defer work.deinit(std.testing.allocator);
    const work_plan = try expectPlan(&work);
    try std.testing.expectEqualStrings("state", work_plan.provider);
    try std.testing.expect(work_plan.model.value == null);

    var flat = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        "flat",
    );
    defer flat.deinit(std.testing.allocator);
    try std.testing.expectEqual(InvalidReason.not_object, flat.invalid.reason);
}

test "lookup parity order and legacy names" {
    var config = try parseTest(
        "{\"presets\":{\"nested-wins\":{\"provider\":\"config-nested\"}," ++
            "\"fallthrough\":{\"provider\":\"config-fallback\"}}," ++
            "\"presets.masked\":{\"provider\":\"config-flat\"}," ++
            "\"presets.scalar-mask\":{\"provider\":\"config-flat\"}," ++
            "\"presets..hidden name\":{\"provider\":\"legacy\"}}",
    );
    defer config.deinit();
    var state = try parseTest(
        "{\"presets\":{\"fallthrough\":false,\"scalar-mask\":false}," ++
            "\"presets.nested-wins\":{\"provider\":\"state-flat\"}," ++
            "\"presets.masked\":false}",
    );
    defer state.deinit();

    var nested = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        "nested-wins",
    );
    defer nested.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("config-nested", (try expectPlan(&nested)).provider);

    var fallthrough = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        "fallthrough",
    );
    defer fallthrough.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("config-fallback", (try expectPlan(&fallthrough)).provider);

    var masked = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        "masked",
    );
    defer masked.deinit(std.testing.allocator);
    try std.testing.expectEqual(InvalidReason.not_object, masked.invalid.reason);

    var scalar_mask = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        "scalar-mask",
    );
    defer scalar_mask.deinit(std.testing.allocator);
    try std.testing.expectEqual(InvalidReason.not_object, scalar_mask.invalid.reason);

    var legacy = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
        ".hidden name",
    );
    defer legacy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("legacy", (try expectPlan(&legacy)).provider);

    var enumeration = try enumerate(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
    );
    defer enumeration.deinit(std.testing.allocator);
    var found_scalar_mask = false;
    for (enumeration.invalid) |item| {
        if (std.mem.eql(u8, item.name, "scalar-mask")) {
            found_scalar_mask = true;
            try std.testing.expectEqual(InvalidReason.not_object, item.reason);
        }
    }
    try std.testing.expect(found_scalar_mask);
}

test "allowed scalar coercions, explicit empty, tint, unknown and atomic validation" {
    var document = try parseTest(
        "{\"presets\":{" ++
            "\"ok\":{\"provider\":7,\"model\":\"\",\"effort\":true," ++
            "\"system_prompt\":\"\",\"tint\":\"SAGE\",\"description\":false}," ++
            "\"bad\":{\"provider\":\"p\",\"model\":\"would-not-escape\",\"endpoint\":\"x\"}," ++
            "\"bad-tint\":{\"provider\":\"p\",\"tint\":\"blue\"}}}",
    );
    defer document.deinit();
    var ok = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = unavailableSecureOpen() },
        "ok",
    );
    defer ok.deinit(std.testing.allocator);
    const plan = try expectPlan(&ok);
    try std.testing.expectEqualStrings("7", plan.provider);
    try std.testing.expectEqualStrings("", plan.model.value.?);
    try std.testing.expectEqualStrings("1", plan.effort.value.?);
    try std.testing.expectEqualStrings("", plan.system_prompt.value.?);
    try std.testing.expectEqualStrings("0", plan.description.value.?);
    try std.testing.expectEqualStrings("SAGE", plan.tint.value.?);

    var bad = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = unavailableSecureOpen() },
        "bad",
    );
    defer bad.deinit(std.testing.allocator);
    try std.testing.expectEqual(InvalidReason.unknown_field, bad.invalid.reason);
    var bad_tint = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = unavailableSecureOpen() },
        "bad-tint",
    );
    defer bad_tint.deinit(std.testing.allocator);
    try std.testing.expectEqual(InvalidReason.invalid_tint, bad_tint.invalid.reason);
}

test "prompt files validate while plans retain raw references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "a\\b\x00c\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "~cwd", .data = "from cwd" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var secure_open_impl: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);
    var document = try parseTest(
        "{\"presets\":{\"ok\":{\"provider\":\"p\\u0001\",\"system_prompt\":\"@prompt\"}," ++
            "\"cwd\":{\"provider\":\"p\",\"system_prompt\":\"@~cwd\"}," ++
            "\"bad\":{\"provider\":\"p\",\"system_prompt\":\"@missing\"}}}",
    );
    defer document.deinit();
    var ok = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = secure_open, .config_root = base },
        "ok",
    );
    defer ok.deinit(std.testing.allocator);
    const plan = try expectPlan(&ok);
    try std.testing.expectEqualStrings("p\x01", plan.provider);
    try std.testing.expectEqualStrings("@prompt", plan.system_prompt.value.?);
    var cwd = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = secure_open, .cwd = base },
        "cwd",
    );
    defer cwd.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("@~cwd", (try expectPlan(&cwd)).system_prompt.value.?);
    var bad = try lookup(
        std.testing.allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = secure_open, .config_root = base },
        "bad",
    );
    defer bad.deinit(std.testing.allocator);
    try std.testing.expectEqual(InvalidReason.prompt_read, bad.invalid.reason);
}

test "enumeration keeps config order then unseen state and separates invalid" {
    var config = try parseTest(
        "{\"presets\":{\"one\":{\"provider\":\"c1\"},\"shared\":{\"provider\":\"c\"},\"broken\":[]}," ++
            "\"presets.deep.provider\":\"p\"}",
    );
    defer config.deinit();
    var state = try parseTest(
        "{\"presets\":{\"shared\":{\"provider\":\"s\"},\"two\":{\"provider\":\"s2\"}}}",
    );
    defer state.deinit();
    var result = try enumerate(
        std.testing.allocator,
        std.testing.io,
        .{ .state = &state, .config = &config },
        .{ .secure_open = unavailableSecureOpen() },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.plans.len);
    try std.testing.expectEqualStrings("one", result.plans[0].name);
    try std.testing.expectEqualStrings("shared", result.plans[1].name);
    try std.testing.expectEqualStrings("s", result.plans[1].provider);
    try std.testing.expectEqualStrings("two", result.plans[2].name);
    try std.testing.expectEqual(@as(usize, 2), result.invalid.len);
    try std.testing.expectEqualStrings("broken", result.invalid[0].name);
    try std.testing.expectEqualStrings("deep", result.invalid[1].name);
}

test "resource bounds accept exact limits and reject one over" {
    var retained: usize = 0;
    try addRetained(&retained, maximum_retained_bytes - @sizeOf(Plan));
    try addRetained(&retained, @sizeOf(Plan));
    try std.testing.expectEqual(maximum_retained_bytes, retained);
    try std.testing.expectError(error.RetainedDataTooLarge, addRetained(&retained, 1));

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| std.testing.allocator.free(name);
        names.deinit(std.testing.allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var buffer: [16]u8 = undefined;
    for (0..maximum_presets) |index| {
        const name = try std.fmt.bufPrint(&buffer, "p{d}", .{index});
        try appendName(std.testing.allocator, &names, &seen, name);
    }
    try std.testing.expectEqual(maximum_presets, names.items.len);
    try std.testing.expectError(
        error.TooManyPresets,
        appendName(std.testing.allocator, &names, &seen, "over"),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var document = try Document.parse(
        allocator,
        "{\"presets\":{\"one\":{\"provider\":\"p\",\"model\":\"m\",\"system_prompt\":\"text\"}," ++
            "\"bad\":{\"provider\":[]}," ++
            "\"bad-tint\":{\"provider\":\"p\",\"tint\":\"blue\"}," ++
            "\"bad-prompt\":{\"provider\":\"p\",\"system_prompt\":\"@file\"}}}",
        .{},
    );
    defer document.deinit();
    var result = try enumerate(
        allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = unavailableSecureOpen() },
    );
    result.deinit(allocator);
}

test "enumeration frees every allocation on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}

fn exerciseReadablePromptAllocations(
    allocator: std.mem.Allocator,
    access: *TestSecureOpen,
    base: []const u8,
) !void {
    var document = try Document.parse(
        allocator,
        "{\"presets\":{\"review\":{\"provider\":\"p\",\"system_prompt\":\"@prompt\"}}}",
        .{},
    );
    defer document.deinit();
    var result = try lookup(
        allocator,
        std.testing.io,
        .{ .config = &document },
        .{ .secure_open = .from(access), .config_root = base },
        "review",
    );
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("@prompt", result.plan.system_prompt.value.?);
}

test "readable prompt validation frees every allocation and retains its reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prompt", .data = "instructions" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseReadablePromptAllocations,
        .{ &access, base },
    );
}

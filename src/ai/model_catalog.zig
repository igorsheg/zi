const std = @import("std");
const message = @import("message.zig");
pub const model_settings = @import("settings.zig");
const settings = model_settings;

pub const Error = error{
    InvalidProviderId,
    InvalidModelId,
    InvalidProtocolId,
    InvalidAlias,
    InvalidSource,
    InvalidProfile,
    DuplicateModelIdentifier,
};

pub const Entry = struct {
    identity: message.ModelIdentity,
    protocol_id: []const u8,
    aliases: []const []const u8 = &.{},
    source_url: ?[]const u8 = null,
    profile: settings.ModelProfile,
};

pub const Resolved = struct {
    entry: *const Entry,
    matched_model_id: []const u8,

    pub fn canonicalModelId(self: Resolved) []const u8 {
        return self.entry.identity.model;
    }

    pub fn providerId(self: Resolved) []const u8 {
        return self.entry.identity.provider;
    }

    pub fn wasAlias(self: Resolved) bool {
        return !std.mem.eql(u8, self.matched_model_id, self.entry.identity.model);
    }
};

pub const Catalog = struct {
    entries: []const Entry,

    pub fn init(entries: []const Entry) Error!Catalog {
        const catalog: Catalog = .{ .entries = entries };
        try catalog.validate();
        return catalog;
    }

    pub fn validate(self: Catalog) Error!void {
        for (self.entries, 0..) |entry, index| {
            try validateEntry(entry);
            for (self.entries[0..index]) |previous| {
                if (!std.mem.eql(u8, previous.identity.provider, entry.identity.provider)) continue;
                if (entriesOverlap(previous, entry)) return error.DuplicateModelIdentifier;
            }
        }
    }

    pub fn resolve(self: Catalog, identity: message.ModelIdentity) ?Resolved {
        for (self.entries) |*entry| {
            if (!std.mem.eql(u8, entry.identity.provider, identity.provider)) continue;
            if (std.mem.eql(u8, entry.identity.model, identity.model)) return .{
                .entry = entry,
                .matched_model_id = entry.identity.model,
            };
            for (entry.aliases) |alias| {
                if (std.mem.eql(u8, alias, identity.model)) return .{
                    .entry = entry,
                    .matched_model_id = alias,
                };
            }
        }
        return null;
    }
};

fn validateEntry(entry: Entry) Error!void {
    if (!validIdentifier(entry.identity.provider)) return error.InvalidProviderId;
    if (!validIdentifier(entry.identity.model)) return error.InvalidModelId;
    if (!validIdentifier(entry.protocol_id)) return error.InvalidProtocolId;
    if (entry.source_url) |source_url| {
        if (source_url.len == 0 or std.mem.indexOfAny(u8, source_url, "\r\n\x00") != null) {
            return error.InvalidSource;
        }
    }
    if (entry.profile.thinking) |thinking| {
        _ = settings.compileThinking(.{
            .reasoning = true,
            .level_map = thinking.level_map,
        }) catch return error.InvalidProfile;
    }
    if (entry.profile.context_window == 0 or entry.profile.max_output_tokens == 0) {
        return error.InvalidProfile;
    }
    if (entry.profile.context_window) |context_window| {
        if (entry.profile.max_output_tokens) |max_output_tokens| {
            if (max_output_tokens > context_window) return error.InvalidProfile;
        }
    }
    for (entry.aliases, 0..) |alias, index| {
        if (!validIdentifier(alias) or std.mem.eql(u8, alias, entry.identity.model)) return error.InvalidAlias;
        for (entry.aliases[0..index]) |previous| {
            if (std.mem.eql(u8, previous, alias)) return error.DuplicateModelIdentifier;
        }
    }
}

fn entriesOverlap(left: Entry, right: Entry) bool {
    if (identifierInEntry(left.identity.model, right) or
        identifierInEntry(right.identity.model, left)) return true;
    for (left.aliases) |alias| {
        if (identifierInEntry(alias, right)) return true;
    }
    return false;
}

fn identifierInEntry(identifier: []const u8, entry: Entry) bool {
    if (std.mem.eql(u8, identifier, entry.identity.model)) return true;
    for (entry.aliases) |alias| {
        if (std.mem.eql(u8, identifier, alias)) return true;
    }
    return false;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) return false;
    }
    return true;
}

test "catalog resolves canonical IDs and provider-scoped aliases" {
    const entries = [_]Entry{
        .{
            .identity = .{ .provider = "openai", .model = "model-one" },
            .protocol_id = "protocol-one",
            .aliases = &.{"latest"},
            .source_url = "https://example.test/model-one",
            .profile = .{ .context_window = 100, .max_output_tokens = 20 },
        },
        .{
            .identity = .{ .provider = "other", .model = "model-one" },
            .protocol_id = "protocol-two",
            .aliases = &.{"latest"},
            .profile = .{},
        },
    };
    const catalog = try Catalog.init(&entries);

    const canonical = catalog.resolve(.{ .provider = "openai", .model = "model-one" }).?;
    try std.testing.expect(!canonical.wasAlias());
    try std.testing.expectEqualStrings("model-one", canonical.canonicalModelId());
    try std.testing.expectEqualStrings("openai", canonical.providerId());

    const alias = catalog.resolve(.{ .provider = "openai", .model = "latest" }).?;
    try std.testing.expect(alias.wasAlias());
    try std.testing.expectEqualStrings("model-one", alias.canonicalModelId());
    try std.testing.expectEqualStrings(
        "other",
        catalog.resolve(.{ .provider = "other", .model = "latest" }).?.providerId(),
    );
    try std.testing.expect(catalog.resolve(.{ .provider = "openai", .model = "missing" }) == null);
}

test "catalog rejects invalid identity aliases source and profile" {
    const valid: Entry = .{
        .identity = .{ .provider = "provider", .model = "model" },
        .protocol_id = "protocol",
        .profile = .{},
    };
    var entry = valid;
    entry.identity.provider = "";
    try std.testing.expectError(error.InvalidProviderId, Catalog.init(&.{entry}));
    entry = valid;
    entry.identity.model = "bad model";
    try std.testing.expectError(error.InvalidModelId, Catalog.init(&.{entry}));
    entry = valid;
    entry.aliases = &.{"model"};
    try std.testing.expectError(error.InvalidAlias, Catalog.init(&.{entry}));
    entry = valid;
    entry.source_url = "bad\nsource";
    try std.testing.expectError(error.InvalidSource, Catalog.init(&.{entry}));
    entry = valid;
    entry.profile = .{ .context_window = 10, .max_output_tokens = 11 };
    try std.testing.expectError(error.InvalidProfile, Catalog.init(&.{entry}));
    entry = valid;
    entry.profile.thinking = .{ .level_map = .{
        .off = .unsupported,
        .minimal = .unsupported,
        .low = .unsupported,
        .medium = .unsupported,
        .high = .unsupported,
    } };
    try std.testing.expectError(error.InvalidProfile, Catalog.init(&.{entry}));
    entry = valid;
    entry.profile.thinking = .{ .level_map = .{
        .high = .{ .mapped = "unsafe\nvalue" },
    } };
    try std.testing.expectError(error.InvalidProfile, Catalog.init(&.{entry}));

    const duplicate = [_]Entry{
        valid,
        .{
            .identity = .{ .provider = "provider", .model = "other" },
            .protocol_id = "protocol",
            .aliases = &.{"model"},
            .profile = .{},
        },
    };
    try std.testing.expectError(error.DuplicateModelIdentifier, Catalog.init(&duplicate));
}

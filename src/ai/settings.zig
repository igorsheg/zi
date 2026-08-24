const std = @import("std");

pub const Capability = enum {
    streaming,
    tools,
    parallel_tool_calls,
    image_input,
};

pub const Setting = enum {
    temperature,
    top_p,
    max_output_tokens,
    stop_sequences,
    seed,
};

/// Canonical model-neutral thinking level used by model metadata, live agent
/// state, coding-agent settings, journals, and interactive clients.
pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
};

/// Missing source fields compile to inherited mappings. JSON null is the
/// explicit unsupported spelling and strings are model-specific wire aliases.
pub const ThinkingLevelMapping = union(enum) {
    inherited,
    unsupported,
    mapped: []const u8,

    // ziglint-ignore: Z012 -- std.json requires a public hook on this public wire-capable type.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ThinkingLevelMapping {
        const token = try source.nextAlloc(allocator, options.allocate.?);
        return switch (token) {
            .null => .unsupported,
            inline .string, .allocated_string => |value| .{ .mapped = value },
            else => error.UnexpectedToken,
        };
    }
};

pub const ThinkingLevelMap = struct {
    off: ThinkingLevelMapping = .inherited,
    minimal: ThinkingLevelMapping = .inherited,
    low: ThinkingLevelMapping = .inherited,
    medium: ThinkingLevelMapping = .inherited,
    high: ThinkingLevelMapping = .inherited,
    xhigh: ThinkingLevelMapping = .unsupported,
    max: ThinkingLevelMapping = .unsupported,

    pub fn get(self: ThinkingLevelMap, level: ThinkingLevel) ThinkingLevelMapping {
        return switch (level) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

/// Normalized runtime authority for selectable canonical levels and their
/// model-specific wire spellings.
pub const ThinkingProfile = struct {
    level_map: ThinkingLevelMap = .{},

    pub fn supports(self: ThinkingProfile, level: ThinkingLevel) bool {
        return self.level_map.get(level) != .unsupported;
    }

    pub fn supportedLevels(self: ThinkingProfile) std.EnumSet(ThinkingLevel) {
        var levels: std.EnumSet(ThinkingLevel) = .initEmpty();
        for (std.enums.values(ThinkingLevel)) |level| {
            if (self.supports(level)) levels.insert(level);
        }
        return levels;
    }

    pub fn wireValue(
        self: ThinkingProfile,
        level: ThinkingLevel,
        inherited_off_value: []const u8,
    ) ?[]const u8 {
        return switch (self.level_map.get(level)) {
            .inherited => if (level == .off) inherited_off_value else @tagName(level),
            .unsupported => null,
            .mapped => |value| value,
        };
    }
};

/// Semantic authoring contract shared by generated built-ins and custom model
/// definitions. A map without reasoning is invalid rather than ignored.
pub const ThinkingSource = struct {
    reasoning: bool = false,
    level_map: ?ThinkingLevelMap = null,
};

pub const max_thinking_mapping_bytes = 512;

pub const ThinkingSourceError = error{
    ThinkingMapWithoutReasoning,
    InvalidThinkingMapping,
    NoSupportedThinkingLevel,
};

pub fn compileThinking(source: ThinkingSource) ThinkingSourceError!?ThinkingProfile {
    if (!source.reasoning) {
        if (source.level_map != null) return error.ThinkingMapWithoutReasoning;
        return null;
    }
    const profile: ThinkingProfile = .{ .level_map = source.level_map orelse .{} };
    inline for (std.meta.fields(ThinkingLevel)) |field| {
        switch (@field(profile.level_map, field.name)) {
            .inherited, .unsupported => {},
            .mapped => |value| if (!validThinkingMapping(value)) return error.InvalidThinkingMapping,
        }
    }
    if (profile.supportedLevels().count() == 0) return error.NoSupportedThinkingLevel;
    return profile;
}

fn validThinkingMapping(value: []const u8) bool {
    if (value.len == 0 or value.len > max_thinking_mapping_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    var has_non_whitespace = false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return false;
        if (!std.ascii.isWhitespace(byte)) has_non_whitespace = true;
    }
    return has_non_whitespace;
}

pub const ModelProfile = struct {
    capabilities: std.EnumSet(Capability) = .initEmpty(),
    settings: std.EnumSet(Setting) = .initEmpty(),
    thinking: ?ThinkingProfile = null,
    context_window: ?u64 = null,
    max_output_tokens: ?u64 = null,

    pub fn supports(self: ModelProfile, capability: Capability) bool {
        return self.capabilities.contains(capability);
    }

    pub fn supportsSetting(self: ModelProfile, setting: Setting) bool {
        return self.settings.contains(setting);
    }

    pub fn supportsThinkingLevel(self: ModelProfile, level: ThinkingLevel) bool {
        const thinking = self.thinking orelse return level == .off;
        return thinking.supports(level);
    }

    pub fn supportedThinkingLevels(self: ModelProfile) std.EnumSet(ThinkingLevel) {
        const thinking = self.thinking orelse return .initOne(.off);
        return thinking.supportedLevels();
    }

    pub fn thinkingWireValue(
        self: ModelProfile,
        level: ThinkingLevel,
        inherited_off_value: []const u8,
    ) ?[]const u8 {
        const thinking = self.thinking orelse return null;
        return thinking.wireValue(level, inherited_off_value);
    }
};

pub fn clampThinkingLevel(profile: ModelProfile, requested: ThinkingLevel) ThinkingLevel {
    if (profile.supportsThinkingLevel(requested)) return requested;
    const values = std.enums.values(ThinkingLevel);
    const requested_index = @intFromEnum(requested);
    for (values[requested_index + 1 ..]) |level| {
        if (profile.supportsThinkingLevel(level)) return level;
    }
    var index = requested_index;
    while (index > 0) {
        index -= 1;
        if (profile.supportsThinkingLevel(values[index])) return values[index];
    }
    return .off;
}

test "semantic thinking source normalizes all map states" {
    const standard = (try compileThinking(.{ .reasoning = true })).?;
    try std.testing.expect(standard.supports(.off));
    try std.testing.expect(standard.supports(.high));
    try std.testing.expect(!standard.supports(.xhigh));
    try std.testing.expect(!standard.supports(.max));

    const custom = (try compileThinking(.{
        .reasoning = true,
        .level_map = .{
            .off = .unsupported,
            .high = .{ .mapped = "maximum" },
            .xhigh = .{ .mapped = "xhigh" },
        },
    })).?;
    try std.testing.expect(!custom.supports(.off));
    try std.testing.expectEqualStrings("minimal", custom.wireValue(.minimal, "none").?);
    try std.testing.expectEqualStrings("maximum", custom.wireValue(.high, "none").?);
    try std.testing.expectEqualStrings("xhigh", custom.wireValue(.xhigh, "none").?);
    try std.testing.expect(custom.wireValue(.max, "none") == null);
    try std.testing.expectEqual(ThinkingLevel.minimal, clampThinkingLevel(.{ .thinking = custom }, .off));
}

test "semantic thinking source rejects invalid absent reasoning forms" {
    try std.testing.expect((try compileThinking(.{})) == null);
    try std.testing.expectError(
        error.ThinkingMapWithoutReasoning,
        compileThinking(.{ .level_map = .{} }),
    );
    const unsupported: ThinkingLevelMap = .{
        .off = .unsupported,
        .minimal = .unsupported,
        .low = .unsupported,
        .medium = .unsupported,
        .high = .unsupported,
    };
    try std.testing.expectError(
        error.NoSupportedThinkingLevel,
        compileThinking(.{ .reasoning = true, .level_map = unsupported }),
    );
    try std.testing.expectError(
        error.InvalidThinkingMapping,
        compileThinking(.{ .reasoning = true, .level_map = .{
            .high = .{ .mapped = "unsafe\nvalue" },
        } }),
    );
}

pub const ModelSettings = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_output_tokens: ?u64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?u64 = null,
    thinking_level: ThinkingLevel = .off,

    pub fn validate(self: ModelSettings, profile: ModelProfile) error{UnsupportedSetting}!void {
        if (self.temperature != null and !profile.supportsSetting(.temperature))
            return error.UnsupportedSetting;
        if (self.top_p != null and !profile.supportsSetting(.top_p))
            return error.UnsupportedSetting;
        if (self.max_output_tokens != null and
            !profile.supportsSetting(.max_output_tokens)) return error.UnsupportedSetting;
        if (self.stop_sequences != null and
            !profile.supportsSetting(.stop_sequences)) return error.UnsupportedSetting;
        if (self.seed != null and !profile.supportsSetting(.seed)) return error.UnsupportedSetting;
        if (!profile.supportsThinkingLevel(self.thinking_level)) return error.UnsupportedSetting;
    }
};

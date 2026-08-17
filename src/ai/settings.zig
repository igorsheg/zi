const std = @import("std");

pub const Capability = enum {
    streaming,
    tools,
    parallel_tool_calls,
    image_input,
    thinking,
};

pub const Setting = enum {
    temperature,
    top_p,
    max_output_tokens,
    stop_sequences,
    seed,
    reasoning_effort,
};

pub const ReasoningEffort = enum {
    minimal,
    low,
    medium,
    high,
};

pub const ModelProfile = struct {
    capabilities: std.EnumSet(Capability) = .initEmpty(),
    settings: std.EnumSet(Setting) = .initEmpty(),
    reasoning_efforts: std.EnumSet(ReasoningEffort) = .initEmpty(),
    context_window: ?u64 = null,
    max_output_tokens: ?u64 = null,

    pub fn supports(self: ModelProfile, capability: Capability) bool {
        return self.capabilities.contains(capability);
    }

    pub fn supportsSetting(self: ModelProfile, setting: Setting) bool {
        return self.settings.contains(setting);
    }
};

pub const ModelSettings = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_output_tokens: ?u64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?u64 = null,
    reasoning_effort: ?ReasoningEffort = null,

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
        if (self.reasoning_effort != null and
            !profile.supportsSetting(.reasoning_effort)) return error.UnsupportedSetting;
        if (self.reasoning_effort) |effort|
            if (!profile.reasoning_efforts.contains(effort)) return error.UnsupportedSetting;
    }
};

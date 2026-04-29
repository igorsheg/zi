const agent_protocol = @import("../../agent3/types.zig");

pub fn label(level: agent_protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

pub fn value(level: agent_protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

pub fn description(level: agent_protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "No reasoning",
        .minimal => "Very brief reasoning (~1k tokens)",
        .low => "Light reasoning (~2k tokens)",
        .medium => "Moderate reasoning (~8k tokens)",
        .high => "Deep reasoning (~16k tokens)",
        .xhigh => "Maximum reasoning (~32k tokens)",
    };
}

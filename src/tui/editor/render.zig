const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const buffer_state_mod = @import("buffer.zig");
const types = @import("types.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const PromptBuffer = buffer_state_mod.PromptBuffer;
const VirtualLine = types.VirtualLine;

pub const RenderConfig = struct {
    prompt: []const u8,
    continuation_prompt: []const u8 = "  ",
    applied_padding_x: u32,
    prompt_fg: Color,
    text_fg: Color,
};

pub fn renderVisibleLines(region: Region, buffer: *const PromptBuffer, visible_lines: []const VirtualLine, config: RenderConfig) void {
    for (visible_lines, 0..) |line, row| {
        const prompt = switch (line.kind) {
            .prompt_first => config.prompt,
            .wrapped_continuation => config.continuation_prompt,
        };
        _ = region.writeStr(config.applied_padding_x, @intCast(row), prompt, config.prompt_fg, Color.default, .{});
        const text = buffer.text()[line.byte_start..line.byte_end];
        if (text.len > 0) {
            _ = region.writeStr(config.applied_padding_x + line.text_col, @intCast(row), text, config.text_fg, Color.default, .{});
        }
    }
}

const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const grapheme_mod = @import("../grapheme.zig");
const theme_mod = @import("../theme.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Theme = theme_mod.Theme;

/// Single-line search input primitive.
///
/// The owner keeps input/editing state; SearchInput only renders and reports the
/// cursor for a borrowed text slice. This lets flows compose search UIs without
/// growing one-off picker components.
pub const SearchInput = struct {
    theme: *const Theme,
    prompt: []const u8 = "/ ",
    text: []const u8 = "",
    placeholder: ?[]const u8 = null,
    focused: bool = false,
    width_method: grapheme_mod.WidthMethod = .wcwidth,

    pub fn init(theme: *const Theme) SearchInput {
        return .{ .theme = theme };
    }

    pub fn setText(self: *SearchInput, text: []const u8) void {
        self.text = text;
    }

    pub fn render(self: *SearchInput, region: Region) void {
        if (region.width == 0 or region.height == 0) return;
        self.width_method = region.buf.width_method;
        const prompt_w = region.textWidth(self.prompt);
        _ = region.writeStr(0, 0, self.prompt, self.theme.fg(.accent), Color.default, .{});
        if (self.text.len > 0) {
            _ = region.writeStr(prompt_w, 0, self.text, self.theme.fg(.text), Color.default, .{});
        } else if (self.placeholder) |placeholder| {
            _ = region.writeStr(prompt_w, 0, placeholder, self.theme.fg(.muted), Color.default, .{ .dim = true });
        }
    }

    pub fn measure(_: *SearchInput, _: u32) Measurement {
        return .{ .min_height = 1, .preferred_height = 1 };
    }

    pub fn cursorState(self: *SearchInput) ?CursorState {
        if (!self.focused) return null;
        const prompt_w: u32 = @intCast(grapheme_mod.strWidth(self.prompt, self.width_method));
        const text_w: u32 = @intCast(grapheme_mod.strWidth(self.text, self.width_method));
        return .{ .x = prompt_w + text_w, .y = 0, .style = .bar };
    }

    pub fn setFocused(self: *SearchInput, focused: bool) void {
        self.focused = focused;
    }

    pub fn component(self: *SearchInput) Component {
        return Component.init(SearchInput, self);
    }
};

const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Theme = theme_mod.Theme;

pub const Kind = enum {
    info,
    loading,
    @"error",
};

/// Single-line status text primitive.
///
/// This is intentionally only presentation. Owners decide when a status exists
/// and what it means; the primitive maps kind to theme color and height.
pub const StatusText = struct {
    theme: *const Theme,
    text: []const u8 = "",
    kind: Kind = .info,

    pub fn init(theme: *const Theme) StatusText {
        return .{ .theme = theme };
    }

    pub fn set(self: *StatusText, text: []const u8, kind: Kind) void {
        self.text = text;
        self.kind = kind;
    }

    pub fn clear(self: *StatusText) void {
        self.text = "";
        self.kind = .info;
    }

    pub fn render(self: *StatusText, region: Region) void {
        if (self.text.len == 0 or region.width == 0 or region.height == 0) return;
        _ = region.writeStr(0, 0, self.text, self.color(), Color.default, .{ .dim = self.kind == .info });
    }

    pub fn measure(self: *StatusText, _: u32) Measurement {
        return .{ .min_height = if (self.text.len == 0) 0 else 1, .preferred_height = if (self.text.len == 0) 0 else 1 };
    }

    pub fn component(self: *StatusText) Component {
        return Component.init(StatusText, self);
    }

    fn color(self: *const StatusText) Color {
        return switch (self.kind) {
            .info => self.theme.fg(.muted),
            .loading => self.theme.fg(.accent),
            .@"error" => self.theme.fg(.@"error"),
        };
    }
};

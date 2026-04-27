const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;

/// Generic empty block component for layout spacing/reservation.
pub const Div = struct {
    height: u32 = 0,

    pub fn init(height: u32) Div {
        return .{ .height = height };
    }

    pub fn render(_: *Div, _: Region) void {}

    pub fn measure(self: *Div, _: u32) Measurement {
        return .{ .min_height = self.height, .preferred_height = self.height };
    }

    pub fn component(self: *Div) Component {
        return Component.init(Div, self);
    }
};

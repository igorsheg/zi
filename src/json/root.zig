//! Generic JSON module — home for provider-agnostic JSON helpers.
//!
//! Submodules:
//!   - `value`   — clone/free walkers, typed accessors (asString/asU64/asObject/…)
//!   - `partial` — streaming partial-JSON parser (pi-mono partial-json parity)
//!
//! Domain-specific wire serializers stay in their domain directory
//! (`src/agent2/json.zig`, `src/session/json.zig`, `src/settings/json.zig`).
//! This module is the right place for anything that works on raw
//! `std.json.Value` without knowing what it represents.

pub const value = @import("value.zig");
pub const partial = @import("partial.zig");
pub const write = @import("write.zig");

test {
    _ = value;
    _ = partial;
    _ = write;
}

//! JSON boundary helpers.
//!
//! This module is intentionally small. It does not wrap `std.json` generally.
//! It owns only the JSON contracts that cross subsystem boundaries:
//! owned `std.json.Value` cloning/freeing, incomplete streaming-fragment parsing,
//! and bounded JSONL framing.

pub const value = @import("value.zig");
pub const partial = @import("partial.zig");
pub const jsonl = @import("jsonl.zig");

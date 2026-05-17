//! JSON boundary helpers.
//!
//! This module is intentionally small. It does not wrap `std.json` generally.
//! It owns only the JSON contracts that cross subsystem boundaries:
//! owned `std.json.Value` cloning/freeing, incomplete streaming-fragment parsing,
//! bounded JSONL framing, and cross-subsystem text sanitization.

pub const value = @import("value.zig");
pub const partial = @import("partial.zig");
pub const jsonl = @import("jsonl.zig");
pub const text = @import("text.zig");

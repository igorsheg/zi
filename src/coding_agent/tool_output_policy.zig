//! Shared output bounds for the builtin tools. Each tool applies its own
//! truncation shape (head for read, tail for bash); these constants are the one
//! source of truth for the limits.

pub const default_max_lines: usize = 2000;
pub const default_max_bytes: usize = 50 * 1024;

const std = @import("std");

pub const CookedLineInput = @import("CookedLineInput.zig");
pub const max_prompt_bytes = CookedLineInput.max_prompt_bytes;
pub const OwnedLine = CookedLineInput.OwnedLine;
pub const Result = CookedLineInput.Result;
pub const ReadError = CookedLineInput.ReadError;

// Register internal tests when this public seam is imported.
test {
    _ = CookedLineInput;
    _ = std;
}

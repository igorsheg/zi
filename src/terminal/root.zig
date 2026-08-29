const std = @import("std");

pub const CookedLineInput = @import("CookedLineInput.zig");
pub const DisplayColumns = @import("DisplayColumns.zig");
pub const GenerationInterrupt = @import("GenerationInterrupt.zig");
pub const Picker = @import("Picker.zig");
pub const RawLineInput = @import("RawLineInput.zig");
pub const SignalRestore = @import("SignalRestore.zig");
pub const Size = @import("Size.zig");
pub const max_prompt_bytes = CookedLineInput.max_prompt_bytes;
pub const OwnedLine = CookedLineInput.OwnedLine;
pub const Result = CookedLineInput.Result;
pub const ReadError = CookedLineInput.ReadError;

// Register internal tests when this public seam is imported.
test {
    _ = CookedLineInput;
    _ = DisplayColumns;
    _ = GenerationInterrupt;
    _ = Picker;
    _ = RawLineInput;
    _ = SignalRestore;
    _ = Size;
    _ = @import("EditLayout.zig");
    _ = @import("EscapeClassifier.zig");
    _ = @import("LineEditor.zig");
    _ = @import("PickerCore.zig");
    _ = @import("PosixMode.zig");
    _ = std;
}

pub const bash = @import("bash.zig");
pub const edit = @import("edit.zig");
pub const file_mutation_queue = @import("file_mutation_queue.zig");
pub const find = @import("find.zig");
pub const grep = @import("grep.zig");
pub const ls = @import("ls.zig");
pub const output_accumulator = @import("output_accumulator.zig");
pub const output_tail = @import("output_tail.zig");
pub const path_utils = @import("path_utils.zig");
pub const read = @import("read.zig");
pub const write = @import("write.zig");

pub const BashTool = bash.BashTool;
pub const EditTool = edit.EditTool;
pub const FileMutationQueue = file_mutation_queue.FileMutationQueue;
pub const FindTool = find.FindTool;
pub const GrepTool = grep.GrepTool;
pub const LsTool = ls.LsTool;
pub const ReadTool = read.ReadTool;
pub const WriteTool = write.WriteTool;

pub fn testsReachable() void {
    _ = bash;
    _ = edit;
    _ = file_mutation_queue;
    _ = find;
    _ = grep;
    _ = ls;
    _ = output_accumulator;
    _ = output_tail;
    _ = path_utils;
    _ = read;
    _ = write;
}

test {
    _ = bash;
    _ = edit;
    _ = file_mutation_queue;
    _ = find;
    _ = grep;
    _ = ls;
    _ = output_accumulator;
    _ = output_tail;
    _ = path_utils;
    _ = read;
    _ = write;
}

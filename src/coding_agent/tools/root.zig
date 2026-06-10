const bash = @import("bash.zig");
const edit = @import("edit.zig");
const file_writer = @import("file_writer.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");
const ls = @import("ls.zig");
const output_accumulator = @import("output_accumulator.zig");
const output_tail = @import("output_tail.zig");
const path_utils = @import("path_utils.zig");
const read = @import("read.zig");
const write = @import("write.zig");

test {
    _ = bash;
    _ = edit;
    _ = file_writer;
    _ = find;
    _ = grep;
    _ = ls;
    _ = output_accumulator;
    _ = output_tail;
    _ = path_utils;
    _ = read;
    _ = write;
}

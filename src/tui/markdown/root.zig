// Markdown presentation leaf modules adapted from vercel-labs/fx. Transcript
// Runtime owns sanitation and feeds the incremental processor.
const ansi = @import("ansi.zig");
const text_util = @import("text_util.zig");
const payload = @import("payload.zig");
const block_parse = @import("block_parse.zig");
const inline_render = @import("inline_render.zig");
const block_render = @import("block_render.zig");
const display_width = @import("display_width.zig");

/// Incremental streaming Markdown processor.
pub const Processor = @import("Processor.zig").MarkdownProcessor;

test {
    _ = ansi;
    _ = text_util;
    _ = payload;
    _ = block_parse;
    _ = inline_render;
    _ = block_render;
    _ = display_width;
    _ = Processor;
}

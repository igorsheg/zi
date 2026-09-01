const std = @import("std");
const MarkdownOutput = @import("MarkdownOutput.zig");
const MarkdownScan = @import("MarkdownScan.zig");
const MarkdownTable = @import("MarkdownTable.zig");
const MarkdownWrap = @import("MarkdownWrap.zig");
const Theme = @import("Theme.zig");

const Markdown = @This();

pub const Error = MarkdownOutput.Error;
pub const Sink = MarkdownOutput.Sink;

/// Maximum ordinary ambiguous suffix retained between feeds. An incomplete
/// table row may instead retain up to the table collector's 64 KiB bound.
pub const maximum_tail_bytes: usize = 8 * 1024;
/// Bounds one contiguous deferred-plus-new input operation. Production streams
/// are already bounded to 8 MiB before sanitation; this includes expansion.
pub const maximum_work_bytes: usize = 32 * 1024 * 1024;

const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";
const ansi_italic = "\x1b[3m";
const ansi_bold_off = "\x1b[22m";
const ansi_italic_off = "\x1b[23m";
const glyph_em_dash = "—";
const glyph_dot = "·";
const glyph_bullet = "•";

allocator: std.mem.Allocator,
sink: Sink,
theme: Theme,
tail: std.ArrayList(u8) = .empty,
prev_byte: u8 = 0,
prev_text_byte: u8 = 0,
pending_dash_space: bool = false,
at_line_start: bool = true,
trailing_spaces: usize = 0,
fence_open_count: usize = 0,
in_heading: bool = false,
in_code_fence: bool = false,
in_inline_code: bool = false,
in_bold: bool = false,
in_italic: bool = false,
in_link: bool = false,
styled: bool = true,
cur_line_is_block: bool = false,
pending_heading_blank: bool = false,
at_blank: bool = true,
skip_pad: bool = false,
wrap: MarkdownWrap,
table: MarkdownTable,
inline_only: bool = false,
suppress_bold: bool = false,

/// Initializes a reusable streaming Markdown renderer. The sink, theme string
/// slices, and input chunks remain borrowed; all retained parser storage is
/// owned through `allocator`.
pub fn init(
    allocator: std.mem.Allocator,
    sink: Sink,
    theme: Theme,
    wrap_width: usize,
) Markdown {
    return .{
        .allocator = allocator,
        .sink = sink,
        .theme = theme,
        .wrap = .init(allocator, wrap_width),
        .table = .init(allocator),
    };
}

pub fn deinit(self: *Markdown) void {
    self.tail.deinit(self.allocator);
    self.wrap.deinit();
    self.table.deinit();
    self.* = undefined;
}

/// Discards pending state for a new provider request while retaining capacity.
pub fn reset(self: *Markdown, theme: Theme, wrap_width: usize) void {
    self.tail.clearRetainingCapacity();
    self.theme = theme;
    self.prev_byte = 0;
    self.prev_text_byte = 0;
    self.pending_dash_space = false;
    self.at_line_start = true;
    self.trailing_spaces = 0;
    self.fence_open_count = 0;
    self.in_heading = false;
    self.in_code_fence = false;
    self.in_inline_code = false;
    self.in_bold = false;
    self.in_italic = false;
    self.in_link = false;
    self.styled = true;
    self.cur_line_is_block = false;
    self.pending_heading_blank = false;
    self.at_blank = true;
    self.skip_pad = false;
    self.wrap.reset(wrap_width);
    self.table.reset();
    self.inline_only = false;
    self.suppress_bold = false;
}

/// Consumes borrowed, terminal-safe UTF-8 synchronously and retains only
/// bounded lookahead. The stream adapter owns control stripping and UTF-8
/// sanitation before this parser; generated raw controls never enter here.
pub fn feed(self: *Markdown, bytes: []const u8) Error!void {
    try self.process(bytes, false);
}

/// Resolves deferred input at a provider-request boundary and balances styles.
pub fn finish(self: *Markdown) Error!void {
    const was_collecting_table = self.table.isCollecting();
    const table_context = self.tableContext();
    try self.table.finish(table_context, &self.tail);

    // A rejected final row is table fallback output, not fresh Markdown.
    if (was_collecting_table and self.tail.items.len != 0) {
        try self.emitText(self.tail.items);
        self.tail.clearRetainingCapacity();
    }
    try self.process("", true);

    if (self.in_link) try self.closeLink();
    if (self.in_inline_code) try self.closeInlineCode();
    if (self.in_code_fence) try self.closeCodeFence();
    if (self.in_heading) try self.closeHeading();
    if (self.in_bold) try self.closeBold();
    if (self.in_italic) try self.closeItalic();

    try self.wrap.finish(self.wrapContext());
}

/// Changes only SGR emission. Parsing and wrapping stay active.
pub fn setStyled(self: *Markdown, styled: bool) Error!void {
    if (self.styled == styled) return;
    const wrap_width = self.wrap.width();
    try self.finish();
    self.reset(self.theme, wrap_width);
    self.styled = styled;
}

pub fn isInTable(self: *const Markdown) bool {
    return self.table.isCollecting();
}

fn isAlphaNumeric(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9');
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn emDashCrowds(neighbor: u8) bool {
    return neighbor != 0 and !isSpace(neighbor);
}

fn wrapContext(self: *Markdown) MarkdownWrap.Context {
    return .{
        .sink = self.sink,
        .theme = &self.theme,
        .styled = self.styled,
        .in_bold = self.in_bold,
        .in_italic = self.in_italic,
        .in_inline_code = self.in_inline_code,
        .in_link = self.in_link,
    };
}

fn emitText(self: *Markdown, bytes: []const u8) Error!void {
    if (self.pending_dash_space) {
        self.pending_dash_space = false;
        if (bytes.len != 0 and emDashCrowds(bytes[0])) try self.emitText(" ");
    }

    for (bytes) |byte| {
        if (byte == ' ') {
            self.trailing_spaces +|= 1;
        } else if (byte != '\r') {
            self.trailing_spaces = 0;
        }
    }
    if (bytes.len != 0) self.prev_text_byte = bytes[bytes.len - 1];

    try self.wrap.emitText(self.wrapContext(), bytes, self.in_code_fence or self.in_heading);
}

fn emitRaw(self: *Markdown, bytes: []const u8) Error!void {
    if (!self.styled or bytes.len == 0) return;
    try self.wrap.emitRaw(self.wrapContext(), bytes, self.in_code_fence or self.in_heading);
}

fn openBold(self: *Markdown) Error!void {
    if (!self.suppress_bold) try self.emitRaw(ansi_bold);
    self.in_bold = true;
    self.trailing_spaces = 0;
}

fn closeBold(self: *Markdown) Error!void {
    if (!self.suppress_bold) try self.emitRaw(ansi_bold_off);
    self.in_bold = false;
    self.trailing_spaces = 0;
    if (self.in_heading and !self.suppress_bold) try self.emitRaw(self.theme.heading.open);
}

fn openItalic(self: *Markdown) Error!void {
    try self.emitRaw(ansi_italic);
    self.in_italic = true;
    self.trailing_spaces = 0;
}

fn closeItalic(self: *Markdown) Error!void {
    try self.emitRaw(ansi_italic_off);
    self.in_italic = false;
    self.trailing_spaces = 0;
}

fn openInlineCode(self: *Markdown) Error!void {
    try self.emitRaw(self.theme.code_inline.open);
    self.in_inline_code = true;
    self.trailing_spaces = 0;
}

fn closeInlineCode(self: *Markdown) Error!void {
    try self.emitRaw(self.theme.code_inline.close);
    self.in_inline_code = false;
    self.trailing_spaces = 0;
    if (self.in_heading and !std.mem.eql(u8, self.theme.heading.open, ansi_bold)) {
        try self.emitRaw(self.theme.heading.open);
    }
}

fn openLink(self: *Markdown) Error!void {
    try self.emitRaw(self.theme.link.open);
    self.in_link = true;
}

fn closeLink(self: *Markdown) Error!void {
    try self.emitRaw(self.theme.link.close);
    self.in_link = false;
    if (self.in_heading and !std.mem.eql(u8, self.theme.heading.open, ansi_bold)) {
        try self.emitRaw(self.theme.heading.open);
    }
}

fn openCodeFence(self: *Markdown) Error!void {
    self.in_code_fence = true;
    try self.emitRaw(self.theme.code_block.open);
}

fn closeCodeFence(self: *Markdown) Error!void {
    try self.emitRaw(self.theme.code_block.close);
    self.in_code_fence = false;
}

fn openHeading(self: *Markdown) Error!void {
    self.in_heading = true;
    try self.emitRaw(self.theme.heading.open);
}

fn closeHeading(self: *Markdown) Error!void {
    try self.emitRaw(self.theme.heading.close);
    self.in_heading = false;
}

fn tableContext(self: *Markdown) MarkdownTable.Context {
    return MarkdownTable.Context.from(self, self.sink, self.styled, self.wrap.width());
}

pub fn tableEmitText(self: *Markdown, bytes: []const u8) Error!void {
    try self.emitText(bytes);
}

pub fn tableEmitRaw(self: *Markdown, bytes: []const u8) Error!void {
    if (!self.styled or bytes.len == 0) return;
    try self.wrap.emitRaw(self.wrapContext(), bytes, false);
}

pub fn tableReplayRaw(self: *Markdown, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var end = offset;
        while (end < bytes.len and bytes[end] != 'm') : (end += 1) {}
        if (end < bytes.len) end += 1;
        const sequence = bytes[offset..end];
        if (std.mem.eql(u8, sequence, ansi_bold)) {
            self.in_bold = true;
        } else if (std.mem.eql(u8, sequence, ansi_bold_off)) {
            self.in_bold = false;
        } else if (std.mem.eql(u8, sequence, ansi_italic)) {
            self.in_italic = true;
        } else if (std.mem.eql(u8, sequence, ansi_italic_off)) {
            self.in_italic = false;
        } else if (self.theme.code_inline.open.len != 0 and
            std.mem.eql(u8, sequence, self.theme.code_inline.open))
        {
            self.in_inline_code = true;
        } else if (self.theme.code_inline.close.len != 0 and
            std.mem.eql(u8, sequence, self.theme.code_inline.close))
        {
            self.in_inline_code = false;
        } else if (self.theme.link.open.len != 0 and
            std.mem.eql(u8, sequence, self.theme.link.open))
        {
            self.in_link = true;
        } else if (self.theme.link.close.len != 0 and
            std.mem.eql(u8, sequence, self.theme.link.close))
        {
            self.in_link = false;
        }
        offset = end;
    }
    try self.tableEmitRaw(bytes);
}

pub fn tableOpenBold(self: *Markdown) Error!void {
    try self.openBold();
}

pub fn tableCloseBold(self: *Markdown) Error!void {
    try self.closeBold();
}

pub fn tableRenderInline(
    self: *Markdown,
    bytes: []const u8,
    bold_base: bool,
    sink: Sink,
) Error!void {
    var inline_renderer = Markdown.init(self.allocator, sink, self.theme, 0);
    defer inline_renderer.deinit();
    inline_renderer.styled = self.styled;
    inline_renderer.inline_only = true;
    inline_renderer.suppress_bold = bold_base;
    try inline_renderer.feed(bytes);
    try inline_renderer.finish();
}

pub fn tableCommitPending(self: *Markdown) Error!void {
    try self.wrap.commitPending(self.wrapContext());
}

pub fn tableRowReset(self: *Markdown) Error!void {
    self.wrap.rowReset();
}

const Step = enum {
    advanced,
    @"defer",
    pass,
};

fn stepInCodeFence(self: *Markdown, work: []const u8, index: *usize, final: bool) Error!Step {
    const byte = work[index.*];

    if (self.at_line_start) {
        var scan = index.*;
        var spaces: usize = 0;
        while (scan < work.len and spaces < 3 and work[scan] == ' ') {
            scan += 1;
            spaces += 1;
        }
        if (scan >= work.len) {
            if (!final) return .@"defer";
        } else if (work[scan] == '`') {
            var count: usize = 0;
            while (scan + count < work.len and work[scan + count] == '`') count += 1;
            if (scan + count >= work.len and !final) return .@"defer";
            if (count >= self.fence_open_count) {
                var end = scan + count;
                while (end < work.len and work[end] != '\n' and
                    (work[end] == ' ' or work[end] == '\t' or work[end] == '\r'))
                {
                    end += 1;
                }
                if (end >= work.len) {
                    if (!final) return .@"defer";
                    try self.closeCodeFence();
                    self.fence_open_count = 0;
                    index.* = end;
                    self.at_line_start = true;
                    return .advanced;
                }
                if (work[end] == '\n') {
                    try self.closeCodeFence();
                    self.fence_open_count = 0;
                    index.* = end + 1;
                    self.at_line_start = true;
                    return .advanced;
                }
            }
        }
    }

    try self.emitText(work[index.* .. index.* + 1]);
    self.at_line_start = byte == '\n';
    index.* += 1;
    return .advanced;
}

fn stepInInlineCode(self: *Markdown, work: []const u8, index: *usize) Error!Step {
    const byte = work[index.*];
    if (byte == '`') {
        try self.closeInlineCode();
        index.* += 1;
        return .advanced;
    }
    if (byte == '\n') {
        try self.closeInlineCode();
        return .pass;
    }
    try self.emitText(work[index.* .. index.* + 1]);
    index.* += 1;
    return .advanced;
}

fn stepLineStart(self: *Markdown, work: []const u8, index: *usize, final: bool) Error!Step {
    const original_index = index.*;
    const line = MarkdownScan.scan(work[index.*..], final);
    var normalize_indent = line.normalize_indent;
    // A bare setext underline remains literal at EOF, including source indent.
    if (final and line.kind == .thematic and line.marker == '=') normalize_indent = false;
    if (normalize_indent) index.* += line.indent_length;
    if (!line.classification_complete and line.indent_length > 0) return .@"defer";

    if (final and line.kind == .text) {
        const streaming = MarkdownScan.scan(work[index.*..], false);
        if (!streaming.classification_complete) {
            try self.emitText(work[index.*..]);
            index.* = work.len;
            return .advanced;
        }
    }

    if (final and line.kind == .thematic) {
        if (line.marker == '=') {
            try self.emitText(work[index.*..]);
        } else {
            try self.renderHrule();
        }
        index.* = work.len;
        self.at_line_start = true;
        return .advanced;
    }

    // Normalized incomplete indentation may have consumed all available bytes.
    if (index.* >= work.len) {
        index.* = original_index;
        return .@"defer";
    }
    const byte = work[index.*];

    if (byte == '\n') {
        self.pending_heading_blank = false;
        if (!self.at_blank) {
            try self.emitText("\n");
            self.at_blank = true;
        }
        self.at_line_start = true;
        self.cur_line_is_block = false;
        index.* += 1;
        return .advanced;
    }
    self.at_blank = false;

    if (self.pending_heading_blank) {
        self.pending_heading_blank = false;
        try self.emitText("\n");
    }

    if (byte == '`') {
        var count: usize = 0;
        while (index.* + count < work.len and work[index.* + count] == '`') count += 1;
        if (index.* + count >= work.len) return .@"defer";
        if (count >= 3) {
            var scan = index.* + count;
            while (scan < work.len and work[scan] != '\n') scan += 1;
            if (scan >= work.len) return .@"defer";
            try self.openCodeFence();
            self.fence_open_count = count;
            index.* = scan + 1;
            self.at_line_start = true;
            return .advanced;
        }
    }

    if (byte == '#') {
        var count: usize = 0;
        while (count < 6 and index.* + count < work.len and work[index.* + count] == '#') count += 1;
        if (index.* + count >= work.len) return .@"defer";
        if (work[index.* + count] == ' ' and count >= 1) {
            try self.openHeading();
            index.* += count + 1;
            self.at_line_start = false;
            return .advanced;
        }
    }

    if (byte == '-' or byte == '*' or byte == '_' or byte == '=') {
        var end = index.*;
        var count: usize = 0;
        while (end < work.len and
            (work[end] == byte or work[end] == ' ' or work[end] == '\t' or work[end] == '\r'))
        {
            if (work[end] == byte) count += 1;
            end += 1;
        }
        if (end >= work.len) return .@"defer";
        if (work[end] == '\n' and count >= 3) {
            if (byte == '=') {
                try self.emitText(work[index.* .. end + 1]);
            } else {
                try self.renderHrule();
            }
            index.* = end + 1;
            self.at_line_start = true;
            return .advanced;
        }
    }

    // Normalize unordered markers while retaining nesting indentation.
    var marker = index.*;
    while (marker < work.len and work[marker] == ' ') marker += 1;
    if (marker < work.len and
        (work[marker] == '*' or work[marker] == '-' or work[marker] == '+'))
    {
        if (marker + 1 >= work.len) return .@"defer";
        if (work[marker + 1] == ' ') {
            var content = marker + 1;
            while (content < work.len and work[content] == ' ') content += 1;
            if (marker > index.*) try self.emitText(work[index.*..marker]);
            try self.emitBullet();
            self.at_line_start = false;
            self.skip_pad = content >= work.len;
            index.* = content;
            return .advanced;
        }
    }

    // Preserve ordered marker digits and delimiter, dimming only their display.
    marker = index.*;
    while (marker < work.len and work[marker] == ' ') marker += 1;
    if (marker < work.len and work[marker] >= '0' and work[marker] <= '9') {
        var delimiter = marker;
        while (delimiter < work.len and work[delimiter] >= '0' and work[delimiter] <= '9') delimiter += 1;
        if (delimiter >= work.len or delimiter + 1 >= work.len) return .@"defer";
        if ((work[delimiter] == '.' or work[delimiter] == ')') and work[delimiter + 1] == ' ') {
            var content = delimiter + 1;
            while (content < work.len and work[content] == ' ') content += 1;
            if (marker > index.*) try self.emitText(work[index.*..marker]);
            try self.emitRaw(ansi_dim);
            try self.emitText(work[marker .. delimiter + 1]);
            try self.emitText(" ");
            try self.emitRaw(ansi_bold_off);
            self.at_line_start = false;
            self.skip_pad = content >= work.len;
            index.* = content;
            return .advanced;
        }
    }

    if (byte == '|') {
        const result = try self.table.tryStart(work, index);
        switch (result) {
            .@"defer" => {
                if (!final) return .@"defer";
                try self.emitText(work[index.*..]);
                index.* = work.len;
                return .advanced;
            },
            .advanced => return .advanced,
            .pass => {},
        }
    }

    if (byte == '>' or byte == '|') self.cur_line_is_block = true;
    return .pass;
}

fn canOpenEmphasis(left: u8, right: u8) bool {
    return !isAlphaNumeric(left) and !isSpace(right);
}

/// Returns the scheme length, zero when absent, or -1 while a prefix remains ambiguous.
fn linkSchemeLength(bytes: []const u8, final: bool) isize {
    const schemes = [_][]const u8{ "https://", "http://" };
    var incomplete = false;
    for (schemes) |scheme| {
        if (bytes.len >= scheme.len) {
            if (std.ascii.eqlIgnoreCase(bytes[0..scheme.len], scheme)) return @intCast(scheme.len);
        } else if (std.ascii.eqlIgnoreCase(bytes, scheme[0..bytes.len])) {
            incomplete = true;
        }
    }
    return if (incomplete and !final) -1 else 0;
}

fn bracketOpener(closer: u8) u8 {
    return switch (closer) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => 0,
    };
}

fn linkTrimEnd(bytes: []const u8, start: usize, initial_end: usize) usize {
    var end = initial_end;
    while (end > start) {
        const byte = bytes[end - 1];
        if (std.mem.indexOfScalar(u8, ".,;:!?*_'\"", byte) != null) {
            end -= 1;
            continue;
        }
        const opener = bracketOpener(byte);
        if (opener != 0) {
            var depth: isize = 0;
            for (bytes[start .. end - 1]) |candidate| {
                if (candidate == opener) depth += 1 else if (candidate == byte) depth -= 1;
            }
            if (depth <= 0) {
                end -= 1;
                continue;
            }
        }
        break;
    }
    return end;
}

fn stepInline(self: *Markdown, work: []const u8, index: *usize, final: bool) Error!Step {
    const byte = work[index.*];
    const remaining = work.len - index.*;

    if (self.skip_pad) {
        if (byte == ' ') {
            index.* += 1;
            return .advanced;
        }
        self.skip_pad = false;
    }

    if (byte == '\n') {
        if (self.in_heading) {
            try self.closeHeading();
            try self.emitText("\n");
            self.pending_heading_blank = true;
            self.at_line_start = true;
            self.cur_line_is_block = false;
            index.* += 1;
            return .advanced;
        }

        const next_line = MarkdownScan.scan(work[index.* + 1 ..], final);
        if (next_line.kind == .incomplete) {
            if (next_line.indent_length == remaining - 1 or next_line.indent_length <= 3) {
                return .@"defer";
            }
        }
        if (final and next_line.kind == .text and next_line.indent_length == remaining - 1) {
            try self.emitText("\n");
            index.* = work.len;
            self.at_line_start = true;
            self.cur_line_is_block = false;
            return .advanced;
        }
        if (final and next_line.kind == .thematic) {
            try self.emitText("\n");
            index.* += 1 + next_line.indent_length;
            self.at_line_start = true;
            self.cur_line_is_block = false;
            return .advanced;
        }
        if (final and next_line.kind == .text) {
            if (self.trailing_spaces >= 2) {
                try self.emitText("\n");
                try self.emitText(work[index.* + 1 ..]);
            } else {
                const previous = if (index.* > 0) work[index.* - 1] else self.prev_byte;
                if (previous != ' ' and previous != '\t' and previous != 0) try self.emitText(" ");
                const content = index.* + 1 + next_line.indent_length;
                try self.emitText(work[content..]);
            }
            index.* = work.len;
            return .advanced;
        }

        const top_level_list = (next_line.kind == .bullet or next_line.kind == .ordered) and
            next_line.indent_length <= 3;
        const hard = next_line.kind == .blank or next_line.kind == .heading or
            next_line.kind == .fence or next_line.kind == .thematic or
            next_line.kind == .blockquote or next_line.kind == .pipe or
            top_level_list or self.cur_line_is_block;
        const normalized_content = index.* + 1 + next_line.indent_length;
        if (hard) {
            if (self.in_bold) try self.closeBold();
            if (self.in_italic) try self.closeItalic();
            try self.emitText("\n");
            self.at_line_start = true;
            self.cur_line_is_block = false;
            index.* = if (next_line.normalize_indent) normalized_content else index.* + 1;
            return .advanced;
        }

        if (self.trailing_spaces >= 2) {
            try self.emitText("\n");
            self.at_line_start = true;
            self.cur_line_is_block = false;
            index.* += 1;
            return .advanced;
        }

        var content = index.* + 1;
        while (content < work.len and (work[content] == ' ' or work[content] == '\t')) content += 1;
        if (content >= work.len) return .@"defer";
        const previous = if (index.* > 0) work[index.* - 1] else self.prev_byte;
        if (previous != ' ' and previous != '\t') try self.emitText(" ");
        index.* = content;
        return .advanced;
    }

    if (byte == '`') {
        try self.openInlineCode();
        index.* += 1;
        return .advanced;
    }

    if (byte == '*') {
        if (remaining >= 2 and work[index.* + 1] == '*') {
            if (self.in_bold) {
                try self.closeBold();
                index.* += 2;
                return .advanced;
            }
            if (remaining < 3) {
                if (!final) return .@"defer";
                try self.emitText("**");
                index.* += 2;
                return .advanced;
            }
            const left = if (index.* > 0) work[index.* - 1] else self.prev_byte;
            const right = work[index.* + 2];
            if (canOpenEmphasis(left, right)) {
                try self.openBold();
                index.* += 2;
                return .advanced;
            }
            try self.emitText("**");
            index.* += 2;
            return .advanced;
        }
        if (remaining < 2) {
            if (!final) return .@"defer";
            if (self.in_italic) {
                try self.closeItalic();
            } else {
                try self.emitText(work[index.* .. index.* + 1]);
            }
            index.* += 1;
            return .advanced;
        }
        if (self.in_italic) {
            try self.closeItalic();
            index.* += 1;
            return .advanced;
        }
        const left = if (index.* > 0) work[index.* - 1] else self.prev_byte;
        const right = work[index.* + 1];
        if (canOpenEmphasis(left, right)) {
            try self.openItalic();
            index.* += 1;
            return .advanced;
        }
        try self.emitText(work[index.* .. index.* + 1]);
        index.* += 1;
        return .advanced;
    }

    if (byte == '_') {
        if (self.in_italic) {
            try self.closeItalic();
            index.* += 1;
            return .advanced;
        }
        if (remaining < 2) {
            if (!final) return .@"defer";
            try self.emitText(work[index.* .. index.* + 1]);
            index.* += 1;
            return .advanced;
        }
        const left = if (index.* > 0) work[index.* - 1] else self.prev_byte;
        const right = work[index.* + 1];
        if (canOpenEmphasis(left, right)) {
            try self.openItalic();
            index.* += 1;
            return .advanced;
        }
        try self.emitText(work[index.* .. index.* + 1]);
        index.* += 1;
        return .advanced;
    }

    if (byte == glyph_em_dash[0]) {
        if (remaining < glyph_em_dash.len) {
            if (!final) return .@"defer";
        } else if (std.mem.eql(u8, work[index.*..][0..glyph_em_dash.len], glyph_em_dash)) {
            if (emDashCrowds(self.prev_text_byte)) try self.emitText(" ");
            try self.emitText(glyph_em_dash);
            self.pending_dash_space = true;
            index.* += glyph_em_dash.len;
            return .advanced;
        }
    }

    if (byte == 'h' or byte == 'H') {
        const left = if (index.* > 0) work[index.* - 1] else self.prev_byte;
        if (!isAlphaNumeric(left)) {
            const scheme_length = linkSchemeLength(work[index.*..], final);
            if (scheme_length < 0) return .@"defer";
            if (scheme_length > 0) {
                const scheme: usize = @intCast(scheme_length);
                var url_end = index.* + scheme;
                while (url_end < work.len and !isSpace(work[url_end]) and
                    work[url_end] != '<' and work[url_end] != '>' and work[url_end] != '`')
                {
                    url_end += 1;
                }
                if (url_end >= work.len and !final) return .@"defer";
                const scheme_end = index.* + scheme;
                const stop = linkTrimEnd(work, scheme_end, url_end);
                if (stop == scheme_end) {
                    try self.emitText(work[index.*..scheme_end]);
                    index.* = scheme_end;
                    return .advanced;
                }
                if (self.pending_dash_space) {
                    self.pending_dash_space = false;
                    try self.emitText(" ");
                }
                try self.openLink();
                try self.emitText(work[index.*..stop]);
                try self.closeLink();
                index.* = stop;
                return .advanced;
            }
        }
    }

    var end = index.* + 1;
    while (end < work.len) {
        const candidate = work[end];
        if (candidate == '\n' or candidate == '`' or candidate == '*' or candidate == '_' or
            candidate == glyph_em_dash[0]) break;
        if ((candidate == 'h' or candidate == 'H') and !isAlphaNumeric(work[end - 1])) break;
        end += 1;
    }
    try self.emitText(work[index.*..end]);
    index.* = end;
    return .advanced;
}

fn renderHrule(self: *Markdown) Error!void {
    var dots: usize = 3;
    while (self.wrap.width() > 0 and dots > 1 and dots + (dots - 1) * 3 > self.wrap.width()) {
        dots -= 1;
    }
    try self.directRaw(ansi_dim);
    for (0..dots) |dot| {
        if (dot != 0) try self.directSpaces(3);
        try self.sink.emit(glyph_dot, .content);
    }
    try self.directRaw(ansi_bold_off);
    try self.sink.emit("\n", .content);
}

fn directRaw(self: *Markdown, bytes: []const u8) Error!void {
    if (self.styled) try self.sink.emit(bytes, .raw);
}

fn directSpaces(self: *Markdown, count: usize) Error!void {
    const spaces = "                                ";
    var remaining = count;
    while (remaining != 0) {
        const amount = @min(remaining, spaces.len);
        try self.sink.emit(spaces[0..amount], .content);
        remaining -= amount;
    }
}

fn emitBullet(self: *Markdown) Error!void {
    try self.emitRaw(ansi_dim);
    try self.emitText(glyph_bullet ++ " ");
    try self.emitRaw(ansi_bold_off);
}

fn process(self: *Markdown, bytes: []const u8, final: bool) Error!void {
    const work_length = std.math.add(usize, self.tail.items.len, bytes.len) catch
        return error.OutputTooLarge;
    if (work_length > maximum_work_bytes) return error.OutputTooLarge;

    var work = try std.ArrayList(u8).initCapacity(self.allocator, work_length);
    defer work.deinit(self.allocator);
    work.appendSliceAssumeCapacity(self.tail.items);
    work.appendSliceAssumeCapacity(bytes);
    self.tail.clearRetainingCapacity();

    var index: usize = 0;
    while (index < work.items.len) {
        if (self.table.isCollecting()) {
            const context = self.tableContext();
            switch (try self.table.step(context, work.items, &index)) {
                .@"defer" => break,
                .advanced => continue,
                .pass => self.at_line_start = true,
            }
        }

        if (self.in_code_fence) {
            if (try self.stepInCodeFence(work.items, &index, final) == .@"defer") break;
            continue;
        }

        if (self.in_inline_code) {
            switch (try self.stepInInlineCode(work.items, &index)) {
                .@"defer" => break,
                .advanced => continue,
                .pass => {},
            }
        }

        if (self.at_line_start and !self.inline_only) {
            switch (try self.stepLineStart(work.items, &index, final)) {
                .@"defer" => break,
                .advanced => continue,
                .pass => self.at_line_start = false,
            }
        }

        if (try self.stepInline(work.items, &index, final) == .@"defer") break;
    }

    var remaining = work.items.len - index;
    const table_context = self.tableContext();
    if (remaining != 0 and try self.table.bailPartial(table_context, work.items[index..])) {
        index = work.items.len;
        remaining = 0;
    }
    if (final and remaining != 0) {
        try self.emitText(work.items[index..]);
        index = work.items.len;
        remaining = 0;
    }
    if (remaining > maximum_tail_bytes and !self.table.isCollecting()) {
        try self.emitText(work.items[index .. work.items.len - maximum_tail_bytes]);
        index = work.items.len - maximum_tail_bytes;
        remaining = maximum_tail_bytes;
    }
    if (remaining != 0) try self.tail.appendSlice(self.allocator, work.items[index..]);

    if (index != 0) self.prev_byte = work.items[index - 1];
}

const TestCapture = struct {
    bytes: std.ArrayList(u8) = .empty,
    kinds: std.ArrayList(MarkdownOutput.Kind) = .empty,

    fn deinit(self: *TestCapture) void {
        self.bytes.deinit(std.testing.allocator);
        self.kinds.deinit(std.testing.allocator);
    }

    pub fn emit(
        self: *TestCapture,
        bytes: []const u8,
        kind: MarkdownOutput.Kind,
    ) MarkdownOutput.Error!void {
        try self.bytes.ensureUnusedCapacity(std.testing.allocator, bytes.len);
        try self.kinds.ensureUnusedCapacity(std.testing.allocator, bytes.len);
        self.bytes.appendSliceAssumeCapacity(bytes);
        self.kinds.appendNTimesAssumeCapacity(kind, bytes.len);
    }
};

fn ansiTheme() !Theme {
    return Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
}

fn expectRender(expected: []const u8, input: []const u8, width: usize) !void {
    var capture: TestCapture = .{};
    defer capture.deinit();
    var markdown = Markdown.init(
        std.testing.allocator,
        MarkdownOutput.Sink.from(&capture),
        try ansiTheme(),
        width,
    );
    defer markdown.deinit();
    try markdown.feed(input);
    try markdown.finish();
    try std.testing.expectEqualStrings(expected, capture.bytes.items);
}

fn expectEverySplit(expected: []const u8, input: []const u8, width: usize) !void {
    for (0..input.len + 1) |split| {
        var capture: TestCapture = .{};
        defer capture.deinit();
        var markdown = Markdown.init(
            std.testing.allocator,
            MarkdownOutput.Sink.from(&capture),
            try ansiTheme(),
            width,
        );
        defer markdown.deinit();
        try markdown.feed(input[0..split]);
        try markdown.feed(input[split..]);
        try markdown.finish();
        try std.testing.expectEqualStrings(expected, capture.bytes.items);
    }
}

test "plain text and blank-line normalization match hax" {
    try expectRender("", "", 0);
    try expectRender("hello world", "hello world", 0);
    try expectRender("héllo €", "héllo €", 0);
    try expectRender("a\n\nb", "a\n\nb", 0);
    try expectRender("a\n\nb", "a\n\n\n\nb", 0);
    try expectRender("text", "\n\n\ntext", 0);
    try expectEverySplit("a\n\nb", "a\n\n\n\nb", 0);
}

test "inline emphasis code and literal intraword markers match hax" {
    try expectRender("\x1b[1mhi\x1b[22m", "**hi**", 0);
    try expectRender("a \x1b[3mb\x1b[23m c", "a *b* c", 0);
    try expectRender("\x1b[3mb\x1b[23m", "_b_", 0);
    try expectRender("a \x1b[36mread\x1b[39m b", "a `read` b", 0);
    try expectRender("\x1b[1m\x1b[36mread\x1b[39m\x1b[22m", "**`read`**", 0);
    try expectRender("snake_case and a*b", "snake_case and a*b", 0);
    try expectEverySplit("a \x1b[1mbold\x1b[22m and \x1b[36mcode\x1b[39m", "a **bold** and `code`", 0);
}

test "headings fences lists and thematic rules match hax" {
    try expectRender("\x1b[1mTech\x1b[22m\n\nDetails", "## Tech\nDetails", 0);
    try expectRender("####### not a heading\n", "####### not a heading\n", 0);
    try expectRender("\x1b[2mfoo\n\n\nbar\n\x1b[22m", "```zig\nfoo\n\n\nbar\n```\n", 0);
    try expectRender("\x1b[2m• \x1b[22mone\n  \x1b[2m2) \x1b[22mtwo\n", "- one\n  2)   two\n", 0);
    try expectRender("\x1b[2m·   ·   ·\x1b[22m\n", "---\n", 0);
    try expectRender("===", "===", 0);
    try expectEverySplit("\x1b[2mfoo\nbar\n\x1b[22m", "````lang\nfoo\nbar\n````\n", 0);
}

test "soft joins hard breaks block boundaries and em dash spacing match hax" {
    try expectRender("one two", "one\ntwo", 0);
    try expectRender("one  \ntwo", "one  \ntwo", 0);
    try expectRender("one\n\x1b[2m• \x1b[22mtwo\n", "one\n- two\n", 0);
    try expectRender("alpha — beta", "alpha—beta", 0);
    try expectRender("alpha — beta", "alpha — beta", 0);
    try expectRender("— edge —", "—edge—", 0);
    try expectEverySplit("left — right", "left—right", 0);
}

test "bare links preserve balanced URL punctuation and styling" {
    const link = "\x1b[4mhttps://example.test/a_(b)?x[]=1\x1b[24m";
    try expectRender(link ++ ".", "https://example.test/a_(b)?x[]=1.", 0);
    try expectRender("(\x1b[4mHTTP://example.test/a(b)\x1b[24m)", "(HTTP://example.test/a(b))", 0);
    try expectRender("https:// prose", "https:// prose", 0);
    try expectRender("[label](\x1b[4mhttps://example.test\x1b[24m)", "[label](https://example.test)", 0);
    try expectEverySplit("see \x1b[4mhttps://example.test/a_b\x1b[24m now", "see https://example.test/a_b now", 0);
}

test "wrapping is eager and preserves hanging indentation and styles" {
    try expectRender("abc def gh\x1b[3D\x1b[K\nghi", "abc def ghi", 10);
    try expectRender("\x1b[2m• \x1b[22malpha beta ga\x1b[3D\x1b[K\n  gamma", "- alpha beta gamma", 15);
    try expectRender(
        "\x1b[1mfoo bar\x1b[22mb\x1b[5D\x1b[K\n\x1b[1mbar\x1b[22mbaz",
        "**foo bar**baz",
        8,
    );
    try expectRender("aaaaa\nbar", "aaaaa  \nbar", 5);
}

test "styled mode suppresses SGR without disabling Markdown structure" {
    var capture: TestCapture = .{};
    defer capture.deinit();
    var markdown = Markdown.init(
        std.testing.allocator,
        MarkdownOutput.Sink.from(&capture),
        try ansiTheme(),
        0,
    );
    defer markdown.deinit();
    try markdown.setStyled(false);
    try markdown.feed("## Head\n\n**bold** `code`\n---\n");
    try markdown.finish();
    try std.testing.expectEqualStrings("Head\n\nbold code\n·   ·   ·\n", capture.bytes.items);
    for (capture.kinds.items) |kind| try std.testing.expectEqual(MarkdownOutput.Kind.content, kind);
}

test "table collection layout and reflow match hax" {
    try expectRender(
        "\x1b[1mName\x1b[22m \x1b[2m│\x1b[22m \x1b[1mAge\x1b[22m\n" ++
            "\x1b[2m─────┼────\x1b[22m\nAda  \x1b[2m│\x1b[22m  42\n",
        "| Name | Age |\n| :--- | ---: |\n| Ada | 42 |\n",
        80,
    );
    try expectRender(
        "\x1b[2m• \x1b[22m\x1b[1mComponent\x1b[22m: parser\n" ++
            "  \x1b[1mRole\x1b[22m: reads tokens\n" ++
            "  \x1b[1mOwner\x1b[22m: ann\n" ++
            "\x1b[2m• \x1b[22m\x1b[1mComponent\x1b[22m: writer\n" ++
            "  \x1b[1mRole\x1b[22m: emits bytes\n" ++
            "  \x1b[1mOwner\x1b[22m: bob\n",
        "| Component | Role | Owner |\n|---|---|---|\n" ++
            "| parser | reads tokens | ann |\n| writer | emits bytes | bob |",
        20,
    );
}

test "reset discards pending state and reuses owned capacity" {
    var capture: TestCapture = .{};
    defer capture.deinit();
    const theme = try ansiTheme();
    var markdown = Markdown.init(
        std.testing.allocator,
        MarkdownOutput.Sink.from(&capture),
        theme,
        0,
    );
    defer markdown.deinit();
    try markdown.feed("**pending");
    markdown.reset(theme, 0);
    try markdown.feed("fresh");
    try markdown.finish();
    try std.testing.expectEqualStrings("\x1b[1mpendingfresh", capture.bytes.items);
}

fn exerciseMarkdownAllocations(allocator: std.mem.Allocator) !void {
    var capture: TestCapture = .{};
    defer capture.deinit();
    var markdown = Markdown.init(
        allocator,
        MarkdownOutput.Sink.from(&capture),
        try ansiTheme(),
        20,
    );
    defer markdown.deinit();
    try markdown.feed(
        "## Heading\n\n| Component | Role | Owner |\n|---|---|---|\n" ++
            "| **parser** | reads `tokens` | https://example.test/a_b |\n",
    );
    try markdown.finish();
}

test "all Markdown allocation failures release retained parser state" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMarkdownAllocations,
        .{},
    );
}

test "long split fence lookahead is bounded and lossless" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "```");
    try input.appendNTimes(std.testing.allocator, 'x', maximum_tail_bytes * 2);

    var capture: TestCapture = .{};
    defer capture.deinit();
    var markdown = Markdown.init(
        std.testing.allocator,
        MarkdownOutput.Sink.from(&capture),
        try ansiTheme(),
        0,
    );
    defer markdown.deinit();
    try markdown.feed(input.items);
    try std.testing.expect(markdown.tail.items.len <= maximum_tail_bytes);
    try markdown.finish();
    try std.testing.expectEqualSlices(u8, input.items, capture.bytes.items);
}

test "complex Markdown is invariant under every single split" {
    const input =
        "## Review\nText with **bold**, *italic*, `code`, and https://example.test/a_b.\n\n" ++
        "- first item with enough words to wrap onto another line\n" ++
        "| Name | Role |\n|---|---|\n| parser | reads tokens |\n" ++
        "```zig\nconst x = 1;\n```\n---\n";

    var whole: TestCapture = .{};
    defer whole.deinit();
    var baseline = Markdown.init(
        std.testing.allocator,
        MarkdownOutput.Sink.from(&whole),
        try ansiTheme(),
        32,
    );
    defer baseline.deinit();
    try baseline.feed(input);
    try baseline.finish();

    for (0..input.len + 1) |split| {
        var capture: TestCapture = .{};
        defer capture.deinit();
        var markdown = Markdown.init(
            std.testing.allocator,
            MarkdownOutput.Sink.from(&capture),
            try ansiTheme(),
            32,
        );
        defer markdown.deinit();
        try markdown.feed(input[0..split]);
        try markdown.feed(input[split..]);
        try markdown.finish();
        try std.testing.expectEqualSlices(u8, whole.bytes.items, capture.bytes.items);
        try std.testing.expectEqualSlices(MarkdownOutput.Kind, whole.kinds.items, capture.kinds.items);
    }
}

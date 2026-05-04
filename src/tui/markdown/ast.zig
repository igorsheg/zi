const std = @import("std");
const cell_mod = @import("../cell.zig");

pub const Color = cell_mod.Color;
pub const Attributes = cell_mod.Attributes;

pub const Style = struct {
    fg: Color,
    bg: Color,
    attrs: Attributes,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attrs.eql(b.attrs);
    }
};

pub const Document = struct {
    blocks: []const BlockNode,
};

pub const BlockNode = struct {
    block: Block,
    separated: bool = false,
};

pub const Block = union(enum) {
    paragraph: Paragraph,
    heading: Heading,
    code_block: CodeBlock,
    list: List,
    quote: Quote,
    thematic_break: void,
    table: Table,
};

pub const Paragraph = struct {
    inlines: []const Inline,
};

pub const Heading = struct {
    level: u8,
    inlines: []const Inline,
};

pub const CodeBlock = struct {
    info: []const u8,
    lines: []const []const u8,
};

pub const List = struct {
    ordered: bool,
    start: usize,
    items: []const ListItem,
};

pub const ListItem = struct {
    blocks: []const BlockNode,
};

pub const Quote = struct {
    blocks: []const BlockNode,
};

pub const Table = struct {
    alignments: []const Alignment,
    header: []const TableCell,
    rows: []const TableRow,
};

pub const TableRow = struct {
    cells: []const TableCell,
};

pub const TableCell = struct {
    inlines: []const Inline,
};

pub const Alignment = enum {
    none,
    left,
    center,
    right,
};

pub const LinkKind = enum {
    explicit,
    autolink_url,
    autolink_email,
};

pub const Inline = union(enum) {
    text: []const u8,
    code: []const u8,
    strong: []const Inline,
    emphasis: []const Inline,
    strikethrough: []const Inline,
    link: Link,
    line_break: void,
};

pub const Link = struct {
    kind: LinkKind,
    label: []const Inline,
    href: []const u8,
};

pub fn emptyDocument() Document {
    return .{ .blocks = &.{} };
}


const std = @import("std");
const component_mod = @import("../primitives/view.zig");
const surface_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const grapheme = @import("../grapheme.zig");
const text_mod = @import("../components/text.zig");
const markdown_mod = @import("markdown.zig");
const theme_mod = @import("../theme.zig");

const Measurement = component_mod.Measurement;
const Region = surface_mod.Region;
const Color = cell_mod.Color;
const Text = text_mod.Text;
const Markdown = markdown_mod.Markdown;

pub const TranscriptRenderable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render_slice: *const fn (ptr: *anyopaque, region: Region, first_row: u32) void,
        measure: *const fn (ptr: *anyopaque, width: u32) Measurement,
        next_animation_deadline: *const fn (ptr: *anyopaque, now_ns: i128) ?i128,
        tick_animation: *const fn (ptr: *anyopaque, now_ns: i128) bool,
    };

    pub fn init(comptime T: type, ptr: *T) TranscriptRenderable {
        comptime {
            if (!@hasDecl(T, "renderSlice")) {
                @compileError(@typeName(T) ++ " must implement renderSlice(region, first_row) to live in the transcript");
            }
            if (!@hasDecl(T, "measure")) {
                @compileError(@typeName(T) ++ " must implement measure(width) to live in the transcript");
            }
        }

        const gen = struct {
            fn renderSlice(erased: *anyopaque, region: Region, first_row: u32) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.renderSlice(region, first_row);
            }
            fn measure(erased: *anyopaque, width: u32) Measurement {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.measure(width);
            }
            fn nextAnimationDeadline(erased: *anyopaque, now_ns: i128) ?i128 {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "nextAnimationDeadline")) {
                    return self.nextAnimationDeadline(now_ns);
                }
                return null;
            }
            fn tickAnimation(erased: *anyopaque, now_ns: i128) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "tickAnimation")) {
                    return self.tickAnimation(now_ns);
                }
                return false;
            }
        };

        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .render_slice = gen.renderSlice,
                .measure = gen.measure,
                .next_animation_deadline = gen.nextAnimationDeadline,
                .tick_animation = gen.tickAnimation,
            },
        };
    }

    pub fn eql(a: TranscriptRenderable, b: TranscriptRenderable) bool {
        return a.ptr == b.ptr and a.vtable == b.vtable;
    }

    pub fn renderSlice(self: TranscriptRenderable, region: Region, first_row: u32) void {
        self.vtable.render_slice(self.ptr, region, first_row);
    }

    pub fn measure(self: TranscriptRenderable, width: u32) Measurement {
        return self.vtable.measure(self.ptr, width);
    }

    pub fn nextAnimationDeadline(self: TranscriptRenderable, now_ns: i128) ?i128 {
        return self.vtable.next_animation_deadline(self.ptr, now_ns);
    }

    pub fn tickAnimation(self: TranscriptRenderable, now_ns: i128) bool {
        return self.vtable.tick_animation(self.ptr, now_ns);
    }
};

pub const ItemId = enum(u64) { _ };
pub const SemanticVersion = u64;

pub const ItemKind = enum {
    generic,
    markdown,
    assistant_message,
    user_message,
    queued_user_message,
    tool_execution,
};

pub const DeinitFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void;

pub const TranscriptItem = struct {
    renderable: TranscriptRenderable,
    kind: ItemKind = .generic,
    retained_item_id: ?ItemId = null,
    retained_semantic_version: ?SemanticVersion = null,

    tool_call_id: ?[]const u8 = null,

    deinit_ctx: ?*anyopaque = null,
    deinit_fn: ?DeinitFn = null,

    pub const Options = struct {
        kind: ItemKind = .generic,
        retained_item_id: ?ItemId = null,
        retained_semantic_version: ?SemanticVersion = null,
        tool_call_id: ?[]const u8 = null,
        deinit_ctx: ?*anyopaque = null,
        deinit_fn: ?DeinitFn = null,
    };

    pub fn init(renderable: TranscriptRenderable, options: Options) TranscriptItem {
        return .{
            .renderable = renderable,
            .kind = options.kind,
            .retained_item_id = options.retained_item_id,
            .retained_semantic_version = options.retained_semantic_version,
            .tool_call_id = options.tool_call_id,
            .deinit_ctx = options.deinit_ctx,
            .deinit_fn = options.deinit_fn,
        };
    }

    pub fn ownedTyped(comptime T: type, ptr: *T, deinit_fn: DeinitFn, options: Options) TranscriptItem {
        var opts = options;
        opts.deinit_ctx = @ptrCast(ptr);
        opts.deinit_fn = deinit_fn;
        return init(TranscriptRenderable.init(T, ptr), opts);
    }

    pub fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |f| f(self.deinit_ctx.?, allocator);
    }
};

pub const TextOptions = struct {
    content: []const u8,
    width_method: grapheme.WidthMethod,
    fg: Color = Color.default,
    bg: Color = Color.default,
    padding_x: u32 = 0,
    padding_y: u32 = 0,
    kind: ItemKind = .generic,
};

pub fn text(allocator: std.mem.Allocator, options: TextOptions) !TranscriptItem {
    const row = try allocator.create(Text);
    errdefer allocator.destroy(row);
    row.* = Text.init(allocator, options.width_method);
    errdefer row.deinit();
    row.fg = options.fg;
    row.bg = options.bg;
    row.padding_x = options.padding_x;
    row.padding_y = options.padding_y;
    row.setContent(options.content);
    return TranscriptItem.ownedTyped(Text, row, deinitText, .{ .kind = options.kind });
}

pub const MarkdownOptions = struct {
    content: []const u8,
    theme: *const theme_mod.Theme,
    width_method: grapheme.WidthMethod,
    fg: Color = Color.default,
    bg: Color = Color.default,
    padding_x: u32 = 1,
    padding_y: ?u32 = null,
    kind: ItemKind = .markdown,
};

pub fn markdown(allocator: std.mem.Allocator, options: MarkdownOptions) !TranscriptItem {
    const md = try allocator.create(Markdown);
    errdefer allocator.destroy(md);
    md.* = Markdown.init(allocator, options.width_method);
    errdefer md.deinit();
    md.theme = options.theme;
    md.padding_x = options.padding_x;
    md.padding_y = options.padding_y orelse if (options.bg.eql(Color.default)) 0 else 1;
    md.fg = options.fg;
    md.bg = options.bg;
    md.setContent(options.content);
    return TranscriptItem.ownedTyped(Markdown, md, deinitMarkdown, .{ .kind = options.kind });
}

fn deinitText(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const row: *Text = @ptrCast(@alignCast(ctx));
    row.deinit();
    allocator.destroy(row);
}

fn deinitMarkdown(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const md: *Markdown = @ptrCast(@alignCast(ctx));
    md.deinit();
    allocator.destroy(md);
}

test "text item owns a Text renderable" {
    var item = try text(std.testing.allocator, .{
        .content = "hello",
        .width_method = .wcwidth,
        .kind = .generic,
    });
    defer item.deinit(std.testing.allocator);

    try std.testing.expectEqual(ItemKind.generic, item.kind);
    try std.testing.expect(item.deinit_ctx != null);
    const measurement = item.renderable.measure(80);
    try std.testing.expect(measurement.preferred_height > 0);
}

test "markdown item owns a Markdown renderable and defaults to markdown kind" {
    const themes_builtin = @import("../../themes/builtin.zig");
    var item = try markdown(std.testing.allocator, .{
        .content = "**hello**",
        .theme = themes_builtin.dark(),
        .width_method = .wcwidth,
    });
    defer item.deinit(std.testing.allocator);

    try std.testing.expectEqual(ItemKind.markdown, item.kind);
    try std.testing.expect(item.deinit_ctx != null);
    const measurement = item.renderable.measure(80);
    try std.testing.expect(measurement.preferred_height > 0);
}

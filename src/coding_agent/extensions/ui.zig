const std = @import("std");
const json_value = @import("../../json/value.zig");

pub const UiTarget = enum {
    overlay,
    status,
    toast,
    editor_border_top,
    editor_border_bottom,
};

pub const Tone = enum { neutral, info, success, warning, danger, accent };
pub const Direction = enum { row, column };
pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, space_between };
pub const SizeUnit = enum { fixed, percent, fill, auto };
pub const Constraint = union(SizeUnit) {
    fixed: f32,
    percent: f32,
    fill: f32,
    auto: void,

    pub fn clone(_: std.mem.Allocator, c: Constraint) !Constraint { return c; }
    pub fn deinit(_: *Constraint, _: std.mem.Allocator) void {}
};

pub const EdgeSizes = struct { top: f32 = 0, right: f32 = 0, bottom: f32 = 0, left: f32 = 0 };

pub const Style = struct {
    width: ?Constraint = null,
    height: ?Constraint = null,
    flex_direction: Direction = .column,
    flex_grow: f32 = 0,
    alignment: Align = .stretch,
    justify: Justify = .start,
    padding: EdgeSizes = .{},
    gap: f32 = 0,
    border: bool = false,
    tone: Tone = .neutral,

    pub fn clone(_: std.mem.Allocator, style: Style) !Style { return style; }
    pub fn deinit(_: *Style, _: std.mem.Allocator) void {}
};

pub const UiNode = union(enum) {
    box: Box,
    text: Text,
    chip: Chip,
    progress: Progress,
    surface: Surface,

    pub const Box = struct { id: ?[]const u8 = null, style: Style = .{}, children: []UiNode = &.{} };
    pub const Text = struct { id: ?[]const u8 = null, text: []const u8, style: Style = .{} };
    pub const Chip = struct { id: ?[]const u8 = null, label: []const u8, style: Style = .{} };
    pub const Progress = struct { id: ?[]const u8 = null, value: ?f32 = null, label: ?[]const u8 = null, style: Style = .{} };
    pub const Surface = struct { id: []const u8, style: Style = .{} };

    pub fn clone(allocator: std.mem.Allocator, node: UiNode) !UiNode {
        return switch (node) {
            .box => |b| blk: {
                const id = if (b.id) |v| try allocator.dupe(u8, v) else null;
                errdefer if (id) |v| allocator.free(v);
                const children = try allocator.alloc(UiNode, b.children.len);
                var n: usize = 0;
                errdefer {
                    for (children[0..n]) |*child| child.deinit(allocator);
                    allocator.free(children);
                }
                for (b.children, 0..) |child, i| { children[i] = try UiNode.clone(allocator, child); n += 1; }
                break :blk .{ .box = .{ .id = id, .style = try Style.clone(allocator, b.style), .children = children } };
            },
            .text => |t| .{ .text = .{ .id = if (t.id) |v| try allocator.dupe(u8, v) else null, .text = try allocator.dupe(u8, t.text), .style = t.style } },
            .chip => |ch| .{ .chip = .{ .id = if (ch.id) |v| try allocator.dupe(u8, v) else null, .label = try allocator.dupe(u8, ch.label), .style = ch.style } },
            .progress => |pr| .{ .progress = .{ .id = if (pr.id) |v| try allocator.dupe(u8, v) else null, .value = pr.value, .label = if (pr.label) |v| try allocator.dupe(u8, v) else null, .style = pr.style } },
            .surface => |s| .{ .surface = .{ .id = try allocator.dupe(u8, s.id), .style = s.style } },
        };
    }

    pub fn deinit(self: *UiNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .box => |*b| { if (b.id) |v| allocator.free(v); for (b.children) |*child| child.deinit(allocator); allocator.free(b.children); },
            .text => |*t| { if (t.id) |v| allocator.free(v); allocator.free(t.text); },
            .chip => |*ch| { if (ch.id) |v| allocator.free(v); allocator.free(ch.label); },
            .progress => |*pr| { if (pr.id) |v| allocator.free(v); if (pr.label) |v| allocator.free(v); },
            .surface => |*s| allocator.free(s.id),
        }
        self.* = undefined;
    }
};

pub const KeyBinding = struct {
    key: []const u8,
    action: []const u8,

    pub fn clone(allocator: std.mem.Allocator, key: KeyBinding) !KeyBinding {
        const k = try allocator.dupe(u8, key.key); errdefer allocator.free(k);
        return .{ .key = k, .action = try allocator.dupe(u8, key.action) };
    }
    pub fn deinit(self: *KeyBinding, allocator: std.mem.Allocator) void { allocator.free(self.key); allocator.free(self.action); self.* = undefined; }
};

pub const RenderSpec = struct {
    state_owner_id: []const u8,
    generation: u64,
    id: []const u8,
    target: UiTarget = .overlay,
    title: ?[]const u8 = null,
    order: i64 = 0,
    focus: bool = false,
    remove: bool = false,
    root: ?UiNode = null,
    keys: []KeyBinding = &.{},

    pub fn clone(allocator: std.mem.Allocator, spec: RenderSpec) !RenderSpec {
        const state_owner_id = try allocator.dupe(u8, spec.state_owner_id); errdefer allocator.free(state_owner_id);
        const id = try allocator.dupe(u8, spec.id); errdefer allocator.free(id);
        const title = if (spec.title) |v| try allocator.dupe(u8, v) else null; errdefer if (title) |v| allocator.free(v);
        const root = if (spec.root) |n| try UiNode.clone(allocator, n) else null; errdefer if (root) |*r| { var rr = r.*; rr.deinit(allocator); };
        const keys = try allocator.alloc(KeyBinding, spec.keys.len);
        var initialized: usize = 0;
        errdefer { for (keys[0..initialized]) |*k| k.deinit(allocator); allocator.free(keys); }
        for (spec.keys, 0..) |k, i| { keys[i] = try KeyBinding.clone(allocator, k); initialized += 1; }
        return .{ .state_owner_id = state_owner_id, .generation = spec.generation, .id = id, .target = spec.target, .title = title, .order = spec.order, .focus = spec.focus, .remove = spec.remove, .root = root, .keys = keys };
    }

    pub fn deinit(self: *RenderSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id); allocator.free(self.id); if (self.title) |v| allocator.free(v); if (self.root) |*r| r.deinit(allocator); for (self.keys) |*k| k.deinit(allocator); allocator.free(self.keys); self.* = undefined;
    }
};

pub const FrameFormat = enum {
    rgba8888,
    halfblock_rgb,

    pub fn expectedBytes(self: FrameFormat, width: u32, height: u32) ?usize {
        const pixels = std.math.mul(usize, width, height) catch return null;
        return switch (self) { .rgba8888 => std.math.mul(usize, pixels, 4) catch null, .halfblock_rgb => std.math.mul(usize, pixels, 3) catch null };
    }
};

pub const FrameSpec = struct {
    state_owner_id: []const u8,
    generation: u64,
    view: []const u8,
    node: []const u8,
    width: u32,
    height: u32,
    format: FrameFormat = .rgba8888,
    data: []const u8,

    pub fn validate(self: FrameSpec) !void {
        const expected = self.format.expectedBytes(self.width, self.height) orelse return error.FrameByteCountOverflow;
        if (self.data.len != expected) return error.InvalidFrameByteCount;
    }
    pub fn clone(allocator: std.mem.Allocator, spec: FrameSpec) !FrameSpec {
        const state_owner_id = try allocator.dupe(u8, spec.state_owner_id); errdefer allocator.free(state_owner_id);
        const view = try allocator.dupe(u8, spec.view); errdefer allocator.free(view);
        const node = try allocator.dupe(u8, spec.node); errdefer allocator.free(node);
        const data = try allocator.dupe(u8, spec.data); errdefer allocator.free(data);
        return .{ .state_owner_id = state_owner_id, .generation = spec.generation, .view = view, .node = node, .width = spec.width, .height = spec.height, .format = spec.format, .data = data };
    }
    pub fn deinit(self: *FrameSpec, allocator: std.mem.Allocator) void { allocator.free(self.state_owner_id); allocator.free(self.view); allocator.free(self.node); allocator.free(self.data); self.* = undefined; }
};

pub const UiFrame = FrameSpec;

pub const EditorActionKind = enum {
    set_text,
    paste_text,
    clear_text,
    get_text,
};

pub const EditorAction = struct {
    state_owner_id: []const u8,
    generation: u64,
    kind: EditorActionKind,
    text: ?[]const u8 = null,

    pub fn clone(allocator: std.mem.Allocator, action: EditorAction) !EditorAction {
        const state_owner_id = try allocator.dupe(u8, action.state_owner_id);
        errdefer allocator.free(state_owner_id);
        const text = if (action.text) |value| try allocator.dupe(u8, value) else null;
        return .{ .state_owner_id = state_owner_id, .generation = action.generation, .kind = action.kind, .text = text };
    }

    pub fn deinit(self: *EditorAction, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id);
        if (self.text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const JobEventKind = enum { stdout, stderr, exit, json };

pub const JobEvent = struct {
    id: u64,
    kind: JobEventKind,
    data: ?[]const u8 = null,
    code: ?i64 = null,
    value: ?std.json.Value = null,
    is_error: bool = false,
    error_message: ?[]const u8 = null,

    pub fn clone(allocator: std.mem.Allocator, event: JobEvent) !JobEvent {
        return .{
            .id = event.id,
            .kind = event.kind,
            .data = if (event.data) |data| try allocator.dupe(u8, data) else null,
            .code = event.code,
            .value = if (event.value) |value| try json_value.cloneJsonValue(allocator, value) else null,
            .is_error = event.is_error,
            .error_message = if (event.error_message) |msg| try allocator.dupe(u8, msg) else null,
        };
    }

    pub fn deinit(self: *JobEvent, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        if (self.value) |value| json_value.freeJsonValue(allocator, value);
        if (self.error_message) |msg| allocator.free(msg);
        self.* = undefined;
    }
};


test "ui v3 render spec clone owns node tree" {
    const testing = std.testing;
    const child = UiNode{ .text = .{ .id = "child", .text = "hello", .style = .{ .tone = .info } } };
    const root = UiNode{ .box = .{ .id = "root-node", .style = .{ .flex_direction = .row, .gap = 1 }, .children = @constCast(&[_]UiNode{child}) } };
    const spec = RenderSpec{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .title = "Title", .root = root, .keys = @constCast(&[_]KeyBinding{.{ .key = "ctrl+x", .action = "close" }}) };
    var cloned = try RenderSpec.clone(testing.allocator, spec);
    defer cloned.deinit(testing.allocator);
    try testing.expectEqualStrings("owner", cloned.state_owner_id);
    try testing.expectEqual(UiTarget.status, cloned.target);
    try testing.expect(cloned.root != null);
    try testing.expectEqual(@as(usize, 1), cloned.keys.len);
}

test "ui v3 frame byte validation" {
    const testing = std.testing;
    const rgba = FrameSpec{ .state_owner_id = "owner", .generation = 1, .view = "v", .node = "n", .width = 2, .height = 2, .format = .rgba8888, .data = &[_]u8{0} ** 16 };
    try rgba.validate();
    const half = FrameSpec{ .state_owner_id = "owner", .generation = 1, .view = "v", .node = "n", .width = 2, .height = 2, .format = .halfblock_rgb, .data = &[_]u8{0} ** 12 };
    try half.validate();
    const bad = FrameSpec{ .state_owner_id = "owner", .generation = 1, .view = "v", .node = "n", .width = 2, .height = 2, .format = .rgba8888, .data = &[_]u8{0} ** 15 };
    try testing.expectError(error.InvalidFrameByteCount, bad.validate());
}

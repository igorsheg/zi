const std = @import("std");
const ai = @import("../ai/root.zig");

pub const Definition = ai.Provider.ToolDefinition;
pub const Parameter = ai.Provider.ToolParameter;
pub const ImageInput = ai.Provider.ImageInput;

pub const RunError = error{
    OutOfMemory,
    InvalidResult,
};

/// Synchronous display-only sink. The implementation must outlive the call.
/// Emitted bytes are borrowed only for `emit` and may not escape it.
pub const DisplaySink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8) error{OutOfMemory}!void,

    pub fn emit(self: DisplaySink, bytes: []const u8) error{OutOfMemory}!void {
        return self.emit_fn(self.context, bytes);
    }

    pub fn from(implementation: anytype) DisplaySink {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("DisplaySink.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emit(context: *anyopaque, bytes: []const u8) error{OutOfMemory}!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.emit(bytes);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

/// Borrowed cancellation probe. Implementations poll it synchronously and the
/// probe owner must outlive the tool call.
pub const Cancellation = struct {
    context: *const anyopaque,
    is_requested_fn: *const fn (*const anyopaque) bool,

    pub fn isRequested(self: Cancellation) bool {
        return self.is_requested_fn(self.context);
    }

    pub fn from(implementation: anytype) Cancellation {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Cancellation.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn isRequested(context: *const anyopaque) bool {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.isRequested();
            }
        };
        return .{ .context = implementation, .is_requested_fn = Adapter.isRequested };
    }
};

pub const RunContext = struct {
    display: ?DisplaySink = null,
    image_input: ImageInput = .unsupported,
    cancel: ?Cancellation = null,
};

/// Owned model-facing result. Caller must call `deinit` exactly once.
pub const Result = struct {
    output: []u8,
    images: []ai.Item.Image = &.{},
    summarizes_display: bool = false,
    hidden_tail_bytes: usize = 0,

    pub fn validate(self: Result) error{InvalidResult}!void {
        if (self.hidden_tail_bytes > self.output.len) return error.InvalidResult;
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        for (self.images) |*image| image.deinit(allocator);
        if (self.images.len != 0) allocator.free(self.images);
        self.* = undefined;
    }
};

pub const OutputStyle = enum {
    plain,
    unified_diff,
};

pub const PreviewMode = enum {
    head,
    head_tail,
    collapsed,
};

pub const Display = struct {
    arg_name: ?[]const u8 = null,
    output_style: OutputStyle = .plain,
    preview_mode: PreviewMode = .head,
    header_rows: usize = 1,
    format_extra: ?*const fn (
        std.mem.Allocator,
        ?[]const u8,
    ) error{OutOfMemory}!?[]u8 = null,
    collapse_argument: ?*const fn (
        std.mem.Allocator,
        ?[]const u8,
    ) error{OutOfMemory}![]u8 = null,
    select_preview: ?*const fn (?[]const u8) PreviewMode = null,

    pub fn preview(self: Display, args_json: ?[]const u8) PreviewMode {
        const select = self.select_preview orelse return self.preview_mode;
        return select(args_json);
    }
};

/// Erased synchronous tool. The implementation, definition strings, parameter
/// slices, and display strings must outlive every copied handle and call.
pub const Tool = struct {
    context: *anyopaque,
    vtable: *const VTable,
    definition: Definition,
    display: Display,

    pub const VTable = struct {
        run: *const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            ?[]const u8,
            RunContext,
        ) RunError!Result,
        preprocess: ?*const fn (
            std.mem.Allocator,
            std.Io,
            *anyopaque,
            ?[]const u8,
        ) error{OutOfMemory}!?[]u8 = null,
        advertise: ?*const fn (*anyopaque) ?*const Definition = null,
    };

    pub fn from(
        implementation: anytype,
        definition: Definition,
        display: Display,
    ) Tool {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Tool.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn runFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                args_json: ?[]const u8,
                run_context: RunContext,
            ) RunError!Result {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.run(allocator, io, self, args_json, run_context);
            }

            fn preprocessFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                args_json: ?[]const u8,
            ) error{OutOfMemory}!?[]u8 {
                if (!@hasDecl(Implementation, "preprocess")) return null;
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.preprocess(allocator, io, self, args_json);
            }

            fn advertiseFn(context: *anyopaque) ?*const Definition {
                if (!@hasDecl(Implementation, "advertise")) return null;
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.advertise(self);
            }

            const vtable: VTable = .{
                .run = runFn,
                .preprocess = if (@hasDecl(Implementation, "preprocess")) preprocessFn else null,
                .advertise = if (@hasDecl(Implementation, "advertise")) advertiseFn else null,
            };
        };
        return .{
            .context = implementation,
            .vtable = &Adapter.vtable,
            .definition = definition,
            .display = display,
        };
    }

    pub fn run(
        self: Tool,
        allocator: std.mem.Allocator,
        io: std.Io,
        args_json: ?[]const u8,
        run_context: RunContext,
    ) RunError!Result {
        var result = try self.vtable.run(
            allocator,
            io,
            self.context,
            args_json,
            run_context,
        );
        result.validate() catch {
            result.deinit(allocator);
            return error.InvalidResult;
        };
        return result;
    }

    /// Returns owned replacement arguments, or null to execute the original.
    pub fn preprocess(
        self: Tool,
        allocator: std.mem.Allocator,
        io: std.Io,
        args_json: ?[]const u8,
    ) error{OutOfMemory}!?[]u8 {
        if (args_json == null) return null;
        const preprocess_fn = self.vtable.preprocess orelse return null;
        return preprocess_fn(allocator, io, self.context, args_json);
    }

    /// Returns the definition to advertise, or null when withheld.
    pub fn advertised(self: Tool) ?Definition {
        const advertise_fn = self.vtable.advertise orelse return self.definition;
        const definition = advertise_fn(self.context) orelse return null;
        return definition.*;
    }
};

const test_definition: Definition = .{
    .name = "fake",
    .description = "fake tool",
    .parameters = &.{},
};

test "erased tool preserves borrowed callback and owned result lifetimes" {
    const Fake = struct {
        const Self = @This();

        fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            args_json: ?[]const u8,
            context: RunContext,
        ) RunError!Result {
            if (!std.mem.eql(u8, args_json.?, "{}")) return error.InvalidResult;
            var stack_bytes = [_]u8{ 'o', 'k' };
            try context.display.?.emit(&stack_bytes);
            stack_bytes = .{ 'x', 'x' };
            const mime = try allocator.dupe(u8, "image/png");
            errdefer allocator.free(mime);
            const data_base64 = try allocator.dupe(u8, "AAAA");
            errdefer allocator.free(data_base64);
            const output = try allocator.dupe(u8, "result\nmodel-only");
            errdefer allocator.free(output);
            const images = try allocator.alloc(ai.Item.Image, 1);
            images[0] = .{
                .mime = mime,
                .data_base64 = data_base64,
                .width = 1,
                .height = 1,
            };
            return .{
                .output = output,
                .images = images,
                .summarizes_display = true,
                .hidden_tail_bytes = "model-only".len,
            };
        }
    };
    const Sink = struct {
        const Self = @This();
        bytes: [2]u8 = undefined,

        fn emit(self: *Self, bytes: []const u8) error{OutOfMemory}!void {
            @memcpy(&self.bytes, bytes);
        }
    };

    var fake: Fake = .{};
    var sink: Sink = .{};
    const tool = Tool.from(&fake, test_definition, .{});
    var result = try tool.run(
        std.testing.allocator,
        std.testing.io,
        "{}",
        .{ .display = DisplaySink.from(&sink), .image_input = .supported },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", &sink.bytes);
    try std.testing.expect(result.summarizes_display);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
}

test "recoverable tool failure is an ordinary owned result" {
    const Fake = struct {
        const Self = @This();
        fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: RunContext,
        ) RunError!Result {
            return .{ .output = try allocator.dupe(u8, "invalid arguments") };
        }
    };
    var fake: Fake = .{};
    var result = try Tool.from(&fake, test_definition, .{}).run(
        std.testing.allocator,
        std.testing.io,
        null,
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("invalid arguments", result.output);
}

test "invalid hidden tail is rejected and cleaned up" {
    const Fake = struct {
        const Self = @This();
        fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: RunContext,
        ) RunError!Result {
            return .{
                .output = try allocator.dupe(u8, "short"),
                .hidden_tail_bytes = 6,
            };
        }
    };
    var fake: Fake = .{};
    try std.testing.expectError(error.InvalidResult, Tool.from(&fake, test_definition, .{}).run(
        std.testing.allocator,
        std.testing.io,
        null,
        .{},
    ));
}

test "optional preprocess and advertisement hooks stay erased" {
    const Fake = struct {
        const Self = @This();
        advertised_definition: Definition = test_definition,
        preprocess_calls: usize = 0,

        fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            args_json: ?[]const u8,
            _: RunContext,
        ) RunError!Result {
            return .{ .output = try allocator.dupe(u8, args_json.?) };
        }

        fn preprocess(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
        ) error{OutOfMemory}!?[]u8 {
            self.preprocess_calls += 1;
            const result = try allocator.dupe(u8, "{\"normalized\":true}");
            return result;
        }

        fn advertise(self: *Self) ?*const Definition {
            return &self.advertised_definition;
        }
    };

    var fake: Fake = .{};
    const tool = Tool.from(&fake, test_definition, .{});
    try std.testing.expect((try tool.preprocess(std.testing.allocator, std.testing.io, null)) == null);
    try std.testing.expectEqual(@as(usize, 0), fake.preprocess_calls);
    const processed = (try tool.preprocess(std.testing.allocator, std.testing.io, "{}")).?;
    defer std.testing.allocator.free(processed);
    try std.testing.expectEqualStrings("{\"normalized\":true}", processed);
    try std.testing.expectEqual(@as(usize, 1), fake.preprocess_calls);
    try std.testing.expectEqualStrings("fake", tool.advertised().?.name);
}

fn exerciseToolResultAllocations(allocator: std.mem.Allocator) !void {
    const Fake = struct {
        const Self = @This();
        fn run(
            result_allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: RunContext,
        ) RunError!Result {
            const output = try result_allocator.dupe(u8, "owned output");
            errdefer result_allocator.free(output);
            const first_mime = try result_allocator.dupe(u8, "image/png");
            errdefer result_allocator.free(first_mime);
            const first_data = try result_allocator.dupe(u8, "AAAA");
            errdefer result_allocator.free(first_data);
            const second_mime = try result_allocator.dupe(u8, "image/jpeg");
            errdefer result_allocator.free(second_mime);
            const second_data = try result_allocator.dupe(u8, "BBBB");
            errdefer result_allocator.free(second_data);
            const images = try result_allocator.alloc(ai.Item.Image, 2);
            images[0] = .{ .mime = first_mime, .data_base64 = first_data };
            images[1] = .{ .mime = second_mime, .data_base64 = second_data };
            return .{ .output = output, .images = images };
        }
    };

    var fake: Fake = .{};
    var result = try Tool.from(&fake, test_definition, .{}).run(
        allocator,
        std.testing.io,
        null,
        .{},
    );
    result.deinit(allocator);
}

test "owned tool result frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseToolResultAllocations,
        .{},
    );
}

test "default advertisement returns a safe definition value" {
    const Fake = struct {
        const Self = @This();
        fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: RunContext,
        ) RunError!Result {
            return .{ .output = try allocator.dupe(u8, "ok") };
        }
    };
    var fake: Fake = .{};
    const advertised = Tool.from(&fake, test_definition, .{}).advertised().?;
    try std.testing.expectEqualStrings("fake", advertised.name);
    try std.testing.expectEqualStrings("fake tool", advertised.description);
}

test "cancellation erases a borrowed synchronous probe" {
    const Probe = struct {
        const Self = @This();
        requested: bool,
        pub fn isRequested(self: *const Self) bool {
            return self.requested;
        }
    };
    var probe: Probe = .{ .requested = false };
    const cancellation = Cancellation.from(&probe);
    try std.testing.expect(!cancellation.isRequested());
    probe.requested = true;
    try std.testing.expect(cancellation.isRequested());
}

test "display preview selector overrides its fallback" {
    const Selector = struct {
        fn select(args: ?[]const u8) PreviewMode {
            return if (args != null) .collapsed else .head_tail;
        }
    };
    const display: Display = .{
        .preview_mode = .head,
        .select_preview = Selector.select,
    };
    try std.testing.expectEqual(PreviewMode.head_tail, display.preview(null));
    try std.testing.expectEqual(PreviewMode.collapsed, display.preview("{}"));
}

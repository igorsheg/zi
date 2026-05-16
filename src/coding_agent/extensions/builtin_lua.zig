const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const build_options = @import("build_options");

pub const v4_doc_surface = [_][]const u8{
    "zi.doc.fragment",
    "zi.doc.span",
    "zi.doc.marker",
    "zi.doc.step",
    "zi.doc.is_fragment",
    "zi.doc.validate",
    "zi.doc.to_markdown",
};

pub fn install(state: *lua_runtime.LuaState) lua_runtime.LuaError!void {
    try preload(state, "zi.doc", build_options.embedded_zi_doc_lua);
}

fn preload(state: *lua_runtime.LuaState, module_name: []const u8, source: []const u8) lua_runtime.LuaError!void {
    var chunk: std.Io.Writer.Allocating = .init(state.allocator);
    defer chunk.deinit();

    const writer = &chunk.writer;
    writer.writeAll("package.preload[") catch return error.OutOfMemory;
    writeLuaString(writer, module_name) catch return error.OutOfMemory;
    writer.writeAll("] = function()\n") catch return error.OutOfMemory;
    writer.writeAll(source) catch return error.OutOfMemory;
    writer.writeAll("\nend\n") catch return error.OutOfMemory;

    const chunk_name_base = std.fmt.allocPrint(state.allocator, "@zi.builtin.{s}", .{module_name}) catch return error.OutOfMemory;
    defer state.allocator.free(chunk_name_base);
    const chunk_name = state.allocator.dupeZ(u8, chunk_name_base) catch return error.OutOfMemory;
    defer state.allocator.free(chunk_name);

    try state.doString(chunk.written(), chunk_name);
}

fn writeLuaString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

test "builtin zi.doc Lua helper emits zi.doc.v1 tables" {
    var state = try lua_runtime.LuaState.init(std.testing.allocator);
    defer state.deinit();

    try install(&state);
    try state.doString(
        \\local doc = require("zi.doc")
        \\local p = doc.fragment({ doc.step("done", "grep", "ok"), doc.text("body", { collapsed_lines = 0 }), doc.markdown("# title") })
        \\assert(p.schema == "zi.doc.v1")
        \\assert(p.blocks[1].type == "line")
        \\assert(p.blocks[1].marker.text == "✓")
        \\assert(p.blocks[2].collapsed_lines == 0)
        \\assert(p.blocks[3].type == "markdown")
    , "@test.zi_doc");
}

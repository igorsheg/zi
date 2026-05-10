const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse (optimize != .Debug);
    const app_version = b.option([]const u8, "version", "Application version") orelse "0.0.1-dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);

    const self_docs_generated = generateSelfDocsModule(b);

    const generate_models = b.addExecutable(.{
        .name = "generate-models",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate-models.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const generate_models_run = b.addRunArtifact(generate_models);
    generate_models_run.stdio = .inherit;
    generate_models_run.addArg(b.pathFromRoot("src/ai/models_generated.zig"));
    b.step("generate-models", "Generate AI model catalog").dependOn(&generate_models_run.step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe_mod.addOptions("build_options", build_options);
    exe_mod.addImport("self_docs_embedded", b.createModule(.{ .root_source_file = self_docs_generated }));
    exe_mod.addImport("mdman_parser", b.createModule(.{ .root_source_file = b.path("website/mdman/parser.zig") }));

    const lua_dep = b.dependency("lua", .{});
    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        }),
    });
    const lua_c_sources = [_][]const u8{
        "src/lapi.c",     "src/lauxlib.c",  "src/lbaselib.c", "src/lcode.c",
        "src/lcorolib.c", "src/lctype.c",   "src/ldblib.c",   "src/ldebug.c",
        "src/ldo.c",      "src/ldump.c",    "src/lfunc.c",    "src/lgc.c",
        "src/linit.c",    "src/liolib.c",   "src/llex.c",     "src/lmathlib.c",
        "src/lmem.c",     "src/loadlib.c",  "src/lobject.c",  "src/lopcodes.c",
        "src/loslib.c",   "src/lparser.c",  "src/lstate.c",   "src/lstring.c",
        "src/lstrlib.c",  "src/ltable.c",   "src/ltablib.c",  "src/ltm.c",
        "src/lundump.c",  "src/lutf8lib.c", "src/lvm.c",      "src/lzio.c",
    };
    const lua_cflags = [_][]const u8{
        "-std=gnu99",
        "-DLUA_USE_POSIX",
        "-DLUA_USE_DLOPEN",
        "-fno-sanitize=undefined",
    };
    lua_lib.root_module.addCSourceFiles(.{
        .root = lua_dep.path("."),
        .files = &lua_c_sources,
        .flags = &lua_cflags,
    });
    lua_lib.root_module.addIncludePath(lua_dep.path("src"));
    lua_lib.installHeadersDirectory(lua_dep.path("src"), "", .{
        .include_extensions = &.{".h"},
    });

    const env_mod = b.createModule(.{ .root_source_file = b.path("src/env.zig") });
    exe_mod.addImport("env", env_mod);
    exe_mod.addIncludePath(lua_dep.path("src"));
    exe_mod.linkLibrary(lua_lib);
    if (target.result.os.tag == .macos) {
        exe_mod.addCSourceFile(.{ .file = b.path("src/tui/terminal/clipboard_macos.m"), .flags = &.{"-fobjc-arc"} });
        exe_mod.linkFramework("AppKit", .{});
        exe_mod.linkFramework("Foundation", .{});
    }

    const exe = b.addExecutable(.{
        .name = "zi",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    if (target.result.os.tag == .macos) {
        const webview_host_mod = b.createModule(.{
            .root_source_file = b.path("tools/zi-webview-host/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        });
        webview_host_mod.addCSourceFile(.{ .file = b.path("src/coding_agent/webview/host/macos_host.m"), .flags = &.{"-fobjc-arc"} });
        webview_host_mod.linkFramework("AppKit", .{});
        webview_host_mod.linkFramework("Foundation", .{});
        webview_host_mod.linkFramework("WebKit", .{});
        const webview_host = b.addExecutable(.{
            .name = "zi-webview-host",
            .root_module = webview_host_mod,
        });
        b.installArtifact(webview_host);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (target.result.os.tag == .macos) {
        run_cmd.setEnvironmentVariable("ZI_WEBVIEW_HOST", b.getInstallPath(.bin, "zi-webview-host"));
    }
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zi").dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    test_mod.addOptions("build_options", build_options);
    test_mod.addImport("self_docs_embedded", b.createModule(.{ .root_source_file = self_docs_generated }));
    test_mod.addImport("mdman_parser", b.createModule(.{ .root_source_file = b.path("website/mdman/parser.zig") }));
    test_mod.addImport("env", env_mod);
    test_mod.addIncludePath(lua_dep.path("src"));
    test_mod.linkLibrary(lua_lib);
    if (target.result.os.tag == .macos) {
        test_mod.addCSourceFile(.{ .file = b.path("src/tui/terminal/clipboard_macos.m"), .flags = &.{"-fobjc-arc"} });
        test_mod.linkFramework("AppKit", .{});
        test_mod.linkFramework("Foundation", .{});
    }
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const DocMeta = struct {
    path: []const u8,
    slug: []const u8,
    title: []const u8,
    order: i32,
    aliases: []const []const u8,
    body: []const u8,
};

fn generateSelfDocsModule(b: *std.Build) std.Build.LazyPath {
    const allocator = b.allocator;
    const docs_dir = b.pathFromRoot("website/docs/man");
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, docs_dir, .{ .iterate = true }) catch @panic("open website/docs/man failed");
    defer dir.close(std.Options.debug_io);

    var metas: std.ArrayList(DocMeta) = .empty;
    var walker = dir.iterate();
    while (walker.next(std.Options.debug_io) catch @panic("iterate website/docs/man failed")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const rel = b.fmt("website/docs/man/{s}", .{entry.name});
        const abs = b.pathFromRoot(rel);
        const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, abs, allocator, .limited(1024 * 1024)) catch @panic("read self doc failed");
        const meta = parseDocMeta(allocator, rel, content) catch @panic("parse self doc frontmatter failed");
        metas.append(allocator, meta) catch @panic("append self doc meta failed");
    }

    std.mem.sort(DocMeta, metas.items, {}, struct {
        fn lessThan(_: void, a: DocMeta, rhs: DocMeta) bool {
            if (a.order == rhs.order) return std.mem.lessThan(u8, a.slug, rhs.slug);
            return a.order < rhs.order;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    w.writeAll("pub const Doc = struct { slug: []const u8, title: []const u8, order: i32, path: []const u8, aliases: []const []const u8, body: []const u8 };\n\n") catch @panic("write self docs failed");
    w.writeAll("pub const docs = [_]Doc{\n") catch @panic("write self docs failed");
    for (metas.items) |meta| {
        w.print("    .{{ .slug = ", .{}) catch unreachable;
        writeZigString(w, meta.slug) catch unreachable;
        w.print(", .title = ", .{}) catch unreachable;
        writeZigString(w, meta.title) catch unreachable;
        w.print(", .order = {d}, .path = ", .{meta.order}) catch unreachable;
        writeZigString(w, meta.path) catch unreachable;
        w.writeAll(", .aliases = &.{") catch unreachable;
        for (meta.aliases, 0..) |alias, i| {
            if (i > 0) w.writeAll(", ") catch unreachable;
            writeZigString(w, alias) catch unreachable;
        }
        w.writeAll("}, .body = ") catch unreachable;
        writeZigString(w, meta.body) catch unreachable;
        w.writeAll(" },\n") catch unreachable;
    }
    w.writeAll("};\n") catch @panic("write self docs failed");

    const wf = b.addWriteFiles();
    return wf.add("self_docs_embedded.zig", out.written());
}

fn parseDocMeta(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !DocMeta {
    if (!std.mem.startsWith(u8, content, "---\n")) return error.MissingFrontmatter;
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    var slug: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var order: ?i32 = null;
    var aliases: std.ArrayList([]const u8) = .empty;
    var in_aliases = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "---")) break;
        if (std.mem.startsWith(u8, line, "  - ") and in_aliases) {
            try aliases.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, line[4..], " \t")));
            continue;
        }
        in_aliases = false;
        if (std.mem.startsWith(u8, line, "slug:")) {
            slug = try allocator.dupe(u8, std.mem.trim(u8, line[5..], " \t"));
        } else if (std.mem.startsWith(u8, line, "title:")) {
            title = try allocator.dupe(u8, std.mem.trim(u8, line[6..], " \t"));
        } else if (std.mem.startsWith(u8, line, "order:")) {
            order = try std.fmt.parseInt(i32, std.mem.trim(u8, line[6..], " \t"), 10);
        } else if (std.mem.eql(u8, line, "aliases:")) {
            in_aliases = true;
        }
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .slug = slug orelse return error.MissingSlug,
        .title = title orelse return error.MissingTitle,
        .order = order orelse return error.MissingOrder,
        .aliases = try aliases.toOwnedSlice(allocator),
        .body = try allocator.dupe(u8, content),
    };
}

fn writeZigString(writer: anytype, value: []const u8) !void {
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

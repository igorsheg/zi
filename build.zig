const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse (optimize != .Debug);

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

    // ── executable ──────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    // ── lua 5.4 (vendored via build.zig.zon) ────────────────────────────
    //
    // Lua is compiled as a static library from upstream C sources and
    // linked into the exe module. The .zig.zon dependency pulls the
    // official 5.4.7 tarball; zig's fetcher verifies it by hash.
    //
    // We compile every .c file in src/ EXCEPT `lua.c` and `luac.c`,
    // which contain `main()` for the standalone interpreter and
    // bytecode compiler respectively.
    //
    // LUA_USE_POSIX enables POSIX-specific features (popen, tmpfile,
    // etc.); LUA_USE_DLOPEN enables `require` of C shared libs at
    // runtime on Linux/macOS. Both match upstream Makefile defaults
    // for the `posix` / `macosx` targets.
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

    // Expose Lua headers to zig code via `@cImport` in src/extensions/lua_runtime.zig.
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

    const doom_helper = b.addExecutable(.{
        .name = "zi-doom-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/doom-helper/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    b.installArtifact(doom_helper);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zi").dependOn(&run_cmd.step);

    // ── tests ───────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
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

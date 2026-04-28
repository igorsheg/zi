const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zine owns the root site. The dependency is pinned in website/build.zig.zon,
    // but the build uses the installed zine binary so zi's root build graph stays
    // fully independent from website tooling.
    const zine_site = b.addSystemCommand(&.{
        "zine",
        "release",
        "--force",
        b.fmt("--output={s}", .{b.install_prefix}),
    });

    // mdman owns /man. It is intentionally local to the website project.
    const mdman = b.addExecutable(.{
        .name = "mdman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("mdman/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_mdman_html = b.addRunArtifact(mdman);
    run_mdman_html.addArgs(&.{ "--html-fragment", "--name", "zi", "--section", "1" });
    run_mdman_html.addFileArg(b.path("docs/zi.1.md"));
    const man_fragment = run_mdman_html.captureStdOut();

    const man_page = b.addSystemCommand(&.{ "cat", "--" });
    man_page.addFileArg(b.path("docs/web/man-header.html"));
    man_page.addFileArg(man_fragment);
    man_page.addFileArg(b.path("docs/web/man-footer.html"));
    const install_man = b.addInstallFileWithDir(man_page.captureStdOut(), .prefix, "man/index.html");

    const web = b.step("web", "Build the compound static website");
    web.dependOn(&zine_site.step);
    web.dependOn(&install_man.step);

    b.getInstallStep().dependOn(web);
}

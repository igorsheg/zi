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

    const man_pages = .{
        .{ "docs/man/00-intro.md", "man/index.html", "man/index.md", "zi(1)", "", "", "cli", "cli.html" },
        .{ "docs/man/10-cli.md", "man/cli.html", "man/cli.md", "cli", "intro", "index.html", "extensions", "extensions.html" },
        .{ "docs/man/20-extension-model.md", "man/extensions.html", "man/extensions.md", "extensions", "cli", "cli.html", "api", "api.html" },
        .{ "docs/man/30-extension-api.md", "man/api.html", "man/api.md", "api", "extensions", "extensions.html", "context", "context.html" },
        .{ "docs/man/40-context-api.md", "man/context.html", "man/context.md", "context", "api", "api.html", "guidance", "guidance.html" },
        .{ "docs/man/50-guidance.md", "man/guidance.html", "man/guidance.md", "guidance", "context", "context.html", "", "" },
    };

    const web = b.step("web", "Build the compound static website");
    web.dependOn(&zine_site.step);

    inline for (man_pages) |entry| {
        const md_file, const html_file, const markdown_file, const page_title, const prev_label, const prev_url, const next_label, const next_url = entry;

        const run_mdman_html = b.addRunArtifact(mdman);
        const markdown_url = markdown_file[4..];
        run_mdman_html.addArgs(&.{ "--html-fragment", "--name", "zi", "--section", "1", "--page-label", "ZI(1)", "--page-title", page_title, "--markdown-url", markdown_url });
        if (prev_label.len > 0) run_mdman_html.addArgs(&.{ "--prev-label", prev_label });
        if (prev_url.len > 0) run_mdman_html.addArgs(&.{ "--prev-url", prev_url });
        if (next_label.len > 0) run_mdman_html.addArgs(&.{ "--next-label", next_label });
        if (next_url.len > 0) run_mdman_html.addArgs(&.{ "--next-url", next_url });
        run_mdman_html.addFileArg(b.path(md_file));
        const man_fragment = run_mdman_html.captureStdOut();

        const man_page = b.addSystemCommand(&.{ "cat", "--" });
        man_page.addFileArg(b.path("docs/web/man-header.html"));
        man_page.addFileArg(man_fragment);
        man_page.addFileArg(b.path("docs/web/man-footer.html"));
        const install_man = b.addInstallFileWithDir(man_page.captureStdOut(), .prefix, html_file);
        web.dependOn(&install_man.step);

        const install_markdown = b.addInstallFileWithDir(b.path(md_file), .prefix, markdown_file);
        web.dependOn(&install_markdown.step);
    }

    b.getInstallStep().dependOn(web);
}

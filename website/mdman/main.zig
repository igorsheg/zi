const std = @import("std");
const parser = @import("parser.zig");
const roff = @import("roff.zig");
const html = @import("html.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try printUsage(init.io);
        std.process.exit(1);
    }

    var input_file: ?[]const u8 = null;
    var output_format: enum { roff, html } = .roff;
    var name: []const u8 = "prise";
    var section: []const u8 = "1";
    var html_fragment: bool = false;
    var page_label: []const u8 = "ZI(1)";
    var page_title: []const u8 = "zi manual";
    var prev_label: ?[]const u8 = null;
    var prev_url: ?[]const u8 = null;
    var next_label: ?[]const u8 = null;
    var next_url: ?[]const u8 = null;
    var markdown_url: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(init.io);
            return;
        } else if (std.mem.eql(u8, arg, "--html")) {
            output_format = .html;
        } else if (std.mem.eql(u8, arg, "--html-fragment")) {
            output_format = .html;
            html_fragment = true;
        } else if (std.mem.eql(u8, arg, "--roff")) {
            output_format = .roff;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --name requires an argument\n", .{});
                std.process.exit(1);
            }
            name = args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--section")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --section requires an argument\n", .{});
                std.process.exit(1);
            }
            section = args[i];
        } else if (std.mem.eql(u8, arg, "--page-label")) {
            i += 1;
            if (i >= args.len) fatalMissing("--page-label");
            page_label = args[i];
        } else if (std.mem.eql(u8, arg, "--page-title")) {
            i += 1;
            if (i >= args.len) fatalMissing("--page-title");
            page_title = args[i];
        } else if (std.mem.eql(u8, arg, "--prev-label")) {
            i += 1;
            if (i >= args.len) fatalMissing("--prev-label");
            prev_label = args[i];
        } else if (std.mem.eql(u8, arg, "--prev-url")) {
            i += 1;
            if (i >= args.len) fatalMissing("--prev-url");
            prev_url = args[i];
        } else if (std.mem.eql(u8, arg, "--next-label")) {
            i += 1;
            if (i >= args.len) fatalMissing("--next-label");
            next_label = args[i];
        } else if (std.mem.eql(u8, arg, "--next-url")) {
            i += 1;
            if (i >= args.len) fatalMissing("--next-url");
            next_url = args[i];
        } else if (std.mem.eql(u8, arg, "--markdown-url")) {
            i += 1;
            if (i >= args.len) fatalMissing("--markdown-url");
            markdown_url = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_file = arg;
        } else {
            std.debug.print("error: unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const file_path = input_file orelse {
        std.debug.print("error: no input file specified\n", .{});
        std.process.exit(1);
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .limited(1024 * 1024));
    const doc = try parser.parse(allocator, source);

    const output = switch (output_format) {
        .roff => try roff.render(allocator, doc, name, section),
        .html => try html.render(allocator, doc, name, .{
            .fragment = html_fragment,
            .page_label = page_label,
            .page_title = page_title,
            .prev_label = prev_label,
            .prev_url = prev_url,
            .next_label = next_label,
            .next_url = next_url,
            .markdown_url = markdown_url,
        }),
    };

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.writeAll(output);
}

fn fatalMissing(option: []const u8) noreturn {
    std.debug.print("error: {s} requires an argument\n", .{option});
    std.process.exit(1);
}

fn printUsage(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    defer stderr.interface.flush() catch {};
    try stderr.interface.writeAll(
        \\Usage: mdman [OPTIONS] <FILE>
        \\
        \\Convert Markdown to man page (roff) or HTML.
        \\
        \\Options:
        \\  --roff           Output roff format (default)
        \\  --html           Output full HTML page
        \\  --html-fragment  Output HTML fragment (no wrapper)
        \\  -n, --name       Man page name (default: prise)
        \\  -s, --section    Man page section (default: 1)
        \\  -h, --help       Show this help
        \\
    );
}

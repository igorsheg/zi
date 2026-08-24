const std = @import("std");
const ToolContract = @import("Tool.zig");
const OutputCap = @import("OutputCap.zig");
const text = @import("../text/root.zig");
const ai = @import("../ai/root.zig");
const ImageSniff = @import("ImageSniff.zig");
const Path = @import("Path.zig");

const json_argument_bytes: usize = 64 * 1024;
const stream_chunk_bytes: usize = 8192;
const final_result_bytes: usize = OutputCap.maximum_capture_bytes;
const image_max_bytes: usize = 5 * 1024 * 1024 / 4 * 3;
const image_max_side: u32 = 8000;

pub const Config = struct {
    output_bytes: usize = OutputCap.default_output_bytes,
    home: ?[]const u8 = null,
    path_env: ?[]const u8 = null,
};

pub const Read = struct {
    config: Config = .{},

    pub fn tool(self: *Read) ToolContract.Tool {
        return ToolContract.Tool.from(self, definition, .{
            .arg_name = "path",
            .preview_mode = .collapsed,
            .format_extra = formatLineRange,
            .collapse_argument = collapsePath,
        });
    }

    pub fn run(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Read,
        args_json: ?[]const u8,
        run_context: ToolContract.RunContext,
    ) ToolContract.RunError!ToolContract.Result {
        if (self.config.output_bytes == 0 or self.config.output_bytes > final_result_bytes)
            return error.InvalidResult;

        const json_bytes = args_json orelse "{}";
        if (json_bytes.len > json_argument_bytes)
            return resultCopy(allocator, "invalid arguments: input exceeds 65536 bytes");
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json_bytes,
            .{},
        ) catch |parse_error| switch (parse_error) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return resultFormat(
                allocator,
                "invalid arguments: {s}",
                .{@errorName(parse_error)},
            ),
        };
        defer parsed.deinit();

        const args = parseArgs(parsed.value) catch |argument_error| {
            return resultCopy(allocator, argumentErrorText(argument_error));
        };
        const expanded_path = try Path.expandHome(allocator, args.path, self.config.home);
        defer allocator.free(expanded_path);

        // Zig 0.16's std.Io has no nonblocking regular-only open. This preflight avoids
        // admitted FIFOs and devices; the immediate handle stat remains authoritative.
        // A final-component swap during open can still block on Unix, matching hax's limit.
        const path_stat = std.Io.Dir.cwd().statFile(io, expanded_path, .{}) catch |stat_error| {
            return readErrorResult(allocator, expanded_path, stat_error);
        };
        if (path_stat.kind != .file) {
            return resultFormat(
                allocator,
                "{s} exists but is not a regular file",
                .{expanded_path},
            );
        }
        const file = std.Io.Dir.cwd().openFile(io, expanded_path, .{}) catch |open_error| {
            return readErrorResult(allocator, expanded_path, open_error);
        };
        defer file.close(io);
        const stat = file.stat(io) catch |stat_error| {
            return readErrorResult(allocator, expanded_path, stat_error);
        };
        if (stat.kind != .file) {
            return resultFormat(
                allocator,
                "{s} exists but is not a regular file",
                .{expanded_path},
            );
        }
        var reader_buffer: [stream_chunk_bytes]u8 = undefined;
        var file_reader = file.reader(io, &reader_buffer);
        const image_signature = readFileImageSignature(&file_reader) catch false;
        if (image_signature) {
            return readImage(
                allocator,
                io,
                &file_reader,
                expanded_path,
                stat.size,
                self.config.path_env,
                run_context.image_input,
            );
        }
        if (!args.offset_provided and !args.limit_provided and stat.size > self.config.output_bytes) {
            return resultFormat(
                allocator,
                "{s} is {d} bytes; cap is {d}. Pass offset/limit to read a slice, or use bash with grep/head/tail.",
                .{ expanded_path, stat.size, self.config.output_bytes },
            );
        }

        var read_result = readTextSlice(
            allocator,
            &file_reader,
            args.offset,
            args.limit,
            self.config.output_bytes,
        ) catch |read_error| switch (read_error) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidResult => return error.InvalidResult,
            else => return readErrorResult(allocator, expanded_path, read_error),
        };
        defer read_result.deinit(allocator);

        if (read_result.binary) {
            return resultFormat(
                allocator,
                "{s} appears to be binary (NUL byte found in first 8 KiB)",
                .{expanded_path},
            );
        }
        if (read_result.offset_past_eof) {
            return resultFormat(
                allocator,
                "(file has {d} line{s}; offset {d} is past EOF)",
                .{
                    read_result.line_count,
                    if (read_result.line_count == 1) "" else "s",
                    args.offset,
                },
            );
        }
        return formatTextResult(allocator, &read_result, self.config.output_bytes);
    }

    pub fn preprocess(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Read,
        args_json: ?[]const u8,
    ) error{OutOfMemory}!?[]u8 {
        return Path.preprocessArgs(
            allocator,
            io,
            args_json,
            self.config.home,
            json_argument_bytes,
        );
    }
};

const ArgumentError = error{
    MissingPath,
    OffsetNotInteger,
    OffsetBelowOne,
    LimitNotInteger,
    LimitBelowOne,
};

const Args = struct {
    path: []const u8,
    offset: i64 = 1,
    limit: i64 = 0,
    offset_provided: bool = false,
    limit_provided: bool = false,
};

fn parseArgs(value: std.json.Value) ArgumentError!Args {
    if (value != .object) return error.MissingPath;
    const path_value = value.object.get("path") orelse return error.MissingPath;
    if (path_value != .string or path_value.string.len == 0) return error.MissingPath;
    var args: Args = .{ .path = path_value.string };
    if (value.object.get("offset")) |offset| {
        args.offset_provided = true;
        if (offset != .integer) return error.OffsetNotInteger;
        if (offset.integer < 1) return error.OffsetBelowOne;
        args.offset = offset.integer;
    }
    if (value.object.get("limit")) |limit| {
        args.limit_provided = true;
        if (limit != .integer) return error.LimitNotInteger;
        if (limit.integer < 1) return error.LimitBelowOne;
        args.limit = limit.integer;
    }
    return args;
}

fn argumentErrorText(err: ArgumentError) []const u8 {
    return switch (err) {
        error.MissingPath => "missing 'path' argument",
        error.OffsetNotInteger => "'offset' must be an integer",
        error.OffsetBelowOne => "'offset' must be >= 1",
        error.LimitNotInteger => "'limit' must be an integer",
        error.LimitBelowOne => "'limit' must be >= 1",
    };
}

const Truncation = enum {
    none,
    bytes,
    lines,
};

const ReadResult = struct {
    content: std.ArrayList(u8) = .empty,
    truncation: Truncation = .none,
    offset_past_eof: bool = false,
    binary: bool = false,
    line_count: i64 = 0,

    fn deinit(self: *ReadResult, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.* = undefined;
    }
};

const ReadSliceError = error{
    OutOfMemory,
    InvalidResult,
} || std.Io.File.Reader.Error;

fn readImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_reader: *std.Io.File.Reader,
    path: []const u8,
    stat_size: u64,
    path_env: ?[]const u8,
    image_input: ToolContract.ImageInput,
) ToolContract.RunError!ToolContract.Result {
    if (image_input == .unsupported) {
        return resultFormat(
            allocator,
            "{s} is an image, but the current model does not accept image input, " ++
                "so it was not attached. Ask the user to switch to a vision-capable " ++
                "model (or set image_input=on if this detection is wrong).",
            .{path},
        );
    }
    if (stat_size > image_max_bytes) {
        const hint = try formatDownscaleHint(allocator, io, path, path_env);
        defer allocator.free(hint);
        return resultFormat(
            allocator,
            "{s} is {d} bytes; images over {d} bytes exceed provider limits: {s}.",
            .{ path, stat_size, image_max_bytes, hint },
        );
    }

    const bytes = file_reader.interface.allocRemaining(
        allocator,
        .limited(image_max_bytes + 1),
    ) catch |read_error| switch (read_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return imageChangedResult(allocator, path),
    };
    defer allocator.free(bytes);
    if (bytes.len > image_max_bytes) return imageChangedResult(allocator, path);
    const info = ImageSniff.sniff(bytes) orelse return imageChangedResult(allocator, path);
    if (info.width == 0 or info.height == 0 or !info.complete) {
        return resultFormat(
            allocator,
            "{s} looks like {s} but is truncated or malformed, so it was not attached. " ++
                "Check that the file is a complete image.",
            .{ path, info.mime() },
        );
    }
    if (info.width > image_max_side or info.height > image_max_side) {
        const hint = try formatDownscaleHint(allocator, io, path, path_env);
        defer allocator.free(hint);
        return resultFormat(
            allocator,
            "{s} is {d}x{d}; images over {d}px per side exceed provider limits: {s}.",
            .{ path, info.width, info.height, image_max_side, hint },
        );
    }

    const output = try std.fmt.allocPrint(
        allocator,
        "Read image {s} ({s}, {d}x{d}, {d} bytes).",
        .{ path, info.mime(), info.width, info.height, bytes.len },
    );
    errdefer allocator.free(output);
    const mime = try allocator.dupe(u8, info.mime());
    errdefer allocator.free(mime);
    const encoded_length = std.base64.standard.Encoder.calcSize(bytes.len);
    const data_base64 = try allocator.alloc(u8, encoded_length);
    errdefer allocator.free(data_base64);
    _ = std.base64.standard.Encoder.encode(data_base64, bytes);
    const images = try allocator.alloc(ai.Item.Image, 1);
    images[0] = .{
        .mime = mime,
        .data_base64 = data_base64,
        .width = info.width,
        .height = info.height,
    };
    return .{ .output = output, .images = images };
}

fn imageChangedResult(
    allocator: std.mem.Allocator,
    path: []const u8,
) error{OutOfMemory}!ToolContract.Result {
    return resultFormat(
        allocator,
        "error reading {s}: file changed while reading",
        .{path},
    );
}

const ResizeCommand = enum {
    magick,
    convert,
    sips,
};

fn formatDownscaleHint(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    path_env: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const quoted = try shellSingleQuote(allocator, path);
    defer allocator.free(quoted);
    const prefix = if (path.len > 0 and path[0] == '-') "./" else "";
    if (try findResizeCommand(allocator, io, path_env)) |command| {
        return switch (command) {
            .magick, .convert => std.fmt.allocPrint(
                allocator,
                "downscale it first, e.g.: {s} {s}{s} -resize '1568x1568>' " ++
                    "/tmp/downscaled.png: then read the copy",
                .{ @tagName(command), prefix, quoted },
            ),
            .sips => std.fmt.allocPrint(
                allocator,
                "downscale it first, e.g.: sips -Z 1568 {s}{s} " ++
                    "--out /tmp/downscaled.png: then read the copy",
                .{ prefix, quoted },
            ),
        };
    }
    return allocator.dupe(
        u8,
        "downscale it first (no ImageMagick found on PATH; ask the user how they'd " ++
            "like to resize it)",
    );
}

fn findResizeCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_env: ?[]const u8,
) error{OutOfMemory}!?ResizeCommand {
    inline for ([_]ResizeCommand{ .magick, .convert, .sips }) |command| {
        if (try executableOnPath(allocator, io, path_env, @tagName(command))) return command;
    }
    return null;
}

fn executableOnPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_env: ?[]const u8,
    name: []const u8,
) error{OutOfMemory}!bool {
    var entries = std.mem.splitScalar(u8, path_env orelse return false, ':');
    while (entries.next()) |entry| {
        if (!std.fs.path.isAbsolute(entry)) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, name });
        defer allocator.free(candidate);
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind != .file) continue;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return true;
    }
    return false;
}

fn shellSingleQuote(
    allocator: std.mem.Allocator,
    input: []const u8,
) error{OutOfMemory}![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '\'');
    for (input) |byte| {
        if (byte == '\'') {
            try output.appendSlice(allocator, "'\\''");
        } else {
            try output.append(allocator, byte);
        }
    }
    try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

fn readFileImageSignature(file_reader: *std.Io.File.Reader) error{ReadFailed}!bool {
    const header = file_reader.interface.peekGreedy(16) catch |peek_error| switch (peek_error) {
        error.EndOfStream => file_reader.interface.buffered(),
        error.ReadFailed => return error.ReadFailed,
    };
    return ImageSniff.sniff(header) != null;
}

fn readTextSlice(
    allocator: std.mem.Allocator,
    file_reader: *std.Io.File.Reader,
    offset: i64,
    limit: i64,
    output_limit: usize,
) ReadSliceError!ReadResult {
    var result: ReadResult = .{};
    errdefer result.deinit(allocator);
    const line_limit: i64 = if (limit > 0 and limit < OutputCap.maximum_lines)
        limit
    else
        OutputCap.maximum_lines;
    var chunk: [stream_chunk_bytes]u8 = undefined;
    var completed_lines: i64 = 0;
    var returned_lines: i64 = 0;
    var line_number = offset;
    var in_range = offset == 1;
    var reached_eof = false;
    var current_line_has_content = false;
    var checking_first_chunk = true;
    var needs_prefix = in_range;

    read_loop: while (true) {
        const bytes_read = file_reader.interface.readSliceShort(&chunk) catch
            return file_reader.err orelse error.InputOutput;
        if (bytes_read == 0) {
            reached_eof = true;
            break;
        }
        if (checking_first_chunk) {
            const first = chunk[0..bytes_read];
            if (std.mem.findScalar(u8, first, 0) != null) {
                result.binary = true;
                break;
            }
            checking_first_chunk = false;
        }

        var run_start: usize = 0;
        for (chunk[0..bytes_read], 0..) |byte, index| {
            if (byte != '\n') current_line_has_content = true;
            if (!in_range) {
                if (byte == '\n') {
                    completed_lines += 1;
                    current_line_has_content = false;
                    if (completed_lines + 1 >= offset) {
                        in_range = true;
                        needs_prefix = true;
                        run_start = index + 1;
                    }
                }
                continue;
            }
            if (byte != '\n') continue;
            if (try appendNumberedRun(
                allocator,
                &result.content,
                chunk[0..bytes_read],
                run_start,
                index + 1,
                output_limit,
                line_number,
                &needs_prefix,
            )) {
                result.truncation = .bytes;
                break :read_loop;
            }
            run_start = index + 1;
            completed_lines += 1;
            returned_lines += 1;
            line_number += 1;
            needs_prefix = true;
            current_line_has_content = false;
            if (returned_lines < line_limit) continue;
            if (limit > 0 and limit <= OutputCap.maximum_lines) break :read_loop;
            const has_more = if (index + 1 < bytes_read)
                true
            else if (bytes_read < chunk.len)
                false
            else
                readOneHasContent(file_reader);
            if (has_more) result.truncation = .lines;
            break :read_loop;
        }
        if (in_range and try appendNumberedRun(
            allocator,
            &result.content,
            chunk[0..bytes_read],
            run_start,
            bytes_read,
            output_limit,
            line_number,
            &needs_prefix,
        )) {
            result.truncation = .bytes;
            break;
        }
        if (bytes_read < chunk.len) {
            reached_eof = true;
            break;
        }
    }

    if (current_line_has_content and reached_eof) {
        completed_lines += 1;
        if (in_range) returned_lines += 1;
    }
    result.line_count = completed_lines;
    if (reached_eof and returned_lines == 0 and (completed_lines > 0 or offset > 1)) {
        result.offset_past_eof = true;
        result.content.clearRetainingCapacity();
    }
    return result;
}

/// Once the bounded 2000-line result is complete, hax treats a failed one-byte
/// look-ahead conservatively as evidence of more content rather than failing it.
fn readOneHasContent(file_reader: *std.Io.File.Reader) bool {
    var byte: [1]u8 = undefined;
    const count = file_reader.interface.readSliceShort(&byte) catch return true;
    return count != 0;
}

fn appendNumberedRun(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    chunk: []const u8,
    start: usize,
    end: usize,
    output_limit: usize,
    line_number: i64,
    needs_prefix: *bool,
) error{ OutOfMemory, InvalidResult }!bool {
    if (end <= start) return false;
    if (needs_prefix.*) {
        var digits_buffer: [32]u8 = undefined;
        const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{line_number}) catch
            return error.InvalidResult;
        var prefix_buffer: [40]u8 = undefined;
        const padding = 6 -| digits.len;
        @memset(prefix_buffer[0..padding], ' ');
        @memcpy(prefix_buffer[padding .. padding + digits.len], digits);
        @memcpy(prefix_buffer[padding + digits.len .. padding + digits.len + "→".len], "→");
        const prefix = prefix_buffer[0 .. padding + digits.len + "→".len];
        const remaining = output_limit -| output.items.len;
        if (prefix.len >= remaining) return true;
        try output.appendSlice(allocator, prefix);
        needs_prefix.* = false;
    }
    return appendWithLimit(allocator, output, chunk[start..end], output_limit);
}

fn appendWithLimit(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    output_limit: usize,
) error{OutOfMemory}!bool {
    if (bytes.len == 0) return false;
    const remaining = output_limit -| output.items.len;
    if (remaining == 0) return true;
    const retained = @min(bytes.len, remaining);
    try output.appendSlice(allocator, bytes[0..retained]);
    return retained != bytes.len;
}

fn formatTextResult(
    allocator: std.mem.Allocator,
    read_result: *ReadResult,
    output_limit: usize,
) ToolContract.RunError!ToolContract.Result {
    const capped = OutputCap.capLineLengths(
        allocator,
        read_result.content.items,
        OutputCap.maximum_line_bytes,
        final_result_bytes,
    ) catch |err| return mapOutputError(err);
    defer allocator.free(capped);
    const sanitized = text.Utf8.sanitize(allocator, capped, final_result_bytes) catch |err|
        return mapOutputError(err);
    defer allocator.free(sanitized);
    return switch (read_result.truncation) {
        .none => .{ .output = try allocator.dupe(u8, sanitized) },
        .bytes => resultFormat(
            allocator,
            "{s}\n\n[truncated at {d} bytes; file is larger: pass offset/limit to read more]",
            .{ sanitized, output_limit },
        ),
        .lines => resultFormat(
            allocator,
            "{s}\n\n[truncated at {d} lines; file has more: pass offset/limit to read more]",
            .{ sanitized, OutputCap.maximum_lines },
        ),
    };
}

fn mapOutputError(err: OutputCap.Error) ToolContract.RunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.InvalidResult,
    };
}

fn resultCopy(
    allocator: std.mem.Allocator,
    output: []const u8,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try allocator.dupe(u8, output) };
}

fn resultFormat(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try std.fmt.allocPrint(allocator, format, args) };
}

fn readErrorResult(
    allocator: std.mem.Allocator,
    path: []const u8,
    err: anyerror,
) error{OutOfMemory}!ToolContract.Result {
    return resultFormat(
        allocator,
        "error reading {s}: {s}",
        .{ path, errorReason(err) },
    );
}

fn errorReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.InputOutput => "Input/output error",
        error.IsDir => "Is a directory",
        error.WouldBlock => "Resource temporarily unavailable",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.NotOpenForReading => "Bad file descriptor",
        error.SocketUnconnected => "Transport endpoint is not connected",
        error.Canceled => "Operation canceled",
        else => @errorName(err),
    };
}

pub fn formatLineRange(
    allocator: std.mem.Allocator,
    args_json: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    const input = args_json orelse return null;
    if (input.len > json_argument_bytes) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const offset_value = parsed.value.object.get("offset");
    const limit_value = parsed.value.object.get("limit");
    if (offset_value == null and limit_value == null) return null;
    if (parsed.value.object.get("path")) |path| {
        if (path == .string and pathHasImageExtension(path.string)) return null;
    }
    const offset: i64 = if (offset_value) |value|
        if (value == .integer) value.integer else 1
    else
        1;
    if (limit_value) |value| {
        if (value == .integer and value.integer >= 1) {
            const end = std.math.add(i64, offset, value.integer - 1) catch std.math.maxInt(i64);
            const range = try std.fmt.allocPrint(allocator, ":{d}-{d}", .{ offset, end });
            return range;
        }
    }
    const range = try std.fmt.allocPrint(allocator, ":{d}-", .{offset});
    return range;
}

fn pathHasImageExtension(path: []const u8) bool {
    const dot = std.mem.findScalarLast(u8, path, '.') orelse return false;
    const extension = path[dot..];
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" }) |known| {
        if (std.ascii.eqlIgnoreCase(extension, known)) return true;
    }
    return false;
}

const generic_basenames = [_][]const u8{
    "AndroidManifest.xml", "build.gradle",   "build.gradle.kts",   "build.rs",         "build.zig",
    "Cargo.toml",          "Chart.yaml",     "CMakeLists.txt",     "compose.yaml",     "compose.yml",
    "composer.json",       "configure.ac",   "conftest.py",        "default.nix",      "docker-compose.yaml",
    "docker-compose.yml",  "Dockerfile",     "flake.nix",          "Gemfile",          "GNUmakefile",
    "go.mod",              "go.sum",         "__init__.py",        "Jenkinsfile",      "justfile",
    "Kbuild",              "Kconfig",        "kustomization.yaml", "lib.rs",           "__main__.py",
    "Makefile",            "manifest.json",  "meson.build",        "mix.exs",          "mod.rs",
    "outputs.tf",          "Package.swift",  "package.json",       "Podfile",          "pom.xml",
    "project.pbxproj",     "pyproject.toml", "Rakefile",           "requirements.txt", "settings.gradle",
    "settings.gradle.kts", "setup.py",       "shell.nix",          "tsconfig.json",    "values.yaml",
    "variables.tf",        "versions.tf",
};

pub fn collapsePath(
    allocator: std.mem.Allocator,
    path: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const input = path orelse return allocator.dupe(u8, "?");
    if (input.len == 0) return allocator.dupe(u8, "?");
    const slash = std.mem.findScalarLast(u8, input, '/');
    const base = if (slash) |index|
        if (index + 1 == input.len) input else input[index + 1 ..]
    else
        input;
    if (base.ptr == input.ptr or !basenameIsGeneric(base)) return allocator.dupe(u8, base);
    const base_start = @intFromPtr(base.ptr) - @intFromPtr(input.ptr);
    const separator = base_start - 1;
    var parent_start = separator;
    while (parent_start > 0 and input[parent_start - 1] != '/') parent_start -= 1;
    if (parent_start == separator) return allocator.dupe(u8, base);
    if (parent_start == 0 or (parent_start == 1 and input[0] == '/'))
        return allocator.dupe(u8, input);
    return std.fmt.allocPrint(allocator, ".../{s}", .{input[parent_start..]});
}

fn basenameIsGeneric(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '.' or stemIsAllCaps(name) or stemEquals(name, "index") or
        stemEquals(name, "main")) return true;
    for (generic_basenames) |generic| {
        if (std.ascii.eqlIgnoreCase(name, generic)) return true;
    }
    return false;
}

fn stemIsAllCaps(name: []const u8) bool {
    var has_upper = false;
    for (name) |byte| {
        if (byte == '.') break;
        if (std.ascii.isLower(byte)) return false;
        if (std.ascii.isUpper(byte)) has_upper = true;
    }
    return has_upper;
}

fn stemEquals(name: []const u8, stem: []const u8) bool {
    if (name.len < stem.len or !std.ascii.eqlIgnoreCase(name[0..stem.len], stem)) return false;
    return name.len == stem.len or name[stem.len] == '.';
}

const parameters = [_]ToolContract.Parameter{
    .{ .name = "path", .type = .string, .required = true, .description = "Path to the file." },
    .{ .name = "offset", .type = .integer, .minimum = 1, .description = "1-indexed first line to return. Default 1." },
    .{
        .name = "limit",
        .type = .integer,
        .minimum = 1,
        .description = "Maximum number of lines to return. Default: to EOF.",
    },
};

pub const definition: ToolContract.Definition = .{
    .name = "read",
    .description = "Read a file from disk and return its contents in `cat -n` style: each " ++
        "line is prefixed with its 1-indexed line number, a → arrow, then the line's content. " ++
        "The prefix is presentation only: it is NOT part of the file on disk; do not " ++
        "include it in `edit` tool `old_string`/`new_string` arguments. Optional 1-indexed " ++
        "line `offset` and `limit` slice a range; without them, the whole file is returned. " ++
        "Image files (PNG/JPEG/GIF/WebP) are detected by content and attached to the result " ++
        "as images when the model supports image input.",
    .parameters = &parameters,
};

fn testPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

fn writeTestFile(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    const file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

fn runTestRead(
    allocator: std.mem.Allocator,
    read: *Read,
    args_json: ?[]const u8,
) !ToolContract.Result {
    return read.tool().run(allocator, std.testing.io, args_json, .{});
}

test "read validates JSON and line arguments as ordinary results" {
    var read: Read = .{};
    const cases = [_]struct { input: ?[]const u8, expected: []const u8 }{
        .{ .input = "{", .expected = "invalid arguments: UnexpectedEndOfInput" },
        .{ .input = null, .expected = "missing 'path' argument" },
        .{ .input = "[]", .expected = "missing 'path' argument" },
        .{ .input = "{\"path\":3}", .expected = "missing 'path' argument" },
        .{ .input = "{\"path\":\"\"}", .expected = "missing 'path' argument" },
        .{ .input = "{\"path\":\"x\",\"offset\":1.5}", .expected = "'offset' must be an integer" },
        .{ .input = "{\"path\":\"x\",\"offset\":0}", .expected = "'offset' must be >= 1" },
        .{ .input = "{\"path\":\"x\",\"limit\":false}", .expected = "'limit' must be an integer" },
        .{ .input = "{\"path\":\"x\",\"limit\":-1}", .expected = "'limit' must be >= 1" },
    };
    for (cases) |case| {
        var result = try runTestRead(std.testing.allocator, &read, case.input);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.output);
    }
}

test "read returns numbered text and exact slices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "sample.txt", "alpha\nbeta\ngamma");
    const path = try testPath(std.testing.allocator, &tmp, "sample.txt");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\"}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var read: Read = .{ .config = .{ .output_bytes = 256 * 1024 } };
    var result = try runTestRead(std.testing.allocator, &read, args);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "     1→alpha\n     2→beta\n     3→gamma",
        result.output,
    );

    const slice_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"offset\":2,\"limit\":1}}",
        .{path},
    );
    defer std.testing.allocator.free(slice_args);
    var slice = try runTestRead(std.testing.allocator, &read, slice_args);
    defer slice.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("     2→beta\n", slice.output);
}

test "read handles empty and past EOF line counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "empty", "");
    try writeTestFile(&tmp, "one", "unterminated");
    const empty_path = try testPath(std.testing.allocator, &tmp, "empty");
    defer std.testing.allocator.free(empty_path);
    const one_path = try testPath(std.testing.allocator, &tmp, "one");
    defer std.testing.allocator.free(one_path);
    var read: Read = .{};
    const empty_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{empty_path});
    defer std.testing.allocator.free(empty_args);
    var empty = try runTestRead(std.testing.allocator, &read, empty_args);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.output.len);

    const past_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"offset\":2}}",
        .{one_path},
    );
    defer std.testing.allocator.free(past_args);
    var past = try runTestRead(std.testing.allocator, &read, past_args);
    defer past.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("(file has 1 line; offset 2 is past EOF)", past.output);
}

test "read refuses unsliced oversize files and permits slices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "large", "first\nsecond\n");
    const path = try testPath(std.testing.allocator, &tmp, "large");
    defer std.testing.allocator.free(path);
    var read: Read = .{ .config = .{ .output_bytes = 10 } };
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var refused = try runTestRead(std.testing.allocator, &read, args);
    defer refused.deinit(std.testing.allocator);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s} is 13 bytes; cap is 10. Pass offset/limit to read a slice, or use bash with grep/head/tail.",
        .{path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, refused.output);

    const sliced_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"limit\":1}}",
        .{path},
    );
    defer std.testing.allocator.free(sliced_args);
    var sliced = try runTestRead(std.testing.allocator, &read, sliced_args);
    defer sliced.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("     1→f", sliced.output[0..10]);
    try std.testing.expect(std.mem.find(u8, sliced.output, "[truncated at 10 bytes") != null);
}

test "read detects binary and image signatures before text output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "binary", "abc\x00def");
    try writeTestFile(&tmp, "picture", "\xff\xd8\xffpayload");
    var read: Read = .{};
    for ([_][]const u8{ "binary", "picture" }, 0..) |name, index| {
        const path = try testPath(std.testing.allocator, &tmp, name);
        defer std.testing.allocator.free(path);
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
        defer std.testing.allocator.free(args);
        var result = try runTestRead(std.testing.allocator, &read, args);
        defer result.deinit(std.testing.allocator);
        if (index == 0) {
            try std.testing.expect(std.mem.endsWith(
                u8,
                result.output,
                "appears to be binary (NUL byte found in first 8 KiB)",
            ));
        } else {
            try std.testing.expect(std.mem.find(
                u8,
                result.output,
                "current model does not accept image input",
            ) != null);
        }
    }
}

test "read caps numbered physical lines before UTF-8 sanitation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [601]u8 = undefined;
    @memset(bytes[0..600], 'x');
    bytes[600] = '\n';
    try writeTestFile(&tmp, "long", &bytes);
    const path = try testPath(std.testing.allocator, &tmp, "long");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{ .config = .{ .output_bytes = 1024 } };
    var result = try runTestRead(std.testing.allocator, &read, args);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.output, "     1→"));
    try std.testing.expect(std.mem.find(u8, result.output, "...[109 bytes elided]\n") != null);
}

test "read display range and collapsed paths match hax" {
    const allocator = std.testing.allocator;
    var read: Read = .{};
    const display = read.tool().display;
    try std.testing.expect(display.format_extra != null);
    try std.testing.expect(display.collapse_argument != null);
    const range = (try display.format_extra.?(allocator, "{\"path\":\"x\",\"offset\":3,\"limit\":4}")).?;
    defer allocator.free(range);
    try std.testing.expectEqualStrings(":3-6", range);
    try std.testing.expect((try formatLineRange(allocator, "{\"path\":\"x\"}")) == null);
    try std.testing.expect((try formatLineRange(
        allocator,
        "{\"path\":\"x.PNG\",\"offset\":1,\"limit\":1}",
    )) == null);
    const cases = [_]struct { input: ?[]const u8, expected: []const u8 }{
        .{ .input = null, .expected = "?" },
        .{ .input = "src/ordinary.zig", .expected = "ordinary.zig" },
        .{ .input = "src/tool/README.md", .expected = ".../tool/README.md" },
        .{ .input = "/etc/Makefile", .expected = "/etc/Makefile" },
        .{ .input = "a//SKILL.md", .expected = "SKILL.md" },
        .{ .input = "dir/", .expected = "dir/" },
    };
    for (cases) |case| {
        const collapsed = try collapsePath(allocator, case.input);
        defer allocator.free(collapsed);
        try std.testing.expectEqualStrings(case.expected, collapsed);
    }
}

test "read preprocess relativizes strict cwd descendants" {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_length];
    const absolute = try std.fs.path.join(std.testing.allocator, &.{ cwd, "src", "tool", "Read.zig" });
    defer std.testing.allocator.free(absolute);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"offset\":3}}",
        .{absolute},
    );
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    const rewritten = (try read.tool().preprocess(
        std.testing.allocator,
        std.testing.io,
        args,
    )).?;
    defer std.testing.allocator.free(rewritten);
    try std.testing.expectEqualStrings("{\"path\":\"src/tool/Read.zig\",\"offset\":3}", rewritten);
    try std.testing.expect((try read.tool().preprocess(
        std.testing.allocator,
        std.testing.io,
        "{\"path\":\"src/tool/Read.zig\"}",
    )) == null);
}

test "read applies implicit and explicit 2000 line semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..2001) |_| try source.appendSlice(std.testing.allocator, "x\n");
    try writeTestFile(&tmp, "lines", source.items);
    const path = try testPath(std.testing.allocator, &tmp, "lines");
    defer std.testing.allocator.free(path);
    var read: Read = .{ .config = .{ .output_bytes = 256 * 1024 } };
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var implicit = try runTestRead(std.testing.allocator, &read, args);
    defer implicit.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(
        u8,
        implicit.output,
        "[truncated at 2000 lines; file has more: pass offset/limit to read more]",
    ));

    const bounded_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"limit\":2000}}",
        .{path},
    );
    defer std.testing.allocator.free(bounded_args);
    var bounded = try runTestRead(std.testing.allocator, &read, bounded_args);
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, bounded.output, "[truncated") == null);
    try std.testing.expect(std.mem.endsWith(u8, bounded.output, "  2000→x\n"));
}

test "read does not report a false marker at exactly 2000 lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..2000) |_| try source.appendSlice(std.testing.allocator, "x\n");
    try writeTestFile(&tmp, "lines", source.items);
    const path = try testPath(std.testing.allocator, &tmp, "lines");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{ .config = .{ .output_bytes = 256 * 1024 } };
    var result = try runTestRead(std.testing.allocator, &read, args);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.output, "[truncated") == null);
    try std.testing.expect(std.mem.endsWith(u8, result.output, "  2000→x\n"));
}

test "read only checks NUL in the first 8 KiB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: [stream_chunk_bytes + 2]u8 = undefined;
    var index: usize = 0;
    for (0..1998) |_| {
        source[index] = 'a';
        source[index + 1] = '\n';
        index += 2;
    }
    @memset(source[index .. stream_chunk_bytes - 1], 'a');
    source[stream_chunk_bytes - 1] = '\n';
    source[stream_chunk_bytes] = 0;
    source[stream_chunk_bytes + 1] = '\n';
    try writeTestFile(&tmp, "late-nul", &source);
    const path = try testPath(std.testing.allocator, &tmp, "late-nul");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"offset\":1}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var read: Read = .{ .config = .{ .output_bytes = 32 * 1024 } };
    var result = try runTestRead(std.testing.allocator, &read, args);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.output, "appears to be binary") == null);
    try std.testing.expect(std.mem.find(u8, result.output, "\xef\xbf\xbd") != null);
}

test "read expands configured home without ambient environment reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "home-file", "home\n");
    const home = try testPath(std.testing.allocator, &tmp, "");
    defer std.testing.allocator.free(home);
    var read: Read = .{ .config = .{ .home = home } };
    var result = try runTestRead(
        std.testing.allocator,
        &read,
        "{\"path\":\"~/home-file\"}",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("     1→home\n", result.output);
}

fn exerciseReadAllocations(
    allocator: std.mem.Allocator,
    read: *Read,
    args_json: []const u8,
) !void {
    var result = try runTestRead(allocator, read, args_json);
    result.deinit(allocator);
}

test "read frees every partial successful-path allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "alloc", "valid\ninvalid \xff\n");
    const path = try testPath(std.testing.allocator, &tmp, "alloc");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseReadAllocations,
        .{ &read, args },
    );
}

fn exerciseReadPreprocessAllocations(
    allocator: std.mem.Allocator,
    read: *Read,
    args_json: []const u8,
) !void {
    const rewritten = try read.tool().preprocess(
        allocator,
        std.testing.io,
        args_json,
    );
    if (rewritten) |owned| allocator.free(owned);
}

test "read preprocess frees every partial allocation" {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}/src/tool/Read.zig\",\"offset\":3}}",
        .{cwd_buffer[0..cwd_length]},
    );
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseReadPreprocessAllocations,
        .{ &read, args },
    );
}

test "path relativization matches hax redundant separator behavior" {
    try std.testing.expectEqualStrings("src/a", Path.descendantPath("/work//src/a", "/work").?);
    try std.testing.expectEqualStrings("src//a", Path.descendantPath("/work/src//a", "/work").?);
    try std.testing.expectEqualStrings("work/src", Path.descendantPath("//work/src", "/").?);
    try std.testing.expect(Path.descendantPath("/work/src/../a", "/work") == null);
    try std.testing.expect(Path.descendantPath("/work", "/work") == null);
}

const tiny_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x36, 0x88, 0x49,
    0xd6, 0x00, 0x00, 0x00, 0x15, 0x49, 0x44, 0x41,
    0x54, 0x78, 0xda, 0x63, 0x60, 0x80, 0x00, 0x8d,
    0x80, 0x0a, 0x20, 0x62, 0x08, 0x58, 0xf0, 0x01,
    0x88, 0x00, 0x1f, 0x05, 0x05, 0xa1, 0xfc, 0xf8,
    0x4b, 0x42, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

fn runTestReadContext(
    allocator: std.mem.Allocator,
    read: *Read,
    args_json: ?[]const u8,
    context: ToolContract.RunContext,
) !ToolContract.Result {
    return read.tool().run(allocator, std.testing.io, args_json, context);
}

test "read attaches a complete image with exact owned base64" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "image", &tiny_png);
    const path = try testPath(std.testing.allocator, &tmp, "image");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\",\"offset\":99,\"limit\":1}}",
        .{path},
    );
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    var result = try runTestReadContext(
        std.testing.allocator,
        &read,
        args,
        .{ .image_input = .supported },
    );
    defer result.deinit(std.testing.allocator);
    const expected_output = try std.fmt.allocPrint(
        std.testing.allocator,
        "Read image {s} (image/png, 2x3, 78 bytes).",
        .{path},
    );
    defer std.testing.allocator.free(expected_output);
    try std.testing.expectEqualStrings(expected_output, result.output);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("image/png", result.images[0].mime);
    try std.testing.expectEqual(@as(?u32, 2), result.images[0].width);
    try std.testing.expectEqual(@as(?u32, 3), result.images[0].height);
    try std.testing.expectEqualStrings(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAFUlEQVR42mNggACNgAog" ++
            "YghY8AGIAB8FBaH8+EtCAAAAAElFTkSuQmCC",
        result.images[0].data_base64,
    );
    const decoded_length = try std.base64.standard.Decoder.calcSizeForSlice(
        result.images[0].data_base64,
    );
    const decoded = try std.testing.allocator.alloc(u8, decoded_length);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, result.images[0].data_base64);
    try std.testing.expectEqualSlices(u8, &tiny_png, decoded);
}

test "read attaches for unknown capability and refuses known unsupported models" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "image", &tiny_png);
    const path = try testPath(std.testing.allocator, &tmp, "image");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    var unknown = try runTestReadContext(
        std.testing.allocator,
        &read,
        args,
        .{ .image_input = .unknown },
    );
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), unknown.images.len);

    var unsupported = try runTestReadContext(
        std.testing.allocator,
        &read,
        args,
        .{ .image_input = .unsupported },
    );
    defer unsupported.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unsupported.images.len);
    try std.testing.expect(std.mem.find(
        u8,
        unsupported.output,
        "current model does not accept image input",
    ) != null);
}

test "read rejects recognized malformed and oversized images without attachments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "bad", tiny_png[0..24]);
    const path = try testPath(std.testing.allocator, &tmp, "bad");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    var malformed = try runTestReadContext(
        std.testing.allocator,
        &read,
        args,
        .{ .image_input = .supported },
    );
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), malformed.images.len);
    try std.testing.expect(std.mem.find(u8, malformed.output, "truncated or malformed") != null);

    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var oversized_reader_buffer: [stream_chunk_bytes]u8 = undefined;
    var oversized_reader = file.reader(std.testing.io, &oversized_reader_buffer);
    var oversized = try readImage(
        std.testing.allocator,
        std.testing.io,
        &oversized_reader,
        "image.png",
        image_max_bytes + 1,
        null,
        .supported,
    );
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), oversized.images.len);
    try std.testing.expectEqualStrings(
        "image.png is 3932161 bytes; images over 3932160 bytes exceed provider limits: " ++
            "downscale it first (no ImageMagick found on PATH; ask the user how they'd " ++
            "like to resize it).",
        oversized.output,
    );
}

fn completePng(width: u32, height: u32) [57]u8 {
    var png = [_]u8{0} ** 57;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    png[11] = 13;
    @memcpy(png[12..16], "IHDR");
    png[16] = @truncate(width >> 24);
    png[17] = @truncate(width >> 16);
    png[18] = @truncate(width >> 8);
    png[19] = @truncate(width);
    png[20] = @truncate(height >> 24);
    png[21] = @truncate(height >> 16);
    png[22] = @truncate(height >> 8);
    png[23] = @truncate(height);
    @memcpy(png[37..41], "IDAT");
    @memcpy(png[49..53], "IEND");
    return png;
}

test "read enforces image side limit after complete-container validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const too_wide = completePng(8001, 1);
    try writeTestFile(&tmp, "wide", &too_wide);
    const path = try testPath(std.testing.allocator, &tmp, "wide");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    var result = try runTestReadContext(
        std.testing.allocator,
        &read,
        args,
        .{ .image_input = .supported },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
    try std.testing.expect(std.mem.find(u8, result.output, "is 8001x1") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "over 8000px per side") != null);
}

fn exerciseImageReadAllocations(
    allocator: std.mem.Allocator,
    read: *Read,
    args_json: []const u8,
) !void {
    var result = try runTestReadContext(
        allocator,
        read,
        args_json,
        .{ .image_input = .supported },
    );
    result.deinit(allocator);
}

test "read image attachment frees every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "image", &tiny_png);
    const path = try testPath(std.testing.allocator, &tmp, "image");
    defer std.testing.allocator.free(path);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    var read: Read = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseImageReadAllocations,
        .{ &read, args },
    );
}

test "image resize hints use explicit PATH and shell-quote untrusted paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "magick", "#!/bin/sh\n");
    const executable = try tmp.dir.openFile(std.testing.io, "magick", .{ .mode = .read_write });
    try executable.setPermissions(std.testing.io, .executable_file);
    executable.close(std.testing.io);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const path_env = try std.fs.path.join(
        std.testing.allocator,
        &.{ cwd_buffer[0..cwd_length], ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer std.testing.allocator.free(path_env);
    const hint = try formatDownscaleHint(
        std.testing.allocator,
        std.testing.io,
        "a'b.png",
        path_env,
    );
    defer std.testing.allocator.free(hint);
    try std.testing.expectEqualStrings(
        "downscale it first, e.g.: magick 'a'\\''b.png' -resize '1568x1568>' " ++
            "/tmp/downscaled.png: then read the copy",
        hint,
    );
    const leading_hyphen = try formatDownscaleHint(
        std.testing.allocator,
        std.testing.io,
        "-input.png",
        path_env,
    );
    defer std.testing.allocator.free(leading_hyphen);
    try std.testing.expect(std.mem.find(u8, leading_hyphen, "magick ./\'-input.png\'") != null);
}

test "read image accepts the exact raw cap and refuses cap plus one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.testing.allocator.alloc(u8, image_max_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    bytes[11] = 13;
    @memcpy(bytes[12..16], "IHDR");
    bytes[19] = 1;
    bytes[23] = 1;
    const idat_offset: usize = 33;
    const payload_length: u32 = image_max_bytes - 57;
    bytes[idat_offset] = @truncate(payload_length >> 24);
    bytes[idat_offset + 1] = @truncate(payload_length >> 16);
    bytes[idat_offset + 2] = @truncate(payload_length >> 8);
    bytes[idat_offset + 3] = @truncate(payload_length);
    @memcpy(bytes[idat_offset + 4 .. idat_offset + 8], "IDAT");
    const iend_offset = image_max_bytes - 12;
    @memcpy(bytes[iend_offset + 4 .. iend_offset + 8], "IEND");
    try writeTestFile(&tmp, "boundary", bytes[0..image_max_bytes]);
    const boundary_path = try testPath(std.testing.allocator, &tmp, "boundary");
    defer std.testing.allocator.free(boundary_path);
    const boundary_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\"}}",
        .{boundary_path},
    );
    defer std.testing.allocator.free(boundary_args);
    var read: Read = .{};
    var accepted = try runTestReadContext(
        std.testing.allocator,
        &read,
        boundary_args,
        .{ .image_input = .supported },
    );
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), accepted.images.len);
    try std.testing.expectEqual(
        std.base64.standard.Encoder.calcSize(image_max_bytes),
        accepted.images[0].data_base64.len,
    );

    bytes[image_max_bytes] = 'x';
    try writeTestFile(&tmp, "over", bytes);
    const over_path = try testPath(std.testing.allocator, &tmp, "over");
    defer std.testing.allocator.free(over_path);
    const stale_file = try std.Io.Dir.cwd().openFile(std.testing.io, over_path, .{});
    defer stale_file.close(std.testing.io);
    var stale_reader_buffer: [stream_chunk_bytes]u8 = undefined;
    var stale_reader = stale_file.reader(std.testing.io, &stale_reader_buffer);
    var changed = try readImage(
        std.testing.allocator,
        std.testing.io,
        &stale_reader,
        over_path,
        image_max_bytes,
        null,
        .supported,
    );
    defer changed.deinit(std.testing.allocator);
    const changed_expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "error reading {s}: file changed while reading",
        .{over_path},
    );
    defer std.testing.allocator.free(changed_expected);
    try std.testing.expectEqualStrings(changed_expected, changed.output);
    try std.testing.expectEqual(@as(usize, 0), changed.images.len);
    const over_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"{s}\"}}",
        .{over_path},
    );
    defer std.testing.allocator.free(over_args);
    var refused = try runTestReadContext(
        std.testing.allocator,
        &read,
        over_args,
        .{ .image_input = .supported },
    );
    defer refused.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), refused.images.len);
    try std.testing.expect(std.mem.find(u8, refused.output, "is 3932161 bytes") != null);
}

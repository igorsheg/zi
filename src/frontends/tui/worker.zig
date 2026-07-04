const std = @import("std");

const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const clipboard_image = @import("clipboard_image.zig");
const clipboard_text = @import("clipboard_text.zig");

const client_protocol = coding_agent.client_protocol;

pub const clipboard_image_attachment_count_max = client_protocol.submit_image_count_max;

pub const Worker = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    task_runtime: ?*runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
    tmp_dir: []const u8,
    wake_fds: [2]std.c.fd_t,
    task: ?Task = null,

    const Task = struct {
        kind: Kind,
        thread: std.Thread,
        slot: *ResultSlot,
    };

    pub const SpawnError = error{ Busy, ThreadQuotaExceeded, SystemResources, OutOfMemory };

    pub fn init(
        allocator: std.mem.Allocator,
        task_runtime: ?*runtime.Runtime,
        environ: ?*const std.process.Environ.Map,
        tmp_dir: []const u8,
    ) !Worker {
        const wake_fds = try createPipe();
        errdefer closePipe(wake_fds);
        return .{
            .allocator = allocator,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .task_runtime = task_runtime,
            .environ = environ,
            .tmp_dir = tmp_dir,
            .wake_fds = wake_fds,
        };
    }

    pub fn deinit(self: *Worker) void {
        self.cancelAndDrain();
        closePipe(self.wake_fds);
        self.threaded.deinit();
        self.* = undefined;
    }

    pub fn wakeFd(self: *const Worker) std.c.fd_t {
        return self.wake_fds[0];
    }

    pub fn drainWakeFd(self: *Worker) void {
        drainPipe(self.wake_fds[0]);
    }

    /// Takes ownership of `input` only on success. Single-slot policy: reject when busy.
    pub fn spawn(self: *Worker, kind: Kind, input: Input) SpawnError!void {
        if (self.task != null) return error.Busy;
        const slot = try self.allocator.create(ResultSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{ .wake_fd = self.wake_fds[1] };
        const thread = std.Thread.spawn(.{}, threadMain, .{ThreadArgs{
            .slot = slot,
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .task_runtime = self.task_runtime,
            .environ = self.environ,
            .tmp_dir = self.tmp_dir,
            .kind = kind,
            .input = input,
        }}) catch |err| switch (err) {
            error.ThreadQuotaExceeded => return error.ThreadQuotaExceeded,
            error.SystemResources => return error.SystemResources,
            else => return error.SystemResources,
        };
        self.task = .{ .kind = kind, .thread = thread, .slot = slot };
    }

    pub fn drain(self: *Worker) ?ResultEnvelope {
        const task = self.task orelse return null;
        if (!task.slot.isReady()) return null;
        self.task = null;
        task.thread.join();
        defer self.allocator.destroy(task.slot);
        return task.slot.result;
    }

    fn cancelAndDrain(self: *Worker) void {
        const task = self.task orelse return;
        self.task = null;
        task.thread.join();
        if (task.slot.isReady()) task.slot.result.deinit(self.allocator);
        self.allocator.destroy(task.slot);
    }
};

pub const Kind = enum { clipboard_copy, clipboard_image_paste, prompt_attachments };

pub const Input = union(enum) {
    clipboard_copy: []u8,
    clipboard_image_paste,
    prompt_attachments: []u8,

    pub fn deinit(self: Input, allocator: std.mem.Allocator) void {
        switch (self) {
            .clipboard_copy, .prompt_attachments => |text| allocator.free(text),
            .clipboard_image_paste => {},
        }
    }
};

pub const ResultEnvelope = union(enum) {
    ok: Result,
    err: anyerror,

    pub fn deinit(self: *ResultEnvelope, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*result| result.deinit(allocator),
            .err => {},
        }
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    clipboard_copy: ClipboardCopyResult,
    clipboard_image_paste: ClipboardImagePasteResult,
    prompt_attachments: PromptAttachmentsResult,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .clipboard_copy => |*result| result.deinit(allocator),
            .clipboard_image_paste => |*result| result.deinit(allocator),
            .prompt_attachments => |*result| result.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ClipboardCopyResult = struct {
    text: []u8,
    native_copied: bool,

    fn deinit(self: *ClipboardCopyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const ClipboardImagePasteResult = struct {
    path: []u8,

    fn deinit(self: *ClipboardImagePasteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const PromptAttachmentsResult = struct {
    prompt: []u8,
    attachments: PromptImageAttachments,

    fn deinit(self: *PromptAttachmentsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        PromptImageAttachments.deinit(allocator, &self.attachments);
        self.* = undefined;
    }
};

pub const PromptImageAttachments = struct {
    list: std.ArrayList(ai.ImageContent) = .empty,

    pub fn images(self: *const PromptImageAttachments) []const ai.ImageContent {
        return self.list.items;
    }

    pub fn deinit(allocator: std.mem.Allocator, self: *PromptImageAttachments) void {
        for (self.list.items) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        self.list.deinit(allocator);
        self.* = undefined;
    }
};

const ResultSlot = struct {
    ready: std.atomic.Value(bool) = .init(false),
    result: ResultEnvelope = undefined,
    wake_fd: std.c.fd_t,

    fn complete(self: *ResultSlot, result: ResultEnvelope) void {
        self.result = result;
        self.ready.store(true, .release);
        wakeFd(self.wake_fd);
    }

    fn isReady(self: *const ResultSlot) bool {
        return self.ready.load(.acquire);
    }
};

const ThreadArgs = struct {
    slot: *ResultSlot,
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: ?*runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
    tmp_dir: []const u8,
    kind: Kind,
    input: Input,
};

fn threadMain(args: ThreadArgs) void {
    args.slot.complete(build(args) catch |err| .{ .err = err });
}

fn build(args: ThreadArgs) anyerror!ResultEnvelope {
    return .{ .ok = switch (args.kind) {
        .clipboard_copy => try buildClipboardCopy(args.allocator, args.io, args.environ, args.input.clipboard_copy),
        .clipboard_image_paste => try buildClipboardImagePaste(
            args.allocator,
            args.io,
            args.task_runtime orelse return error.ToolUnavailable,
            args.environ,
            args.tmp_dir,
        ),
        .prompt_attachments => try buildPromptAttachments(args.allocator, args.io, args.input.prompt_attachments),
    } };
}

fn buildClipboardCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    text: []u8,
) !Result {
    _ = allocator;
    const native_copied = if (clipboard_text.copyNative(io, environ, text)) |_| true else |_| false;
    return .{ .clipboard_copy = .{ .text = text, .native_copied = native_copied } };
}

fn buildClipboardImagePaste(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
    tmp_dir: []const u8,
) !Result {
    var image = try clipboard_image.read(allocator, io, task_runtime, environ);
    defer image.deinit(allocator);
    const path = try writeClipboardImageTempFile(allocator, io, tmp_dir, &image);
    return .{ .clipboard_image_paste = .{ .path = path } };
}

fn buildPromptAttachments(allocator: std.mem.Allocator, io: std.Io, prompt: []u8) !Result {
    errdefer allocator.free(prompt);
    var attachments = try promptImageAttachmentsFromPrompt(allocator, io, prompt);
    errdefer PromptImageAttachments.deinit(allocator, &attachments);
    return .{ .prompt_attachments = .{ .prompt = prompt, .attachments = attachments } };
}

fn writeClipboardImageTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_dir: []const u8,
    image: *const clipboard_image.ClipboardImage,
) ![]u8 {
    const ext = clipboard_image.extensionForMimeType(image.mime_type) orelse return error.UnsupportedFormat;
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var name_buffer: [96]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buffer,
            "zi-clipboard-{d}-{d}.{s}",
            .{ stamp, attempts, ext },
        ) catch unreachable;
        const path = try std.fs.path.join(allocator, &.{ tmp_dir, name });
        errdefer allocator.free(path);
        var file = std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        try writer.interface.writeAll(image.bytes);
        try writer.flush();
        return path;
    }
    return error.PathAlreadyExists;
}

fn promptImageAttachmentsFromPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
) !PromptImageAttachments {
    var attachments: PromptImageAttachments = .{};
    errdefer PromptImageAttachments.deinit(allocator, &attachments);
    var index: usize = 0;
    while (index < prompt.len and attachments.list.items.len < clipboard_image_attachment_count_max) {
        const at = std.mem.indexOfScalarPos(u8, prompt, index, '@') orelse break;
        index = at + 1;
        const path_start = index;
        while (index < prompt.len and isPromptPathByte(prompt[index])) : (index += 1) {}
        if (index == path_start) continue;
        const path = prompt[path_start..index];
        if (!isZiClipboardImagePath(path)) continue;
        try attachments.list.append(allocator, try readPromptImageAttachment(allocator, io, path));
    }
    return attachments;
}

fn readPromptImageAttachment(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !ai.ImageContent {
    const mime_type = mimeTypeForImagePath(path) orelse return error.UnsupportedFormat;
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const file_len = try file.length(io);
    if (file_len == 0) return error.NoImage;
    if (file_len > client_protocol.submit_image_data_bytes_max) return error.ImageTooLarge;
    const raw = try allocator.alloc(u8, @intCast(file_len));
    defer allocator.free(raw);
    const read_len = try file.readPositionalAll(io, raw, 0);
    if (read_len != raw.len) return error.ShortRead;

    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    const mime = try allocator.dupe(u8, mime_type);
    errdefer allocator.free(mime);
    return .{ .data = encoded, .mime_type = mime };
}

fn isPromptPathByte(byte: u8) bool {
    return switch (byte) {
        0...32, '"', '\'', '<', '>' => false,
        else => true,
    };
}

fn isZiClipboardImagePath(path: []const u8) bool {
    const leaf = std.fs.path.basename(path);
    return std.mem.startsWith(u8, leaf, "zi-clipboard-") and mimeTypeForImagePath(path) != null;
}

fn mimeTypeForImagePath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    return null;
}

fn createPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    return fds;
}

fn closePipe(fds: [2]std.c.fd_t) void {
    if (fds[0] >= 0) _ = std.c.close(fds[0]);
    if (fds[1] >= 0) _ = std.c.close(fds[1]);
}

fn wakeFd(fd: std.c.fd_t) void {
    const byte: [1]u8 = .{1};
    _ = std.c.write(fd, &byte, byte.len);
}

fn drainPipe(fd: std.c.fd_t) void {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        _ = std.posix.poll(&fds, 0) catch return;
        if ((fds[0].revents & std.posix.POLL.IN) == 0) return;
        var buf: [64]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return;
        if (n == 0 or n < buf.len) return;
        fds[0].revents = 0;
    }
}

test "worker rejects busy single slot" {
    var worker = try Worker.init(std.testing.allocator, null, null, "/tmp");
    defer worker.deinit();

    const first = try std.testing.allocator.dupe(u8, "one");
    try worker.spawn(.clipboard_copy, .{ .clipboard_copy = first });
    const second = try std.testing.allocator.dupe(u8, "two");
    defer std.testing.allocator.free(second);
    try std.testing.expectError(error.Busy, worker.spawn(.clipboard_copy, .{ .clipboard_copy = second }));
}

test "worker result round trip and wake fd readability" {
    var worker = try Worker.init(std.testing.allocator, null, null, "/tmp");
    defer worker.deinit();

    const prompt = try std.testing.allocator.dupe(u8, "hello");
    try worker.spawn(.prompt_attachments, .{ .prompt_attachments = prompt });
    var poll_fds = [_]std.posix.pollfd{.{ .fd = worker.wakeFd(), .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect((try std.posix.poll(&poll_fds, 1000)) > 0);
    worker.drainWakeFd();

    var envelope = worker.drain().?;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expect(envelope == .ok);
    try std.testing.expect(envelope.ok == .prompt_attachments);
    try std.testing.expectEqualStrings("hello", envelope.ok.prompt_attachments.prompt);
    try std.testing.expectEqual(@as(usize, 0), envelope.ok.prompt_attachments.attachments.images().len);
}

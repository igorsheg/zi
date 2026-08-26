const std = @import("std");
const CookedLineInput = @This();

/// Keep this provider-neutral input bound equal to cli.Args.max_prompt_bytes.
/// terminal does not import cli so the dependency remains inward-facing.
pub const max_prompt_bytes: usize = 1024 * 1024;

allocator: std.mem.Allocator,
reader: *std.Io.Reader,
max_bytes: usize,

/// Owns the allocation that backs `bytes`. Call `deinit` exactly once.
pub const OwnedLine = struct {
    bytes: []u8,
    capacity: usize,

    pub fn deinit(line: *OwnedLine, allocator: std.mem.Allocator) void {
        var storage: std.ArrayList(u8) = .{
            .items = line.bytes,
            .capacity = line.capacity,
        };
        storage.deinit(allocator);
        line.* = undefined;
    }
};

/// A submitted line owns its bytes. EOF owns no storage.
pub const Result = union(enum) {
    submit: OwnedLine,
    eof,

    pub fn deinit(result: *Result, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .submit => |*line| line.deinit(allocator),
            .eof => {},
        }
        result.* = undefined;
    }
};

pub const ReadError = error{
    OutOfMemory,
    ReadFailed,
    LineTooLong,
};

pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) CookedLineInput {
    return initBounded(allocator, reader, max_prompt_bytes);
}

/// Reads one cooked line. LF terminates a line and a preceding CR is removed.
/// A final unterminated line is submitted before a later call reports EOF.
/// On `error.LineTooLong`, the complete offending line has been consumed.
pub fn read(input: *CookedLineInput) ReadError!Result {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(input.allocator);

    var saw_byte = false;
    var pending_cr = false;
    while (true) {
        const byte = input.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (!saw_byte) return .eof;
                if (pending_cr) try input.appendByte(&bytes, '\r');
                return submitted(bytes);
            },
            error.ReadFailed => return error.ReadFailed,
        };
        saw_byte = true;

        if (byte == '\n') return submitted(bytes);
        if (pending_cr) {
            input.appendByte(&bytes, '\r') catch |err| return input.recover(err);
            pending_cr = false;
        }
        if (byte == '\r') {
            pending_cr = true;
        } else {
            input.appendByte(&bytes, byte) catch |err| return input.recover(err);
        }
    }
}

fn initBounded(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
) CookedLineInput {
    return .{
        .allocator = allocator,
        .reader = reader,
        .max_bytes = max_bytes,
    };
}

fn appendByte(input: *const CookedLineInput, bytes: *std.ArrayList(u8), byte: u8) !void {
    if (bytes.items.len == input.max_bytes) return error.LineTooLong;
    if (bytes.items.len == bytes.capacity) {
        const doubled = std.math.mul(usize, bytes.capacity, 2) catch input.max_bytes;
        const grown = @max(@as(usize, 8), doubled);
        const new_capacity = @min(input.max_bytes, grown);
        try bytes.ensureTotalCapacityPrecise(input.allocator, new_capacity);
    }
    bytes.appendAssumeCapacity(byte);
}

fn recover(input: *CookedLineInput, original_error: ReadError) ReadError {
    input.discardThroughNewline() catch return error.ReadFailed;
    return original_error;
}

fn discardThroughNewline(input: *CookedLineInput) error{ReadFailed}!void {
    while (true) {
        const byte = input.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        if (byte == '\n') return;
    }
}

fn submitted(bytes: std.ArrayList(u8)) Result {
    return .{ .submit = .{
        .bytes = bytes.items,
        .capacity = bytes.capacity,
    } };
}

fn expectSubmit(result: *Result, expected: []const u8) !void {
    switch (result.*) {
        .submit => |line| try std.testing.expectEqualStrings(expected, line.bytes),
        .eof => return error.TestUnexpectedResult,
    }
}

fn expectEof(result: Result) !void {
    switch (result) {
        .eof => {},
        .submit => return error.TestUnexpectedResult,
    }
}

test "reads repeated LF and CRLF lines including empty lines" {
    var reader = std.Io.Reader.fixed("one\r\n\ntwo\n");
    var input = init(std.testing.allocator, &reader);

    var one = try input.read();
    defer one.deinit(std.testing.allocator);
    try expectSubmit(&one, "one");

    var empty = try input.read();
    defer empty.deinit(std.testing.allocator);
    try expectSubmit(&empty, "");

    var two = try input.read();
    defer two.deinit(std.testing.allocator);
    try expectSubmit(&two, "two");

    try expectEof(try input.read());
}

test "submits a final unterminated line before EOF" {
    var reader = std.Io.Reader.fixed("final");
    var input = init(std.testing.allocator, &reader);

    var final = try input.read();
    defer final.deinit(std.testing.allocator);
    try expectSubmit(&final, "final");
    try expectEof(try input.read());
}

test "empty input is EOF while one newline submits an empty line" {
    var empty_reader = std.Io.Reader.fixed("");
    var empty_input = init(std.testing.allocator, &empty_reader);
    try expectEof(try empty_input.read());

    var newline_reader = std.Io.Reader.fixed("\n");
    var newline_input = init(std.testing.allocator, &newline_reader);
    var line = try newline_input.read();
    defer line.deinit(std.testing.allocator);
    try expectSubmit(&line, "");
    try expectEof(try newline_input.read());
}

test "accepts a maximum line with CRLF" {
    var reader = std.Io.Reader.fixed("1234\r\n");
    var input = initBounded(std.testing.allocator, &reader, 4);
    var line = try input.read();
    defer line.deinit(std.testing.allocator);
    try expectSubmit(&line, "1234");
}

test "overlong lines are drained so the next line is recoverable" {
    var reader = std.Io.Reader.fixed("12345\r\nok\n");
    var input = initBounded(std.testing.allocator, &reader, 4);

    try std.testing.expectError(error.LineTooLong, input.read());
    var recovered = try input.read();
    defer recovered.deinit(std.testing.allocator);
    try expectSubmit(&recovered, "ok");
    try expectEof(try input.read());
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var reader = std.Io.Reader.fixed("allocated line\nnext\n");
    var input = initBounded(allocator, &reader, 64);
    var first = try input.read();
    defer first.deinit(allocator);
    try expectSubmit(&first, "allocated line");
}

test "allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureCase,
        .{},
    );
}

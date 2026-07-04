const std = @import("std");
const runtime = @import("../../runtime/root.zig");

pub const Phase = enum {
    wait,
    input_drain,
    sample,
    diff_apply,
    tick,
    draw,
    flush,
    watchdog,
};

const sample_count_max: usize = 64;

const Sample = struct {
    phase: Phase,
    duration_ns: u64,
};

pub const Stats = struct {
    enabled: bool = false,
    samples: [sample_count_max]Sample = undefined,
    sample_len: usize = 0,
    max_ns: [@typeInfo(Phase).@"enum".fields.len]u64 = @splat(0),

    pub fn init(process: runtime.Process) Stats {
        return .{ .enabled = process.env("ZI_TUI_TRACE") != null };
    }

    pub fn record(self: *Stats, phase: Phase, duration_ns: u64) void {
        if (!self.enabled) return;
        const phase_index = @intFromEnum(phase);
        self.max_ns[phase_index] = @max(self.max_ns[phase_index], duration_ns);
        if (self.sample_len < self.samples.len) {
            self.samples[self.sample_len] = .{ .phase = phase, .duration_ns = duration_ns };
            self.sample_len += 1;
        }
    }

    pub fn writeReport(self: *const Stats, writer: *std.Io.Writer) void {
        if (!self.enabled) return;
        writer.writeAll("\nzi tui trace max phase durations:\n") catch return;
        inline for (@typeInfo(Phase).@"enum".fields, 0..) |field, index| {
            const ns = self.max_ns[index];
            if (ns != 0) {
                writer.print("  {s}: {d}.{d:0>3}ms\n", .{
                    field.name,
                    ns / std.time.ns_per_ms,
                    (ns % std.time.ns_per_ms) / 1000,
                }) catch return;
            }
        }
        if (self.sample_len == 0) return;
        writer.writeAll("zi tui trace samples:\n") catch return;
        for (self.samples[0..self.sample_len]) |sample| {
            writer.print("  {s}: {d}.{d:0>3}ms\n", .{
                @tagName(sample.phase),
                sample.duration_ns / std.time.ns_per_ms,
                (sample.duration_ns % std.time.ns_per_ms) / 1000,
            }) catch return;
        }
    }
};

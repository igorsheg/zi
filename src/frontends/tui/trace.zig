const std = @import("std");

const runtime = @import("../../runtime/root.zig");

pub const Phase = enum {
    poll_input,
    drain_input,
    session_step,
    client_event_drain,
    pending_ui_work,
    tick_time,
    render_draw_foreground,
    render_draw_background,
    render_flush_foreground,
    render_flush_background,
    render_clear,
    render_layout,
    render_transcript,
    render_transcript_total,
    render_transcript_item_rows,
    render_transcript_tail,
    render_transcript_build,
    render_transcript_build_message,
    render_transcript_build_thinking,
    render_transcript_build_tool,
    render_transcript_build_status,
    render_transcript_build_custom,
    render_transcript_emit,
    render_greeter,
    render_status,
    render_notify,
    render_composer,
    render_picker,
    wait_input,
    wait_session,
    wait_frame,
    pending_message,
    pending_thinking,
    assistant_queue_wait,
    assistant_frontend_accept_to_queue,
    assistant_apply_to_flush,
    pending_tool_output,
    pending_tool_structure,
    pending_status,
};

const slow_threshold_ns: u64 = 16 * std.time.ns_per_ms;
const sample_count_max: usize = 64;

const Sample = struct {
    phase: Phase,
    duration_ns: u64,
};

pub const Stats = struct {
    enabled: bool = false,
    samples: [sample_count_max]Sample = undefined,
    sample_start: usize = 0,
    sample_len: usize = 0,
    max_ns: [@typeInfo(Phase).@"enum".fields.len]u64 = @splat(0),
    foreground_with_pending_background_count: usize = 0,
    rendered_foreground_count: usize = 0,
    rendered_scroll_count: usize = 0,
    rendered_background_count: usize = 0,
    background_render_pending_work_count: usize = 0,
    background_render_animation_count: usize = 0,

    pub fn init(process: runtime.Process) Stats {
        return .{ .enabled = process.env("ZI_TUI_TRACE") != null };
    }

    pub fn record(self: *Stats, phase: Phase, duration_ns: u64) void {
        if (!self.enabled) return;
        const index = @intFromEnum(phase);
        self.max_ns[index] = @max(self.max_ns[index], duration_ns);
        if (duration_ns < slow_threshold_ns or isWaitPhase(phase)) return;
        const sample: Sample = .{ .phase = phase, .duration_ns = duration_ns };
        if (self.sample_len < self.samples.len) {
            self.samples[(self.sample_start + self.sample_len) % self.samples.len] = sample;
            self.sample_len += 1;
        } else {
            self.samples[self.sample_start] = sample;
            self.sample_start = (self.sample_start + 1) % self.samples.len;
        }
    }

    pub fn noteRender(self: *Stats, priority: anytype) void {
        if (!self.enabled) return;
        switch (priority) {
            .foreground => self.rendered_foreground_count += 1,
            .scroll => self.rendered_scroll_count += 1,
            .background => self.rendered_background_count += 1,
            .none => {},
        }
    }

    pub fn noteForegroundWithPendingBackground(self: *Stats) void {
        if (!self.enabled) return;
        self.foreground_with_pending_background_count += 1;
    }

    pub fn noteBackgroundReason(self: *Stats, pending_work: bool) void {
        if (!self.enabled) return;
        if (pending_work) {
            self.background_render_pending_work_count += 1;
        } else {
            self.background_render_animation_count += 1;
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
        writer.print("zi tui trace rendered frames: foreground={d} scroll={d} background={d}\n", .{
            self.rendered_foreground_count,
            self.rendered_scroll_count,
            self.rendered_background_count,
        }) catch return;
        writer.print("zi tui trace foreground renders with pending background work: {d}\n", .{
            self.foreground_with_pending_background_count,
        }) catch return;
        writer.print("zi tui trace background reasons: pending_work={d} animation={d}\n", .{
            self.background_render_pending_work_count,
            self.background_render_animation_count,
        }) catch return;
        if (self.sample_len == 0) return;
        writer.writeAll("zi tui trace slow samples:\n") catch return;
        for (0..self.sample_len) |offset| {
            const sample = self.samples[(self.sample_start + offset) % self.samples.len];
            writer.print("  {s}: {d}.{d:0>3}ms\n", .{
                @tagName(sample.phase),
                sample.duration_ns / std.time.ns_per_ms,
                (sample.duration_ns % std.time.ns_per_ms) / 1000,
            }) catch return;
        }
    }

    fn isWaitPhase(phase: Phase) bool {
        return switch (phase) {
            .wait_input, .wait_session, .wait_frame => true,
            else => false,
        };
    }
};

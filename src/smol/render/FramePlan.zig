const std = @import("std");

/// Terminal geometry for one normal-buffer frame.
pub const Geometry = struct {
    rows: u16,
    columns: u16,
};

/// Inclusive, one-based terminal rows. Zero endpoints represent an empty band.
pub const Band = struct {
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn empty() Band {
        return .{};
    }

    pub fn isEmpty(self: Band) bool {
        return self.top == 0 and self.bottom == 0;
    }

    pub fn height(self: Band) u16 {
        if (self.isEmpty()) return 0;
        return self.bottom - self.top + 1;
    }

    pub fn contains(self: Band, row: u16) bool {
        return !self.isEmpty() and row >= self.top and row <= self.bottom;
    }
};

/// Authoritative layout facts retained only after a frame publication succeeds.
pub const CommittedLayout = struct {
    geometry: Geometry,
    preserved_band: Band,
    transcript_band: Band,
    footer_band: Band,
    owned_top: u16,
    owned_bottom: u16,
    transcript_rows: u32,
    footer_rows: u16,

    pub fn frameIsFull(self: CommittedLayout) bool {
        return self.owned_bottom != 0 and self.owned_bottom == self.geometry.rows;
    }
};

pub const SolveInput = struct {
    geometry: Geometry,
    /// One-based hardware cursor row where Zi first takes ownership.
    launch_row: u16,
    /// Total measured transcript rows, before viewport clipping.
    transcript_rows: u32,
    footer_rows: u16,
    prior: ?CommittedLayout = null,
};

pub const FramePlan = struct {
    geometry: Geometry,
    preserved_band: Band,
    transcript_band: Band,
    footer_band: Band,
    owned_top: u16,
    owned_bottom: u16,
    /// Rows the terminal must physically scroll before this layout is painted.
    physical_scroll_rows: u32,
    /// Prefix rows released by that physical movement. Scroll beyond this count
    /// advances an already full transcript through the native scrollback buffer.
    released_preserved_rows: u16,
    transcript_rows: u32,
    footer_rows: u16,

    pub fn committed(self: FramePlan) CommittedLayout {
        return .{
            .geometry = self.geometry,
            .preserved_band = self.preserved_band,
            .transcript_band = self.transcript_band,
            .footer_band = self.footer_band,
            .owned_top = self.owned_top,
            .owned_bottom = self.owned_bottom,
            .transcript_rows = self.transcript_rows,
            .footer_rows = self.footer_rows,
        };
    }
};

pub const SolveError = error{
    InvalidGeometry,
    InvalidLaunchRow,
    InvalidPriorLayout,
};

/// Solves compact-until-full normal-buffer ownership. Physical movement always
/// consumes the preserved prefix before it counts as full-frame transcript
/// advancement.
pub fn solve(input: SolveInput) SolveError!FramePlan {
    if (input.geometry.rows == 0 or input.geometry.columns == 0) {
        return error.InvalidGeometry;
    }
    if (input.launch_row == 0 or input.launch_row > input.geometry.rows) {
        return error.InvalidLaunchRow;
    }
    if (input.prior) |prior| try validateCommitted(prior);

    const initial_owned_top = if (input.prior) |prior|
        @min(prior.owned_top, input.geometry.rows)
    else
        input.launch_row;
    const footer_height = @min(input.footer_rows, input.geometry.rows);
    const transcript_capacity = input.geometry.rows - footer_height;
    const transcript_height: u16 = @intCast(@min(
        input.transcript_rows,
        @as(u32, transcript_capacity),
    ));
    const frame_height = transcript_height + footer_height;
    const available_rows = input.geometry.rows - initial_owned_top + 1;
    const geometry_release = frame_height -| available_rows;

    const native_growth: u32 = if (input.prior) |prior|
        if (sameGeometry(prior.geometry, input.geometry) and prior.frameIsFull())
            input.transcript_rows -| prior.transcript_rows
        else
            0
    else
        0;
    const physical_scroll_rows = @max(@as(u32, geometry_release), native_growth);
    const preserved_capacity = initial_owned_top - 1;
    const released_preserved_rows: u16 = @intCast(@min(
        physical_scroll_rows,
        @as(u32, preserved_capacity),
    ));
    const owned_top = initial_owned_top - released_preserved_rows;
    const owned_bottom = if (frame_height == 0)
        owned_top - 1
    else
        owned_top + frame_height - 1;
    std.debug.assert(owned_bottom <= input.geometry.rows);

    const transcript_band = bandFromTopHeight(owned_top, transcript_height);
    const footer_band = if (footer_height == 0)
        Band.empty()
    else
        bandFromTopHeight(owned_top + transcript_height, footer_height);
    return .{
        .geometry = input.geometry,
        .preserved_band = if (owned_top > 1)
            .{ .top = 1, .bottom = owned_top - 1 }
        else
            .empty(),
        .transcript_band = transcript_band,
        .footer_band = footer_band,
        .owned_top = owned_top,
        .owned_bottom = owned_bottom,
        .physical_scroll_rows = physical_scroll_rows,
        .released_preserved_rows = released_preserved_rows,
        .transcript_rows = input.transcript_rows,
        .footer_rows = input.footer_rows,
    };
}

fn sameGeometry(a: Geometry, b: Geometry) bool {
    return a.rows == b.rows and a.columns == b.columns;
}

fn bandFromTopHeight(top: u16, height: u16) Band {
    if (height == 0) return .empty();
    return .{ .top = top, .bottom = top + height - 1 };
}

fn validateCommitted(layout: CommittedLayout) SolveError!void {
    if (layout.geometry.rows == 0 or layout.geometry.columns == 0) {
        return error.InvalidPriorLayout;
    }
    const frame_is_empty = layout.transcript_band.isEmpty() and layout.footer_band.isEmpty();
    if (layout.owned_top == 0 or layout.owned_top > layout.geometry.rows or
        layout.owned_bottom > layout.geometry.rows or
        (frame_is_empty and layout.owned_bottom != layout.owned_top - 1) or
        (!frame_is_empty and layout.owned_bottom < layout.owned_top))
    {
        return error.InvalidPriorLayout;
    }
    const expected_preserved: Band = if (layout.owned_top > 1)
        .{ .top = 1, .bottom = layout.owned_top - 1 }
    else
        .empty();
    if (!std.meta.eql(expected_preserved, layout.preserved_band)) {
        return error.InvalidPriorLayout;
    }
    if (!validOwnedBand(layout.transcript_band, layout) or
        !validOwnedBand(layout.footer_band, layout))
    {
        return error.InvalidPriorLayout;
    }
    if (!layout.transcript_band.isEmpty() and !layout.footer_band.isEmpty() and
        layout.transcript_band.bottom + 1 != layout.footer_band.top)
    {
        return error.InvalidPriorLayout;
    }
    const first_band_top = if (!layout.transcript_band.isEmpty())
        layout.transcript_band.top
    else if (!layout.footer_band.isEmpty())
        layout.footer_band.top
    else
        0;
    const last_band_bottom = if (!layout.footer_band.isEmpty())
        layout.footer_band.bottom
    else if (!layout.transcript_band.isEmpty())
        layout.transcript_band.bottom
    else
        0;
    if ((!frame_is_empty and
        (first_band_top != layout.owned_top or last_band_bottom != layout.owned_bottom)) or
        (frame_is_empty and (first_band_top != 0 or last_band_bottom != 0)))
    {
        return error.InvalidPriorLayout;
    }
}

fn validOwnedBand(band: Band, layout: CommittedLayout) bool {
    if (band.isEmpty()) return true;
    if (band.top == 0 or band.bottom < band.top) return false;
    return band.top >= layout.owned_top and band.bottom <= layout.owned_bottom;
}

fn expectPlanBands(plan: FramePlan, preserved: Band, transcript: Band, footer: Band) !void {
    try std.testing.expectEqual(preserved, plan.preserved_band);
    try std.testing.expectEqual(transcript, plan.transcript_band);
    try std.testing.expectEqual(footer, plan.footer_band);
}

test "first frame stays compact at the launch row" {
    const plan = try solve(.{
        .geometry = .{ .rows = 24, .columns = 80 },
        .launch_row = 6,
        .transcript_rows = 3,
        .footer_rows = 2,
    });

    try std.testing.expectEqual(@as(u16, 6), plan.owned_top);
    try std.testing.expectEqual(@as(u16, 10), plan.owned_bottom);
    try std.testing.expectEqual(@as(u32, 0), plan.physical_scroll_rows);
    try expectPlanBands(
        plan,
        .{ .top = 1, .bottom = 5 },
        .{ .top = 6, .bottom = 8 },
        .{ .top = 9, .bottom = 10 },
    );
}

test "launch near the bottom releases only rows needed by the first frame" {
    const plan = try solve(.{
        .geometry = .{ .rows = 10, .columns = 40 },
        .launch_row = 9,
        .transcript_rows = 2,
        .footer_rows = 2,
    });

    try std.testing.expectEqual(@as(u32, 2), plan.physical_scroll_rows);
    try std.testing.expectEqual(@as(u16, 2), plan.released_preserved_rows);
    try expectPlanBands(
        plan,
        .{ .top = 1, .bottom = 6 },
        .{ .top = 7, .bottom = 8 },
        .{ .top = 9, .bottom = 10 },
    );
}

test "tiny terminals reserve the footer before transcript rows" {
    const one_row = try solve(.{
        .geometry = .{ .rows = 1, .columns = 1 },
        .launch_row = 1,
        .transcript_rows = 12,
        .footer_rows = 3,
    });
    try expectPlanBands(one_row, .empty(), .empty(), .{ .top = 1, .bottom = 1 });
    try std.testing.expectEqual(@as(u16, 1), one_row.owned_bottom);

    const two_rows = try solve(.{
        .geometry = .{ .rows = 2, .columns = 8 },
        .launch_row = 2,
        .transcript_rows = 12,
        .footer_rows = 1,
    });
    try std.testing.expectEqual(@as(u32, 1), two_rows.physical_scroll_rows);
    try expectPlanBands(two_rows, .empty(), .{ .top = 1, .bottom = 1 }, .{ .top = 2, .bottom = 2 });
}

test "empty frame remains compact and can be committed" {
    const empty_plan = try solve(.{
        .geometry = .{ .rows = 4, .columns = 8 },
        .launch_row = 3,
        .transcript_rows = 0,
        .footer_rows = 0,
    });
    try expectPlanBands(empty_plan, .{ .top = 1, .bottom = 2 }, .empty(), .empty());
    try std.testing.expectEqual(@as(u16, 3), empty_plan.owned_top);
    try std.testing.expectEqual(@as(u16, 2), empty_plan.owned_bottom);

    _ = try solve(.{
        .geometry = empty_plan.geometry,
        .launch_row = 3,
        .transcript_rows = 0,
        .footer_rows = 0,
        .prior = empty_plan.committed(),
    });
}

test "footer growth releases preserved rows and shrink keeps the committed top" {
    const initial = try solve(.{
        .geometry = .{ .rows = 10, .columns = 40 },
        .launch_row = 5,
        .transcript_rows = 2,
        .footer_rows = 2,
    });
    const grown = try solve(.{
        .geometry = initial.geometry,
        .launch_row = 5,
        .transcript_rows = 2,
        .footer_rows = 5,
        .prior = initial.committed(),
    });
    try std.testing.expectEqual(@as(u32, 1), grown.physical_scroll_rows);
    try expectPlanBands(
        grown,
        .{ .top = 1, .bottom = 3 },
        .{ .top = 4, .bottom = 5 },
        .{ .top = 6, .bottom = 10 },
    );

    const shrunk = try solve(.{
        .geometry = grown.geometry,
        .launch_row = 5,
        .transcript_rows = 2,
        .footer_rows = 1,
        .prior = grown.committed(),
    });
    try std.testing.expectEqual(@as(u32, 0), shrunk.physical_scroll_rows);
    try std.testing.expectEqual(grown.owned_top, shrunk.owned_top);
    try std.testing.expectEqual(@as(u16, 6), shrunk.owned_bottom);
    try expectPlanBands(
        shrunk,
        .{ .top = 1, .bottom = 3 },
        .{ .top = 4, .bottom = 5 },
        .{ .top = 6, .bottom = 6 },
    );
}

test "full frame transcript growth continues native scrolling" {
    const initial = try solve(.{
        .geometry = .{ .rows = 6, .columns = 40 },
        .launch_row = 1,
        .transcript_rows = 4,
        .footer_rows = 2,
    });
    const grown = try solve(.{
        .geometry = initial.geometry,
        .launch_row = 1,
        .transcript_rows = 7,
        .footer_rows = 2,
        .prior = initial.committed(),
    });

    try std.testing.expectEqual(@as(u32, 3), grown.physical_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), grown.released_preserved_rows);
    try expectPlanBands(
        grown,
        .empty(),
        .{ .top = 1, .bottom = 4 },
        .{ .top = 5, .bottom = 6 },
    );
}

test "full lower frame growth accounts for preserved release first" {
    const initial = try solve(.{
        .geometry = .{ .rows = 8, .columns = 40 },
        .launch_row = 5,
        .transcript_rows = 2,
        .footer_rows = 2,
    });
    const grown = try solve(.{
        .geometry = initial.geometry,
        .launch_row = 5,
        .transcript_rows = 7,
        .footer_rows = 2,
        .prior = initial.committed(),
    });

    try std.testing.expectEqual(@as(u32, 5), grown.physical_scroll_rows);
    try std.testing.expectEqual(@as(u16, 4), grown.released_preserved_rows);
    try std.testing.expectEqual(@as(u16, 1), grown.owned_top);
    try std.testing.expectEqual(@as(u32, 1), grown.physical_scroll_rows - grown.released_preserved_rows);
}

test "height shrink releases only enough rows and keeps lower shell history" {
    const initial = try solve(.{
        .geometry = .{ .rows = 24, .columns = 80 },
        .launch_row = 10,
        .transcript_rows = 4,
        .footer_rows = 2,
    });
    const shrunk = try solve(.{
        .geometry = .{ .rows = 12, .columns = 80 },
        .launch_row = 10,
        .transcript_rows = 4,
        .footer_rows = 2,
        .prior = initial.committed(),
    });

    try std.testing.expectEqual(@as(u32, 3), shrunk.physical_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), shrunk.owned_top);
    const expected_preserved: Band = .{ .top = 1, .bottom = 6 };
    try std.testing.expectEqual(expected_preserved, shrunk.preserved_band);
    try std.testing.expect(shrunk.owned_top != 1);
}

test "height shrink clamps an off-screen owned top before release" {
    const initial = try solve(.{
        .geometry = .{ .rows = 20, .columns = 80 },
        .launch_row = 15,
        .transcript_rows = 2,
        .footer_rows = 2,
    });
    const shrunk = try solve(.{
        .geometry = .{ .rows = 6, .columns = 80 },
        .launch_row = 6,
        .transcript_rows = 2,
        .footer_rows = 2,
        .prior = initial.committed(),
    });

    try std.testing.expectEqual(@as(u16, 3), shrunk.owned_top);
    try std.testing.expectEqual(@as(u32, 3), shrunk.physical_scroll_rows);
    const expected_preserved: Band = .{ .top = 1, .bottom = 2 };
    try std.testing.expectEqual(expected_preserved, shrunk.preserved_band);
}

test "resize does not infer transcript growth scroll from changed geometry" {
    const initial = try solve(.{
        .geometry = .{ .rows = 4, .columns = 20 },
        .launch_row = 1,
        .transcript_rows = 3,
        .footer_rows = 1,
    });
    const resized = try solve(.{
        .geometry = .{ .rows = 8, .columns = 30 },
        .launch_row = 1,
        .transcript_rows = 6,
        .footer_rows = 1,
        .prior = initial.committed(),
    });

    try std.testing.expectEqual(@as(u32, 0), resized.physical_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), resized.owned_top);
    try std.testing.expectEqual(@as(u16, 7), resized.owned_bottom);
}

test "solver rejects invalid launch geometry and prior layouts" {
    try std.testing.expectError(error.InvalidGeometry, solve(.{
        .geometry = .{ .rows = 0, .columns = 80 },
        .launch_row = 1,
        .transcript_rows = 0,
        .footer_rows = 1,
    }));
    try std.testing.expectError(error.InvalidLaunchRow, solve(.{
        .geometry = .{ .rows = 4, .columns = 80 },
        .launch_row = 5,
        .transcript_rows = 0,
        .footer_rows = 1,
    }));

    var valid = (try solve(.{
        .geometry = .{ .rows = 4, .columns = 80 },
        .launch_row = 2,
        .transcript_rows = 1,
        .footer_rows = 1,
    })).committed();
    valid.preserved_band.bottom = 4;
    try std.testing.expectError(error.InvalidPriorLayout, solve(.{
        .geometry = .{ .rows = 4, .columns = 80 },
        .launch_row = 2,
        .transcript_rows = 1,
        .footer_rows = 1,
        .prior = valid,
    }));
}

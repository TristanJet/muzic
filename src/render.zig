const std = @import("std");
const util = @import("util.zig");
const window = @import("window.zig");
const term = @import("terminal.zig");
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const sym = @import("symbols.zig");
const mpd = @import("mpdclient.zig");
const io = std.io;
const fs = std.fs;
const mem = std.mem;

const wrkallocator = alloc.wrkallocator;

var app: *state.State = undefined;
var render_state: *RenderState = undefined;
var current: state.State = undefined;

pub const RenderState = struct {
    borders: bool = false,
    currentTrack: bool = false,
    bar: bool = false,
    queue: bool = false,
    queueEffects: bool = false,
    find: bool = false,
    browse_one: bool = false,
    browse_two: bool = false,
    browse_three: bool = false,
    browse_cursor_one: bool = false,
    browse_cursor_two: bool = false,
    browse_cursor_three: bool = false,
    clear_browse_cursor_one: bool = false,
    clear_browse_cursor_two: bool = false,
    clear_browse_cursor_three: bool = false,
    clear_col_two: bool = false,
    clear_col_three: bool = false,

    pub fn init() RenderState {
        return .{
            .borders = true,
            .currentTrack = true,
            .bar = true,
            .queue = true,
            .queueEffects = true,
            .find = true,
            .browse_one = false,
            .browse_two = false,
            .browse_three = false,
            .browse_cursor_one = false,
            .browse_cursor_two = false,
            .browse_cursor_three = false,
            .clear_browse_cursor_one = false,
            .clear_browse_cursor_two = false,
            .clear_browse_cursor_three = false,
        };
    }
};

pub fn render(app_state: *state.State, render_state_: *RenderState, panels: window.Panels, end_index: *usize) !void {
    render_state = render_state_;
    app = app_state;
    current = app_state.*;
    if (render_state.borders) try drawBorders(panels.curr_song.area);
    if (render_state.borders) try drawBorders(panels.queue.area);
    if (render_state.borders) try drawHeader(panels.queue.area, "queue");
    if (render_state.borders) try drawBorders(panels.find.area);
    if (render_state.borders or render_state.find) try drawHeader(panels.find.area, try getFindText());
    if (render_state.currentTrack) try currTrackRender(wrkallocator, panels.curr_song, app.song, end_index);
    if (render_state.bar) try barRender(panels.curr_song, app.song, wrkallocator);
    if (render_state.queue) try queueRender(wrkallocator, &alloc.wrkfba.end_index, panels.queue.validArea());
    if (render_state.queueEffects) try queueEffectsRender(wrkallocator, panels.queue.validArea());
    if (render_state.find) try findRender(panels.find);
    if (render_state.browse_one) try browseColumn(panels.browse1.validArea(), current.column_1.displaying, current.column_1.slice_inc);
    if (render_state.browse_two) try browseColumn(panels.browse2.validArea(), current.column_2.displaying, current.column_2.slice_inc);
    if (render_state.browse_three) try browseColumn(panels.browse3.validArea(), current.column_3.displaying, current.column_3.slice_inc);
    if (render_state.browse_cursor_one) try browseCursorRender(panels.browse1.validArea(), current.column_1.displaying, current.column_1.prev_pos, current.column_1.pos);
    if (render_state.browse_cursor_two) try browseCursorRender(panels.browse2.validArea(), current.column_2.displaying, current.column_2.prev_pos, current.column_2.pos);
    if (render_state.browse_cursor_three) try browseCursorRender(panels.browse3.validArea(), current.column_3.displaying, current.column_3.prev_pos, current.column_3.pos);
    if (render_state.clear_browse_cursor_one) try clearCursor(panels.browse1.validArea(), current.column_1.displaying, current.column_1.pos);
    if (render_state.clear_browse_cursor_two) try clearCursor(panels.browse2.validArea(), current.column_2.displaying, current.column_2.pos);
    if (render_state.clear_browse_cursor_three) try clearCursor(panels.browse3.validArea(), current.column_3.displaying, current.column_3.pos);
    if (render_state.clear_col_two) try clear(panels.browse2.validArea());
    if (render_state.clear_col_three) try clear(panels.browse3.validArea());

    term.flushBuffer() catch |err| if (err != error.WouldBlock) return err;
}

fn drawBorders(p: window.Area) !void {
    try term.moveCursor(p.ymin, p.xmin);
    try term.writeAll(sym.round_left_up);
    var x: usize = p.xmin + 1;
    while (x != p.xmax) {
        try term.writeAll(sym.h_line);
        x += 1;
    }
    try term.writeAll(sym.round_right_up);
    var y: usize = p.ymin + 1;
    while (y != p.ymax) {
        try term.moveCursor(y, p.xmin);
        try term.writeAll(sym.v_line);
        try term.moveCursor(y, p.xmax);
        try term.writeAll(sym.v_line);
        y += 1;
    }
    try term.moveCursor(p.ymax, p.xmin);
    try term.writeAll(sym.round_left_down);
    x = p.xmin + 1;
    while (x != p.xmax) {
        try term.writeAll(sym.h_line);
        x += 1;
    }
    try term.writeAll(sym.round_right_down);
}

fn drawHeader(p: window.Area, text: []const u8) !void {
    const x = p.xmin + 1;
    try term.moveCursor(p.ymin, x);
    try term.writeAll(sym.right_up);
    try term.writeAll(text);
    try term.writeAll(sym.left_up);
}

fn formatMilli(allocator: std.mem.Allocator, milli: u64) ![]const u8 {
    // Validate input - ensure we don't exceed reasonable time values
    if (milli > std.math.maxInt(u32) * 1000) {
        return error.TimeValueTooLarge;
    }

    const seconds = milli / 1000;
    const minutes = seconds / 60;
    const remainingSeconds = seconds % 60;

    // Format time string with proper error handling
    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}",
        .{ minutes, remainingSeconds },
    );
}

fn formatSeconds(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
    const minutes = seconds / 60;
    const remainingSeconds = seconds % 60;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}",
        .{ minutes, remainingSeconds },
    );
}

fn queueRender(allocator: std.mem.Allocator, end_index: *usize, area: window.Area) !void {
    const start = end_index.*;
    defer end_index.* = start;

    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeByteNTimes(' ', area.xlen);
    }

    for (current.viewStartQ..current.viewEndQ, 0..) |i, j| {
        if (i >= current.queue.len) break;
        const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
        try writeQueueLine(area, area.ymin + j, current.queue.items[i], itemTime);
    }
}

fn queueEffectsRender(allocator: std.mem.Allocator, area: window.Area) !void {
    var highlighted = false;

    for (current.viewStartQ..current.viewEndQ, 0..) |i, j| {
        if (i >= current.queue.len) break;
        if (current.queue.items[i].pos == current.prevCursorPos and current.input_state == .normal_queue) {
            const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
            try writeQueueLine(area, area.ymin + j, current.queue.items[i], itemTime);
        }
        if (current.queue.items[i].pos == current.cursorPosQ and current.input_state == .normal_queue) {
            const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
            try term.highlight();
            try writeQueueLine(area, area.ymin + j, current.queue.items[i], itemTime);
            try term.unhighlight();
            highlighted = true;
        }
        if ((current.song.id == current.queue.items[i].id) and !highlighted) {
            const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
            try term.setColor("\x1B[33m");
            try writeQueueLine(area, area.ymin + j, current.queue.items[i], itemTime);
            try term.attributeReset();
        }
        highlighted = false;
    }
}

fn writeQueueLine(area: window.Area, row: usize, song: mpd.QSong, itemTime: []const u8) !void {
    const n = area.xlen / 4;
    const gapcol = area.xlen / 8;
    try term.moveCursor(row, area.xmin);
    if (n > song.title.len) {
        try term.writeAll(song.title);
        try term.writeByteNTimes(' ', n - song.title.len);
    } else {
        try term.writeAll(song.title[0..n]);
    }
    try term.writeByteNTimes(' ', gapcol);
    if (n > song.artist.len) {
        try term.writeAll(song.artist);
        try term.writeByteNTimes(' ', n - song.artist.len);
    } else {
        try term.writeAll(song.artist[0..n]);
    }
    try term.writeByteNTimes(' ', area.xlen - 4 - gapcol - 2 * n);
    try term.moveCursor(row, area.xmax - 4);
    try term.writeAll(itemTime);
}

// fn scrollQ() !void {}
fn currTrackRender(
    allocator: std.mem.Allocator,
    p: window.Panel,
    s: mpd.CurrentSong,
    end_index: *usize,
) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const area = p.validArea();

    const xmin = area.xmin;
    const xmax = area.xmax;
    const ycent = p.getYCentre();

    const has_album = s.album.len > 0;
    const has_trackno = s.trackno.len > 0;

    const trckalb = if (!has_album)
        try std.fmt.allocPrint(allocator, "{s}", .{s.title})
    else if (!has_trackno)
        try std.fmt.allocPrint(allocator, "{s} - {s}", .{
            s.title,
            s.album,
        })
    else
        try std.fmt.allocPrint(allocator, "{s} - \"{s}\" {s}.", .{
            s.title,
            s.album,
            s.trackno,
        });

    //Include co-ords in the panel drawing?

    if (!current.first_render) {
        try term.clearLine(ycent, xmin + 11, xmax);
        try term.clearLine(ycent - 2, xmin, xmax);
    }
    try term.writeLine(s.artist, ycent, xmin, xmax);
    try term.writeLine(trckalb, ycent - 2, xmin, xmax);
    if (current.first_render) app.first_render = false;
}

fn barRender(panel: window.Panel, song: mpd.CurrentSong, allocator: std.mem.Allocator) !void {
    const area = panel.validArea();
    const ycent = panel.getYCentre();

    const full_block = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const light_shade = "\xe2\x96\x92"; // Unicode escape sequence for '▒' (U+2592)
    const progress_width = area.xmax - area.xmin;
    const progress_ratio = if (song.time.duration == 0) 0.0 else @as(f32, @floatFromInt(song.time.elapsed)) / @as(f32, @floatFromInt(song.time.duration));
    const float_filled = progress_ratio * @as(f32, @floatFromInt(progress_width));
    const filled = if (float_filled < 0.0) 0 else if (float_filled > @as(f32, @floatFromInt(progress_width))) progress_width else @as(usize, @intFromFloat(float_filled));

    // Initialize bar if it's the first render
    if (current.bar_init) {
        //time
        const elapsedTime = try formatSeconds(allocator, song.time.elapsed);
        const duration = try formatSeconds(allocator, song.time.duration);
        const timeFormatted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });
        try term.moveCursor(ycent, area.xmin);
        try term.writeAll(timeFormatted);
        try term.moveCursor(ycent + 2, area.xmin);
        //draw whole bar
        var x: usize = 0;
        while (x < progress_width) : (x += 1) {
            if (x < filled) {
                try term.writeAll(full_block);
            } else {
                try term.writeAll(light_shade);
            }
        }
        current.currently_filled = filled;
        current.bar_init = false;
        return;
    }

    if (song.time.elapsed != current.last_elapsed) {
        current.last_elapsed = song.time.elapsed;

        //time
        const elapsedTime = try formatSeconds(allocator, song.time.elapsed);
        const duration = try formatSeconds(allocator, song.time.duration);
        const timeFormatted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });
        try term.moveCursor(ycent, area.xmin);
        try term.writeAll(timeFormatted);
    }

    if (filled == current.currently_filled) return;
    // Only update the changing blocks
    if (filled > current.currently_filled) {
        // Fill in new blocks with full_block
        try term.moveCursor(ycent + 2, area.xmin + current.currently_filled);
        var x: usize = current.currently_filled;
        while (x < filled) : (x += 1) {
            try term.writeAll(full_block);
        }
    } else {
        // Replace full blocks with light_shade
        try term.moveCursor(ycent + 2, area.xmin + filled);
        var x: usize = filled;
        while (x < current.currently_filled) : (x += 1) {
            try term.writeAll(light_shade);
        }
    }
    current.currently_filled = filled;
}

fn browseColumn(area: window.Area, strings: []const []const u8, inc: usize) !void {
    util.log("first string: {s} \n", .{strings[0]});
    // Clear the display area
    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeByteNTimes(' ', area.xlen);
    }

    // Display only visible items based on slice_inc
    for (0..area.ylen) |i| {
        const item_index = i + inc;
        if (item_index >= strings.len) break;

        const string = strings[item_index];
        const xmax = if (area.xlen > string.len) string.len else area.xlen;
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeAll(string[0..xmax]);
    }
}

fn clear(area: window.Area) !void {
    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeByteNTimes(' ', area.xlen);
    }
}

fn browseCursorRender(area: window.Area, strings: []const []const u8, prev_pos: u8, pos: u8) !void {
    // Ensure that the positions are valid for the array
    if (strings.len == 0) return;

    // Get currently displayed slice indexes
    const col = for (0..3) |i| {
        const column = switch (i) {
            0 => current.column_1,
            1 => current.column_2,
            2 => current.column_3,
            else => unreachable,
        };
        if (std.meta.eql(column.displaying.ptr, strings.ptr)) {
            break column;
        }
    } else {
        return; // Column not found
    };

    const slice_inc = col.slice_inc;

    // Positions in the visible window (absolute index is pos + slice_inc)
    const prev_visible_pos = prev_pos;
    const curr_visible_pos = pos;

    // Check if these positions are visible in the current view window
    if (prev_visible_pos >= area.ylen or curr_visible_pos >= area.ylen) return;

    // Check if we have valid indices in the original array
    if (prev_visible_pos + slice_inc >= strings.len or
        curr_visible_pos + slice_inc >= strings.len) return;

    // Get the actual strings to render
    const prev = strings[prev_visible_pos + slice_inc];
    const curr = strings[curr_visible_pos + slice_inc];

    // Un-highlight the previous cursor position
    var nSpace: usize = 0;
    var xmax = area.xlen;
    if (prev.len < area.xlen) {
        nSpace = area.xlen - prev.len;
        xmax = prev.len;
    }
    try term.moveCursor(area.ymin + prev_visible_pos, area.xmin);
    try term.attributeReset();
    try term.writeAll(prev[0..xmax]);
    if (nSpace > 0) try term.writeByteNTimes(' ', nSpace);

    // Highlight the current cursor position
    if (curr.len < area.xlen) {
        nSpace = area.xlen - curr.len;
        xmax = curr.len;
    } else {
        nSpace = 0;
        xmax = area.xlen;
    }
    try term.moveCursor(area.ymin + curr_visible_pos, area.xmin);
    try term.highlight();
    try term.writeAll(curr[0..xmax]);
    if (nSpace > 0) try term.writeByteNTimes(' ', nSpace);
    try term.attributeReset();
}

fn clearCursor(area: window.Area, strings: []const []const u8, pos: u8) !void {
    // Safety check for valid position
    if (strings.len == 0) return;

    // Get currently displayed slice indexes
    const col = for (0..3) |i| {
        const column = switch (i) {
            0 => current.column_1,
            1 => current.column_2,
            2 => current.column_3,
            else => unreachable,
        };
        if (std.meta.eql(column.displaying.ptr, strings.ptr)) {
            break column;
        }
    } else {
        return; // Column not found
    };

    const slice_inc = col.slice_inc;

    // Position in the visible window
    const visible_pos = pos;

    // Check if this position is visible
    if (visible_pos >= area.ylen) return;

    // Check if we have a valid index in the original array
    if (visible_pos + slice_inc >= strings.len) return;

    // Get the actual string to render
    const curr = strings[visible_pos + slice_inc];

    var nSpace: usize = 0;
    var xmax = area.xlen;
    if (curr.len < area.xlen) {
        nSpace = area.xlen - curr.len;
        xmax = curr.len;
    }
    try term.moveCursor(area.ymin + visible_pos, area.xmin);
    try term.attributeReset();
    try term.writeAll(curr[0..xmax]);
    if (nSpace > 0) try term.writeByteNTimes(' ', nSpace);
}

fn findRender(panel: window.Panel) !void {
    const area = panel.validArea();

    switch (current.input_state) {
        .typing_find => {
            if (current.viewable_searchable) |viewable| {
                for (0..area.ylen) |i| {
                    try term.moveCursor(area.ymin + i, area.xmin);
                    try term.writeByteNTimes(' ', area.xlen);
                }
                for (viewable, 0..) |song, j| {
                    const len = if (song.string.?.len > area.xlen) area.xlen else song.string.?.len;
                    if (j == current.find_cursor_pos) try term.highlight();
                    try term.moveCursor(area.ymin + j, area.xmin);
                    try term.writeAll(song.string.?[0..len]);
                    if (j == current.find_cursor_pos) try term.unhighlight();
                }
            } else {
                for (0..area.ylen) |i| {
                    try term.moveCursor(area.ymin + i, area.xmin);
                    try term.writeByteNTimes(' ', area.xlen);
                }
            }
        },
        .normal_browse => {
            for (0..area.ylen) |i| {
                try term.moveCursor(area.ymin + i, area.xmin);
                try term.writeByteNTimes(' ', area.xlen);
            }
        },
        else => {},
    }
}

fn getFindText() ![]const u8 {
    return switch (current.input_state) {
        .normal_queue => try std.fmt.allocPrint(wrkallocator, "b{s}{s}find", .{ sym.left_up, sym.right_up }),
        .typing_find => try std.fmt.allocPrint(wrkallocator, "b{s}{s}find: {s}_", .{ sym.left_up, sym.right_up, current.typing_display.typed }),
        .normal_browse => try std.fmt.allocPrint(wrkallocator, "f{s}{s}browse", .{ sym.left_up, sym.right_up }),
        .typing_browse => try std.fmt.allocPrint(wrkallocator, "f{s}{s}browse: {s}_", .{ sym.left_up, sym.right_up, current.typing_display.typed }),
    };
}

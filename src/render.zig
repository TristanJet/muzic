const std = @import("std");
const util = @import("util.zig");
const window = @import("window.zig");
const term = @import("terminal.zig");
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const sym = @import("symbols.zig");
const mpd = @import("mpdclient.zig");
const Input_State = @import("input.zig").Input_State;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const n_browse_columns = state.n_browse_columns;

const wrkallocator = alloc.wrkallocator;

var current: state.State = undefined;

pub fn RenderState(n_col: comptime_int) type {
    const minus_one: comptime_int = n_col - 1;
    return struct {
        const Self = @This();
        borders: bool = false,
        currentTrack: bool = false,
        bar: bool = false,
        queue: bool = false,
        queueEffects: bool = false,
        find: bool = false,
        find_clear: bool = false,
        browse_col: [n_col]bool = .{false} ** n_col,
        browse_cursor: [n_col]bool = .{false} ** n_col,
        browse_clear_cursor: [n_col]bool = .{false} ** n_col,
        browse_clear: [minus_one]bool = .{false} ** minus_one,

        pub fn init() Self {
            return Self{
                .borders = true,
                .currentTrack = true,
                .bar = true,
                .queue = true,
                .queueEffects = true,
                .find = true,
                .find_clear = false,
                .browse_col = .{false} ** n_col,
                .browse_cursor = .{false} ** n_col,
                .browse_clear_cursor = .{false} ** n_col,
                .browse_clear = .{false} ** minus_one,
            };
        }

        pub fn reset(self: *Self) void {
            self.borders = false;
            self.currentTrack = false;
            self.bar = false;
            self.queue = false;
            self.queueEffects = false;
            self.find = false;
            self.find_clear = false;
            self.browse_col = .{false} ** n_col;
            self.browse_cursor = .{false} ** n_col;
            self.browse_clear_cursor = .{false} ** n_col;
            self.browse_clear = .{false} ** minus_one;
        }
    };
}

pub fn render(app: *state.State, render_state: *RenderState(n_browse_columns), panels: window.Panels, end_index: *usize) !void {
    current = app.*;
    if (render_state.borders) try drawBorders(panels.curr_song.area);
    if (render_state.borders) try drawBorders(panels.queue.area);
    if (render_state.borders) try drawHeader(panels.queue.area, "queue");
    if (render_state.borders) try drawBorders(panels.find.area);
    if (render_state.borders or render_state.find) try drawHeader(panels.find.area, try getFindText());
    if (render_state.currentTrack) try currTrackRender(wrkallocator, panels.curr_song, app.song, &app.first_render, end_index);
    if (render_state.bar) try barRender(panels.curr_song, app.song, wrkallocator);
    if (render_state.queue) try queueRender(wrkallocator, panels.queue.validArea(), app.queue.items, app.scroll_q.slice_inc);
    if (render_state.queueEffects) try queueEffectsRender(wrkallocator, panels.queue.validArea(), app.queue.items, app.scroll_q.absolutePos(), app.scroll_q.absolutePrevPos(), app.scroll_q.slice_inc, app.input_state, app.song.id);
    if (render_state.find) try findRender(panels.find);
    if (render_state.find_clear) try clear(panels.find.validArea());
    if (render_state.browse_col[0]) try browseColumn(panels.browse1.validArea(), app.col_arr.buf[0].displaying, app.col_arr.buf[0].slice_inc);
    if (render_state.browse_col[1]) try browseColumn(panels.browse2.validArea(), app.col_arr.buf[1].displaying, app.col_arr.buf[1].slice_inc);
    if (render_state.browse_col[2]) try browseColumn(panels.browse3.validArea(), app.col_arr.buf[2].displaying, app.col_arr.buf[2].slice_inc);
    if (render_state.browse_cursor[0]) try browseCursorRender(panels.browse1.validArea(), app.col_arr.buf[0].displaying, app.col_arr.buf[0].prev_pos, app.col_arr.buf[0].pos, app.col_arr.buf[0].slice_inc, &app.node_switched);
    if (render_state.browse_cursor[1]) try browseCursorRender(panels.browse2.validArea(), app.col_arr.buf[1].displaying, app.col_arr.buf[1].prev_pos, app.col_arr.buf[1].pos, app.col_arr.buf[1].slice_inc, &app.node_switched);
    if (render_state.browse_cursor[2]) try browseCursorRender(panels.browse3.validArea(), app.col_arr.buf[2].displaying, app.col_arr.buf[2].prev_pos, app.col_arr.buf[2].pos, app.col_arr.buf[2].slice_inc, &app.node_switched);
    if (render_state.browse_clear_cursor[0]) try clearCursor(panels.browse1.validArea(), current.col_arr.buf[0].displaying, current.col_arr.buf[0].pos, current.col_arr.buf[0].slice_inc);
    if (render_state.browse_clear_cursor[1]) try clearCursor(panels.browse2.validArea(), current.col_arr.buf[1].displaying, current.col_arr.buf[1].pos, current.col_arr.buf[1].slice_inc);
    if (render_state.browse_clear_cursor[2]) try clearCursor(panels.browse3.validArea(), current.col_arr.buf[2].displaying, current.col_arr.buf[2].pos, current.col_arr.buf[2].slice_inc);
    if (render_state.browse_clear[0]) try clear(panels.browse2.validArea());
    if (render_state.browse_clear[1]) try clear(panels.browse3.validArea());

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

fn queueRender(
    allocator: std.mem.Allocator,
    area: window.Area,
    items: []mpd.QSong,
    inc: usize,
) !void {
    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeByteNTimes(' ', area.xlen);
    }

    for (0..area.ylen) |i| {
        const queue_index = i + inc;
        if (queue_index >= items.len) break;

        const item = items[queue_index];
        const itemTime: []const u8 = formatSeconds(allocator, item.time) catch "";
        try writeQueueLine(area, area.ymin + i, item, itemTime);
    }
}

fn queueEffectsRender(
    allocator: std.mem.Allocator,
    area: window.Area,
    items: []mpd.QSong,
    abs_pos: usize,
    abs_prev_pos: usize,
    inc: usize,
    input_state: Input_State,
    current_song_id: usize,
) !void {
    var highlighted = false;

    for (0..area.ylen) |i| {
        const queue_index = i + inc;
        if (queue_index >= items.len) break;
        const item = items[queue_index];
        if (item.pos == abs_prev_pos and input_state == .normal_queue) {
            const itemTime: []const u8 = formatSeconds(allocator, item.time) catch "";
            try writeQueueLine(area, area.ymin + i, item, itemTime);
        }
        if (item.pos == abs_pos and input_state == .normal_queue) {
            const itemTime: []const u8 = formatSeconds(allocator, item.time) catch "";
            try term.highlight();
            try writeQueueLine(area, area.ymin + i, item, itemTime);
            try term.attributeReset();
            highlighted = true;
        }
        if ((current_song_id == item.id) and !highlighted) {
            const itemTime: []const u8 = formatSeconds(allocator, item.time) catch "";
            try term.setColor(.cyan);
            try writeQueueLine(area, area.ymin + i, item, itemTime);
            try term.setColor(.white);
        }
        highlighted = false;
    }
}

fn writeQueueLine(area: window.Area, row: usize, song: mpd.QSong, itemTime: []const u8) !void {
    const n = area.xlen / 4;
    const gapcol = area.xlen / 8;
    const no_title = "NO TITLE";
    try term.moveCursor(row, area.xmin);
    if (song.title) |title| {
        if (n > title.len) {
            try term.writeAll(title);
            try term.writeByteNTimes(' ', n - title.len);
        } else try term.writeAll(title[0..n]);
    } else {
        if (n > no_title.len) {
            try term.writeAll(no_title);
            try term.writeByteNTimes(' ', n - no_title.len);
        } else try term.writeAll(no_title[0..n]);
    }
    try term.writeByteNTimes(' ', gapcol);
    if (song.artist) |artist| {
        if (n > artist.len) {
            try term.writeAll(artist);
            try term.writeByteNTimes(' ', n - artist.len);
        } else try term.writeAll(artist[0..n]);
    } else try term.writeByteNTimes(' ', n);
    try term.writeByteNTimes(' ', area.xlen - 4 - gapcol - 2 * n);
    try term.moveCursor(row, area.xmax - 4);
    try term.writeAll(itemTime);
}

// fn scrollQ() !void {}
fn currTrackRender(
    allocator: std.mem.Allocator,
    p: window.Panel,
    s: mpd.CurrentSong,
    fr: *bool,
    end_index: *usize,
) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const area = p.validArea();

    const xmin = area.xmin;
    const xmax = area.xmax;
    const ycent = p.getYCentre();

    const has_album = s.album.len > 0;

    const artist_alb = if (!has_album)
        s.artist
    else
        try std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{
            s.artist,
            s.album,
        });

    //Include co-ords in the panel drawing?

    if (!current.first_render) {
        try term.clearLine(ycent, xmin + 11, xmax);
        try term.clearLine(ycent - 2, xmin, xmax);
    }
    try term.setColor(.magenta);
    try term.writeLine(artist_alb, ycent, xmin, xmax);
    try term.setColor(.cyan);
    try term.setBold();
    try term.writeLine(s.title, ycent - 2, xmin, xmax);
    try term.attributeReset();
    if (fr.*) fr.* = false;
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

fn browseColumn(area: window.Area, strings_opt: ?[]const []const u8, inc: usize) !void {
    // Clear the display area
    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeByteNTimes(' ', area.xlen);
    }

    const strings = strings_opt orelse return;
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

fn browseCursorRender(area: window.Area, strings_opt: ?[]const []const u8, prev_pos: u8, pos: u8, slice_inc: usize, switched: *bool) !void {
    const strings = strings_opt orelse return;
    if (strings.len == 0) return;
    var xmax = area.xlen;
    var nSpace: usize = 0;
    if (!switched.*) {
        if (prev_pos >= area.ylen) return error.OutOfBounds;
        if (prev_pos + slice_inc >= strings.len) return error.OutOfBounds;
        const prev = strings[prev_pos + slice_inc];
        // Un-highlight the previous cursor position
        if (prev.len < area.xlen) {
            nSpace = area.xlen - prev.len;
            xmax = prev.len;
        }
        try term.moveCursor(area.ymin + prev_pos, area.xmin);
        try term.attributeReset();
        try term.writeAll(prev[0..xmax]);
        if (nSpace > 0) try term.writeByteNTimes(' ', nSpace);
    } else switched.* = false;
    if (pos >= area.ylen) return error.OutOfBounds;
    if (pos + slice_inc >= strings.len) return error.OutOfBounds;

    const curr = strings[pos + slice_inc];

    // Highlight the current cursor position
    if (curr.len < area.xlen) {
        nSpace = area.xlen - curr.len;
        xmax = curr.len;
    } else {
        nSpace = 0;
        xmax = area.xlen;
    }
    try term.moveCursor(area.ymin + pos, area.xmin);
    try term.highlight();
    try term.writeAll(curr[0..xmax]);
    if (nSpace > 0) try term.writeByteNTimes(' ', nSpace);
    try term.attributeReset();
}

fn clearCursor(area: window.Area, strings_opt: ?[]const []const u8, pos: u8, inc: usize) !void {
    const strings = strings_opt orelse return;
    if (strings.len == 0) return;
    if (pos >= area.ylen) return error.posOverflow;
    // Get the actual string to render
    const curr = strings[pos + inc];

    var nSpace: usize = 0;
    var xmax = area.xlen;
    if (curr.len < area.xlen) {
        nSpace = area.xlen - curr.len;
        xmax = curr.len;
    }
    try term.moveCursor(area.ymin + pos, area.xmin);
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
                    const len = if (song.string.len > area.xlen) area.xlen else song.string.len;
                    if (j == current.find_cursor_pos) try term.highlight();
                    try term.moveCursor(area.ymin + j, area.xmin);
                    try term.writeAll(song.string[0..len]);
                    if (j == current.find_cursor_pos) try term.attributeReset();
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
        .typing_find => try std.fmt.allocPrint(wrkallocator, "b{s}{s}find: {s}_", .{ sym.left_up, sym.right_up, current.typing_buffer.typed }),
        .normal_browse => try std.fmt.allocPrint(wrkallocator, "f{s}{s}browse", .{ sym.left_up, sym.right_up }),
        .typing_browse => try std.fmt.allocPrint(wrkallocator, "f{s}{s}browse: {s}_", .{ sym.left_up, sym.right_up, current.typing_buffer.typed }),
    };
}

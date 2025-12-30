const std = @import("std");
const DisplayWidth = @import("DisplayWidth");
const util = @import("util.zig");
const window = @import("window.zig");
const term = @import("terminal.zig");
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const mpd = @import("mpdclient.zig");
const dw = @import("display_width.zig");
const QueueIterator = mpd.Queue.Iterator;
const Input_State = @import("input.zig").Input_State;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const n_browse_columns = state.n_browse_columns;

const wrkallocator = alloc.wrkallocator;

var current: state.State = undefined;

pub fn RenderState(n_col: comptime_int) type {
    return struct {
        const Self = @This();
        borders: bool = false,
        currentTrack: bool = false,
        bar: bool = false,
        queue: bool = false,
        queueEffects: bool = false,
        find: bool = false,
        find_cursor: bool = false,
        find_clear: bool = false,
        type: bool = false,
        browse_col: [n_col]bool = .{false} ** n_col,
        browse_bar: bool = false,
        browse_cursor: [n_col]bool = .{false} ** n_col,
        browse_clear_cursor: [n_col]bool = .{false} ** n_col,
        browse_clear: [n_col]bool = .{false} ** n_col,

        pub fn init() Self {
            return Self{
                .borders = true,
                .currentTrack = true,
                .bar = true,
                .queue = true,
                .queueEffects = true,
                .find = false,
                .find_cursor = false,
                .find_clear = false,
                .type = false,
                .browse_col = .{true} ** n_col,
                .browse_bar = true,
                .browse_cursor = .{false} ** n_col,
                .browse_clear_cursor = .{false} ** n_col,
                .browse_clear = .{false} ** n_col,
            };
        }

        pub fn reset(self: *Self) void {
            self.borders = false;
            self.currentTrack = false;
            self.bar = false;
            self.queue = false;
            self.queueEffects = false;
            self.find = false;
            self.find_cursor = false;
            self.find_clear = false;
            self.type = false;
            self.browse_col = .{false} ** n_col;
            self.browse_bar = false;
            self.browse_cursor = .{false} ** n_col;
            self.browse_clear_cursor = .{false} ** n_col;
            self.browse_clear = .{false} ** n_col;
        }
    };
}

pub const FixedString = struct {
    pub const MAX_LEN: u8 = 64;
    buffer: [MAX_LEN]u8 = undefined,
    slice: []const u8 = undefined,

    pub fn set(self: *FixedString, str: []const u8) []const u8 {
        if (str.len > MAX_LEN) {
            mem.copyForwards(u8, &self.buffer, str[0..MAX_LEN]);
            self.slice = self.buffer[0..MAX_LEN];
        } else {
            mem.copyForwards(u8, &self.buffer, str);
            self.slice = self.buffer[0..str.len];
        }
        return self.slice;
    }
};

pub fn render(app: *state.State, render_state: *RenderState(n_browse_columns), panels: window.Panels, end_index: *usize) !void {
    current = app.*;
    if (render_state.borders) try drawBorders(panels.curr_song.area);
    if (render_state.borders) try drawBorders(panels.queue.area);
    if (render_state.borders) try drawBorders(panels.find.area);
    if (render_state.borders or render_state.queue) try drawHeader(panels.queue.area, try getQueueText(wrkallocator, @min(app.queue.itopviewport + app.queue.nviewable, app.queue.pl_len), app.queue.pl_len));
    if (render_state.borders or render_state.type or render_state.find) try drawHeader(panels.find.area, try getFindText(wrkallocator));
    if (render_state.currentTrack) try currTrackRender(wrkallocator, panels.curr_song, app.song, &app.first_render, end_index);
    if (render_state.bar) try barRender(panels.curr_song, app.song, wrkallocator);
    if (render_state.queue) try queueRender(wrkallocator, panels.queue.validArea(), try app.queue.getIterator(), app.scroll_q.inc, app.queue.itopviewport + app.scroll_q.pos, app.visual_anchor_pos, app.input_state, app.song.id);
    if (render_state.queueEffects and !render_state.queue) try queueEffectsRender(wrkallocator, panels.queue.validArea(), try app.queue.getIterator(), app.scroll_q.pos + app.queue.itopviewport, app.scroll_q.prev_pos + app.queue.itopviewport, app.visual_anchor_pos, app.scroll_q.inc, app.input_state, app.song.id, app.prev_id);
    if (render_state.find) try findRender(panels.find.validArea());
    if (render_state.find_cursor) try findCursor(panels.find.validArea());
    if (render_state.find_clear) try clear(panels.find.validArea());
    if (render_state.browse_clear[0]) try clear(panels.browse1.validArea());
    if (render_state.browse_clear[1]) try clear(panels.browse2.validArea());
    if (render_state.browse_clear[2]) try clear(panels.browse3.validArea());
    if (render_state.borders) try drawColBar(panels.browse1.area);
    if (render_state.borders) try drawColBar(panels.browse2.area);
    if (render_state.browse_col[0]) try browseColumn(panels.browse1.validArea(), app.col_arr.buf[0].displaying, app.col_arr.buf[0].slice_inc, 1);
    if (render_state.browse_col[1]) try browseColumn(panels.browse2.validArea(), app.col_arr.buf[1].displaying, app.col_arr.buf[1].slice_inc, 2);
    if (render_state.browse_col[2]) try browseColumn(panels.browse3.validArea(), app.col_arr.buf[2].displaying, app.col_arr.buf[2].slice_inc, 3);
    if (render_state.browse_cursor[0]) try browseCursorRender(panels.browse1.validArea(), app.col_arr.buf[0].displaying, app.col_arr.buf[0].prev_pos, app.col_arr.buf[0].pos, app.col_arr.buf[0].slice_inc, &app.node_switched, 1);
    if (render_state.browse_cursor[1]) try browseCursorRender(panels.browse2.validArea(), app.col_arr.buf[1].displaying, app.col_arr.buf[1].prev_pos, app.col_arr.buf[1].pos, app.col_arr.buf[1].slice_inc, &app.node_switched, 2);
    if (render_state.browse_cursor[2]) try browseCursorRender(panels.browse3.validArea(), app.col_arr.buf[2].displaying, app.col_arr.buf[2].prev_pos, app.col_arr.buf[2].pos, app.col_arr.buf[2].slice_inc, &app.node_switched, 3);
    if (render_state.browse_clear_cursor[0]) try clearCursor(panels.browse1.validArea(), current.col_arr.buf[0].displaying, current.col_arr.buf[0].pos, current.col_arr.buf[0].slice_inc);
    if (render_state.browse_clear_cursor[1]) try clearCursor(panels.browse2.validArea(), current.col_arr.buf[1].displaying, current.col_arr.buf[1].pos, current.col_arr.buf[1].slice_inc);
    if (render_state.browse_clear_cursor[2]) try clearCursor(panels.browse3.validArea(), current.col_arr.buf[2].displaying, current.col_arr.buf[2].pos, current.col_arr.buf[2].slice_inc);

    term.flushBuffer() catch |err| if (err != error.WouldBlock) return err;
}

fn drawBorders(p: window.Area) !void {
    try term.moveCursor(p.ymin, p.xmin);
    try term.writeAll(term.symbols.round_left_up);
    var x: usize = p.xmin + 1;
    while (x != p.xmax) {
        try term.writeAll(term.symbols.h_line);
        x += 1;
    }
    try term.writeAll(term.symbols.round_right_up);
    var y: usize = p.ymin + 1;
    while (y != p.ymax) {
        try term.moveCursor(y, p.xmin);
        try term.writeAll(term.symbols.v_line);
        try term.moveCursor(y, p.xmax);
        try term.writeAll(term.symbols.v_line);
        y += 1;
    }
    try term.moveCursor(p.ymax, p.xmin);
    try term.writeAll(term.symbols.round_left_down);
    x = p.xmin + 1;
    while (x != p.xmax) {
        try term.writeAll(term.symbols.h_line);
        x += 1;
    }
    try term.writeAll(term.symbols.round_right_down);
}

fn drawColBar(a: window.Area) !void {
    const x = a.xmax;
    var y: usize = a.ymin;
    while (y <= a.ymax) {
        try term.moveCursor(y, x);
        try term.writeAll(term.symbols.v_line);
        y += 1;
    }
}

fn drawHeader(p: window.Area, text: []const u8) !void {
    const x = p.xmin + 1;
    try term.moveCursor(p.ymin, x);
    try term.writeAll(term.symbols.right_up);
    try term.writeAll(text);
    try term.writeAll(term.symbols.left_up);
    for (0..4) |_| {
        try term.writeAll(term.symbols.h_line);
    }
}

fn formatSeconds(allocator: mem.Allocator, seconds: u64) ![]const u8 {
    const minutes = seconds / 60;
    const remainingSeconds = seconds % 60;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}",
        .{ minutes, remainingSeconds },
    );
}

fn queueRender(
    allocator: mem.Allocator,
    area: window.Area,
    itq: QueueIterator,
    inc: usize,
    abs_pos: usize,
    anchor: ?usize,
    input_state: Input_State,
    current_song_id: usize,
) !void {
    var iterator: QueueIterator = itq;
    var item = iterator.next(inc);
    if (item == null) {
        try clear(area);
        try term.moveCursor(area.ylen / 2, area.xlen / 2);
        try writeLineCenter("queue empty", area.ylen / 2, area.xmin, area.xmax);
        return;
    }

    for (0..area.ylen) |i| {
        if (item) |x| {
            const should_highlight = switch (input_state) {
                .normal_queue => x.pos == abs_pos,
                .visual_queue => visualHlCond(x.pos, abs_pos, anchor orelse abs_pos),
                else => false,
            };

            if (should_highlight) {
                try term.highlight();
                try writeQueueLine(area, area.ymin + i, x, x.time, allocator);
                try term.attributeReset();
            } else if (current_song_id == x.id) {
                try term.setColor(.cyan);
                try writeQueueLine(area, area.ymin + i, x, x.time, allocator);
                try term.attributeReset();
            } else {
                try term.setColor(.white);
                try writeQueueLine(area, area.ymin + i, x, x.time, allocator);
            }
        } else {
            try term.moveCursor(area.ymin + i, area.xmin);
            try term.writeByteNTimes(' ', area.xlen);
        }

        item = iterator.next(inc);
    }
}

fn queueEffectsRender(
    allocator: std.mem.Allocator,
    area: window.Area,
    itq: QueueIterator,
    abs_pos: usize,
    abs_prev_pos: usize,
    anchor: ?usize,
    inc: usize,
    input_state: Input_State,
    current_song_id: usize,
    prev_song_id: usize,
) !void {
    var iterator = itq;

    for (0..area.ylen) |i| {
        const item = iterator.next(inc) orelse break;
        const y = area.ymin + i;

        const should_highlight = switch (input_state) {
            .normal_queue => item.pos == abs_pos,
            .visual_queue => visualHlCond(item.pos, abs_pos, anchor orelse abs_pos),
            else => false,
        };

        const should_clear = switch (input_state) {
            .normal_queue => item.pos == abs_prev_pos,
            .visual_queue => visualHlCond(item.pos, abs_prev_pos, anchor orelse abs_pos),
            else => false,
        };

        if (should_highlight) {
            try term.highlight();
            try writeQueueLine(area, y, item, item.time, allocator);
            try term.attributeReset();
        } else if (current_song_id == item.id) {
            try term.setColor(.cyan);
            try writeQueueLine(area, y, item, item.time, allocator);
            try term.attributeReset();
        } else if (should_clear or (prev_song_id != current_song_id and prev_song_id == item.id)) {
            try term.setColor(.white);
            try writeQueueLine(area, y, item, item.time, allocator);
        }
    }
}

fn visualHlCond(itempos: ?usize, cursor: usize, anchor: usize) bool {
    const pos = itempos orelse return false;
    const start = @min(cursor, anchor);
    const end = @max(cursor, anchor);

    return start <= pos and pos <= end;
}

fn writeQueueLine(area: window.Area, row: usize, song: mpd.QSong, time: ?u16, wa: mem.Allocator) !void {
    const n = area.xlen / 4;
    const gapcol = area.xlen / 8;
    const no_title = "NO TITLE";
    const ftime: []const u8 = if (time) |t|
        formatSeconds(wa, @as(u64, t)) catch ""
    else
        "";

    try term.moveCursor(row, area.xmin);
    if (song.title) |title| {
        const width = try dw.getDisplayWidth(title, .queue);
        try term.writeAll(title[0..width.byte_offset]);
        try term.writeByteNTimes(' ', n - width.cells);
    } else {
        if (n > no_title.len) {
            try term.writeAll(no_title);
            try term.writeByteNTimes(' ', n - no_title.len);
        } else try term.writeAll(no_title[0..n]);
    }
    try term.writeByteNTimes(' ', gapcol);
    if (song.artist) |artist| {
        const width = try dw.getDisplayWidth(artist, .queue);
        try term.writeAll(artist[0..width.byte_offset]);
        try term.writeByteNTimes(' ', n - width.cells);
    } else try term.writeByteNTimes(' ', n);
    try term.writeByteNTimes(' ', area.xlen - 4 - gapcol - 2 * n);
    try term.moveCursor(row, area.xmax - 4);
    try term.writeAll(ftime);
}

// Higher-level rendering functions
pub fn writeLineCenter(str: []const u8, y: usize, xmin: usize, xmax: usize) !void {
    const panel_width = xmax - xmin;
    const width = try dw.getDisplayWidth(str, .playing);
    const x_pos = xmin + (panel_width -| width.cells) / 2;
    try term.moveCursor(y, x_pos);
    try term.writeAll(str);
}

pub fn writeCenterBounded(str: []const u8, y: usize, xmin: usize, xmax: usize) !void {
    const panel_width = xmax - xmin;
    const width = try dw.getDisplayWidth(str, .playing);
    const x_pos = xmin + @max(((panel_width -| width.cells) / 2), 12); //HARD CODED SIZE OF CLOCK
    try term.moveCursor(y, x_pos);
    try term.writeAll(str[0..@min(str.len, xmax - 12)]); //HARD CODED SIZE OF CLOCK
}

fn currTrackRender(
    allocator: std.mem.Allocator,
    p: window.Panel,
    s: *mpd.CurrentSong,
    fr: *bool,
    end_index: *usize,
) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const area = p.validArea();

    const xmin = area.xmin;
    const xmax = area.xmax;
    const ycent = p.getYCentre();

    const artist_alb = if (s.album.len == 0)
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
    try writeCenterBounded(artist_alb, ycent, xmin, xmax);
    try term.setColor(.cyan);
    try term.setBold();
    try writeLineCenter(s.title[0..@min(s.title.len, xmax)], ycent - 2, xmin, xmax);
    try term.attributeReset();
    if (fr.*) fr.* = false;
}

fn barRender(panel: window.Panel, song: *mpd.CurrentSong, allocator: std.mem.Allocator) !void {
    const area = panel.validArea();
    const ycent = panel.getYCentre();

    const full_block = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const light_shade = "\xe2\x96\x92"; // Unicode escape sequence for '▒' (U+2592)
    // const light_shade: []const u8 = "#"; // Unicode escape sequence for '▒' (U+2592)
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

fn browseColumn(area: window.Area, strings_opt: ?[]const []const u8, inc: usize, col: u2) !void {
    const strings = strings_opt orelse return;
    // Display only visible items based on slice_inc

    for (0..area.ylen) |i| {
        const item_index = i + inc;
        if (item_index >= strings.len) break;

        const string = strings[item_index];
        const str_w: dw.Width = try dw.getDisplayWidth(string, @enumFromInt(col));

        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeAll(string[0..str_w.byte_offset]);
        const nSpace = area.xlen - str_w.cells;
        if (nSpace > 0) try term.writeByteNTimes(' ', nSpace);
    }
}

fn clear(area: window.Area) !void {
    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try term.writeByteNTimes(' ', area.xlen);
    }
}

fn browseCursorRender(area: window.Area, strings_opt: ?[]const []const u8, prev_pos: u8, pos: u8, slice_inc: usize, switched: *bool, col: u2) !void {
    const strings = strings_opt orelse return;
    if (strings.len == 0) return;
    var nSpace: usize = 0;
    var width: dw.Width = undefined;
    if (!switched.*) {
        if (prev_pos >= area.ylen) return error.OutOfBounds;
        if (prev_pos + slice_inc >= strings.len) return error.OutOfBounds;

        const prev = strings[prev_pos + slice_inc];
        width = try dw.getDisplayWidth(prev, @enumFromInt(col));
        nSpace = area.xlen - width.cells;

        try term.moveCursor(area.ymin + prev_pos, area.xmin);
        try term.attributeReset();
        try term.writeAll(prev[0..width.byte_offset]);
        try term.writeByteNTimes(' ', nSpace);
    } else switched.* = false;
    if (pos >= area.ylen) return error.OutOfBounds;
    if (pos + slice_inc >= strings.len) return error.OutOfBounds;

    const curr = strings[pos + slice_inc];
    width = try dw.getDisplayWidth(curr, @enumFromInt(col));
    nSpace = area.xlen - width.cells;

    try term.moveCursor(area.ymin + pos, area.xmin);
    try term.highlight();
    try term.writeAll(curr[0..width.byte_offset]);
    try term.writeByteNTimes(' ', nSpace);
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

fn findRender(area: window.Area) !void {
    if (current.viewable_searchable) |viewable| {
        for (0..area.ylen) |i| {
            try term.moveCursor(area.ymin + i, area.xmin);
            try term.writeByteNTimes(' ', area.xlen);
        }
        for (viewable, 0..) |song, j| {
            const len = if (song.string.len > area.xlen) area.xlen else song.string.len;
            try term.moveCursor(area.ymin + j, area.xmin);
            try term.writeAll(song.string[0..len]);
        }
    } else {
        for (0..area.ylen) |i| {
            try term.moveCursor(area.ymin + i, area.xmin);
            try term.writeByteNTimes(' ', area.xlen);
        }
    }
}

fn findCursor(area: window.Area) !void {
    if (current.viewable_searchable) |viewable| {
        for (viewable, 0..) |song, j| {
            if (j != current.find_cursor_pos and j != current.find_cursor_prev) continue;
            const len = if (song.string.len > area.xlen) area.xlen else song.string.len;
            if (j == current.find_cursor_pos) try term.highlight();
            try term.moveCursor(area.ymin + j, area.xmin);
            try term.writeAll(song.string[0..len]);
            if (j == current.find_cursor_pos) try term.attributeReset();
        }
    }
}

fn getQueueText(wa: mem.Allocator, viewend: usize, plen: usize) ![]const u8 {
    return std.fmt.allocPrint(wa, "queue ({}/{})", .{ viewend, plen });
}

fn getFindText(wa: mem.Allocator) ![]const u8 {
    return switch (current.input_state) {
        .normal_queue => try std.fmt.allocPrint(wa, "b{s}{s}find", .{ term.symbols.left_up, term.symbols.right_up }),
        .visual_queue => try std.fmt.allocPrint(wa, "b{s}{s}find", .{ term.symbols.left_up, term.symbols.right_up }),
        .typing_find => try std.fmt.allocPrint(wa, "b{s}{s}find: {s}_", .{ term.symbols.left_up, term.symbols.right_up, current.typing_buffer.typed }),
        .normal_browse => try std.fmt.allocPrint(wa, "f{s}{s}browse", .{ term.symbols.left_up, term.symbols.right_up }),
        .typing_browse => try std.fmt.allocPrint(wa, "f{s}{s}browse: {s}_", .{ term.symbols.left_up, term.symbols.right_up, current.typing_buffer.typed }),
    };
}

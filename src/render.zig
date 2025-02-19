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

    pub fn init() RenderState {
        return .{
            .borders = true,
            .currentTrack = true,
            .bar = true,
            .queue = true,
            .queueEffects = true,
            .find = true,
        };
    }
};

pub fn render(app_state: *state.State, render_state_: *RenderState, panels: window.Panels, end_index: *usize) !void {
    const writer = term.getWriter();
    render_state = render_state_;
    app = app_state;
    current = app_state.*;
    if (render_state.borders) try drawBorders(writer, panels.curr_song.area);
    if (render_state.borders) try drawBorders(writer, panels.queue.area);
    if (render_state.borders) try drawHeader(writer, panels.queue.area, "queue");
    if (render_state.borders) try drawBorders(writer, panels.find.area);
    if (render_state.borders or render_state.find) try drawHeader(writer, panels.find.area, try getFindText());
    if (render_state.currentTrack) try currTrackRender(wrkallocator, panels.curr_song, app.song, end_index);
    if (render_state.bar) try barRender(writer, panels.curr_song, app.song, wrkallocator);
    if (render_state.queue) try queueRender(writer, wrkallocator, &alloc.wrkfba.end_index, panels.queue.validArea());
    if (render_state.queueEffects) try queueEffectsRender(writer, wrkallocator, panels.queue.validArea());
    if (render_state.find) try findRender(writer, panels.find);
}

fn drawBorders(writer: *fs.File.Writer, p: window.Area) !void {
    try term.moveCursor(p.ymin, p.xmin);
    try writer.writeAll(sym.round_left_up);
    var x: usize = p.xmin + 1;
    while (x != p.xmax) {
        try writer.writeAll(sym.h_line);
        x += 1;
    }
    try writer.writeAll(sym.round_right_up);
    var y: usize = p.ymin + 1;
    while (y != p.ymax) {
        try term.moveCursor(y, p.xmin);
        try writer.writeAll(sym.v_line);
        try term.moveCursor(y, p.xmax);
        try writer.writeAll(sym.v_line);
        y += 1;
    }
    try term.moveCursor(p.ymax, p.xmin);
    try writer.writeAll(sym.round_left_down);
    x = p.xmin + 1;
    while (x != p.xmax) {
        try writer.writeAll(sym.h_line);
        x += 1;
    }
    try writer.writeAll(sym.round_right_down);
}

fn drawHeader(writer: *fs.File.Writer, p: window.Area, text: []const u8) !void {
    const x = p.xmin + 1;
    try term.moveCursor(p.ymin, x);
    try writer.writeAll(sym.right_up);
    try writer.writeAll(text);
    try writer.writeAll(sym.left_up);
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

fn queueRender(writer: *fs.File.Writer, allocator: std.mem.Allocator, end_index: *usize, area: window.Area) !void {
    const start = end_index.*;
    defer end_index.* = start;

    for (0..area.ylen) |i| {
        try term.moveCursor(area.ymin + i, area.xmin);
        try writer.writeByteNTimes(' ', area.xlen);
    }

    for (current.viewStartQ..current.viewEndQ, 0..) |i, j| {
        if (i >= current.queue.len) break;
        const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
        try writeQueueLine(writer, area, area.ymin + j, current.queue.items[i], itemTime);
    }
}

fn queueEffectsRender(writer: *fs.File.Writer, allocator: std.mem.Allocator, area: window.Area) !void {
    var highlighted = false;

    for (current.viewStartQ..current.viewEndQ, 0..) |i, j| {
        if (i >= current.queue.len) break;
        if (current.queue.items[i].pos == current.prevCursorPos and current.input_state == .normal) {
            const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
            try writeQueueLine(writer, area, area.ymin + j, current.queue.items[i], itemTime);
        }
        if (current.queue.items[i].pos == current.cursorPosQ and current.input_state == .normal) {
            const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
            try writer.writeAll("\x1B[7m");
            try writeQueueLine(writer, area, area.ymin + j, current.queue.items[i], itemTime);
            try writer.writeAll("\x1B[0m");
            highlighted = true;
        }
        if ((current.song.id == current.queue.items[i].id) and !highlighted) {
            const itemTime = try formatSeconds(allocator, current.queue.items[i].time);
            try writer.writeAll("\x1B[33m");
            try writeQueueLine(writer, area, area.ymin + j, current.queue.items[i], itemTime);
            try writer.writeAll("\x1B[0m");
        }
        highlighted = false;
    }
}

fn writeQueueLine(writer: *fs.File.Writer, area: window.Area, row: usize, song: mpd.QSong, itemTime: []const u8) !void {
    const n = area.xlen / 4;
    const gapcol = area.xlen / 8;
    try term.moveCursor(row, area.xmin);
    if (n > song.title.len) {
        try writer.writeAll(song.title);
        try writer.writeByteNTimes(' ', n - song.title.len);
    } else {
        try writer.writeAll(song.title[0..n]);
    }
    try writer.writeByteNTimes(' ', gapcol);
    if (n > song.artist.len) {
        try writer.writeAll(song.artist);
        try writer.writeByteNTimes(' ', n - song.artist.len);
    } else {
        try writer.writeAll(song.artist[0..n]);
    }
    try writer.writeByteNTimes(' ', area.xlen - 4 - gapcol - 2 * n);
    try term.moveCursor(row, area.xmax - 4);
    try writer.writeAll(itemTime);
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
    if (current.first_render) current.first_render = false;
}

fn barRender(writer: *fs.File.Writer, panel: window.Panel, song: mpd.CurrentSong, allocator: std.mem.Allocator) !void {
    const area = panel.validArea();
    const ycent = panel.getYCentre();

    const full_block = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const light_shade = "\xe2\x96\x92"; // Unicode escape sequence for '▒' (U+2592)
    const progress_width = area.xmax - area.xmin;
    const progress_ratio = @as(f32, @floatFromInt(song.time.elapsed)) / @as(f32, @floatFromInt(song.time.duration));
    const filled = @as(usize, @intFromFloat(progress_ratio * @as(f32, @floatFromInt(progress_width))));

    // Initialize bar if it's the first render
    if (current.bar_init) {
        //time
        const elapsedTime = try formatSeconds(allocator, song.time.elapsed);
        const duration = try formatSeconds(allocator, song.time.duration);
        const timeFormatted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });
        try term.moveCursor(ycent, area.xmin);
        try writer.writeAll(timeFormatted);
        try term.moveCursor(ycent + 2, area.xmin);
        //draw whole bar
        var x: usize = 0;
        while (x < progress_width) : (x += 1) {
            if (x < filled) {
                try writer.writeAll(full_block);
            } else {
                try writer.writeAll(light_shade);
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
        try writer.writeAll(timeFormatted);
    }

    if (filled == current.currently_filled) return;
    // Only update the changing blocks
    if (filled > current.currently_filled) {
        // Fill in new blocks with full_block
        try term.moveCursor(ycent + 2, area.xmin + current.currently_filled);
        var x: usize = current.currently_filled;
        while (x < filled) : (x += 1) {
            try writer.writeAll(full_block);
        }
    } else {
        // Replace full blocks with light_shade
        try term.moveCursor(ycent + 2, area.xmin + filled);
        var x: usize = filled;
        while (x < current.currently_filled) : (x += 1) {
            try writer.writeAll(light_shade);
        }
    }
    current.currently_filled = filled;
}

fn browseOneRender(writer: *fs.File.Writer, panels: window.Panels) !void {
    for (0..panels.browse1.area.ylen) |i| {
        try term.moveCursor(panels.browse1.area.ymin + i, panels.browse1.area.xmin);
        try writer.writeBytesNTimes("\xe2\x96\x88", panels.browse1.area.xlen);
    }
}

fn findRender(writer: *fs.File.Writer, panel: window.Panel) !void {
    const area = panel.validArea();

    switch (current.search_state) {
        .find => {
            if (current.viewable_searchable) |viewable| {
                for (0..area.ylen) |i| {
                    try term.moveCursor(area.ymin + i, area.xmin);
                    try writer.writeByteNTimes(' ', area.xlen);
                }
                for (viewable, 0..) |song, j| {
                    const len = if (song.string.?.len > area.xlen) area.xlen else song.string.?.len;
                    if (j == current.find_cursor_pos) try writer.writeAll("\x1B[7m");
                    try term.moveCursor(area.ymin + j, area.xmin);
                    try writer.writeAll(song.string.?[0..len]);
                    if (j == current.find_cursor_pos) try writer.writeAll("\x1B[0m");
                }
            } else {
                for (0..area.ylen) |i| {
                    try term.moveCursor(area.ymin + i, area.xmin);
                    try writer.writeByteNTimes(' ', area.xlen);
                }
            }
        },
        .browse => {
            for (0..area.ylen) |i| {
                try term.moveCursor(area.ymin + i, area.xmin);
                try writer.writeByteNTimes(' ', area.xlen);
            }
        },
    }
}

fn getFindText() ![]const u8 {
    switch (current.search_state) {
        .find => {
            return switch (current.input_state) {
                .normal => try std.fmt.allocPrint(wrkallocator, "b{s}{s}find", .{ sym.left_up, sym.right_up }),
                .typing => try std.fmt.allocPrint(wrkallocator, "b{s}{s}find: {s}_", .{ sym.left_up, sym.right_up, current.typing_display.typed }),
            };
        },
        .browse => {
            return switch (current.input_state) {
                .normal => try std.fmt.allocPrint(wrkallocator, "f{s}{s}browse", .{ sym.left_up, sym.right_up }),
                .typing => try std.fmt.allocPrint(wrkallocator, "f{s}{s}browse: {s}_", .{ sym.left_up, sym.right_up, current.typing_display.typed }),
            };
        },
    }
}

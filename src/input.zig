const std = @import("std");
const term = @import("terminal.zig");
const mpd = @import("mpdclient.zig");
const algo = @import("algo.zig");
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const window = @import("window.zig");
const mem = std.mem;
const time = std.time;
const assert = std.debug.assert;
const RenderState = @import("render.zig").RenderState;

const log = @import("util.zig").log;
const wrkallocator = alloc.wrkallocator;

const ui_order: [4]state.Column_Type = .{ .Select, .Artists, .Albums, .Tracks };

var app: *state.State = undefined;
var render_state: *RenderState = undefined;
var current: state.State = undefined;
pub var data: state.Data = undefined;

var last_input: i64 = 0;
const release_threshold: u8 = 15;
var nloops: u8 = 0;

pub var scroll_threshold: f16 = 0.2;
pub var min_scroll: u8 = 0;
pub var max_scroll: u8 = undefined;

var key_down: ?u8 = null;

var tracks_from_album: mpd.SongTitleAndUri = undefined;

pub const Input_State = enum {
    normal_queue,
    typing_find,
    normal_browse,
    typing_browse,
};

pub const cursorDirection = enum {
    up,
    down,
};

pub fn checkInputEvent(buffer: []u8) !?state.Event {
    assert(buffer.len == 1);
    const bytes_read: usize = try term.readBytes(buffer);
    if (bytes_read < 1) return null;
    return state.Event{ .input = buffer[0] };
}

pub fn checkReleaseEvent(input_event: ?state.Event) !?state.Event {
    if (key_down) |down| {
        if (input_event) |event| {
            if (down == event.input) {
                nloops = 0; // Key is still pressed, reset nloops
                return null;
            } else {
                // New key pressed, release the old one and track the new one
                nloops = 0;
                key_down = event.input;
                return state.Event{ .release = down };
            }
        } else {
            // No input, increment nloops
            nloops += 1;
            if (nloops >= release_threshold) {
                nloops = 0;
                key_down = null;
                return state.Event{ .release = down };
            }
            return null;
        }
    } else {
        if (input_event) |event| {
            key_down = event.input;
            nloops = 0; // Start tracking new key
        }
        return null;
    }
}

pub fn handleInput(char: u8, app_state: *state.State, render_state_: *RenderState) void {
    app = app_state;
    current = app_state.*;
    render_state = render_state_;
    switch (app_state.input_state) {
        .normal_queue => {
            normalQueue(char) catch unreachable;
        },
        .typing_find => {
            typingFind(char) catch unreachable;
        },
        .normal_browse => {
            normalBrowse(char) catch unreachable;
        },
        else => unreachable,
    }
}

pub fn handleRelease(char: u8, app_state: *state.State, render_state_: *RenderState) void {
    log("released: {}", .{char});
    app = app_state;
    current = app_state.*;
    render_state = render_state_;
    switch (app_state.input_state) {
        .normal_queue => {
            return;
            // normalQueue(char) catch unreachable;
        },
        .typing_find => {
            return;
        },
        .normal_browse => {
            normalBrowseRelease(char) catch unreachable;
        },
        else => unreachable,
    }
}

fn onTypingExit() void {
    app.typing_display.reset();
    render_state.borders = true;
    render_state.find = true;
    render_state.queueEffects = true;
    app.viewable_searchable = null;
    app.input_state = .normal_queue;
    app.find_cursor_pos = 0;
    algo.resetItems();
    _ = alloc.typingArena.reset(.retain_capacity);
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseExit() void {
    render_state.queueEffects = true;
    render_state.clear_browse_cursor_one = true;
    render_state.clear_browse_cursor_two = true;
    render_state.clear_browse_cursor_three = true;
    app.input_state = .normal_queue;
    app.selected_column = .one;
    _ = alloc.typingArena.reset(.retain_capacity);
}

fn typingFind(char: u8) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                onTypingExit();
                return;
            }
        },
        'n' & '\x1F' => {
            log("input: Ctrl-n\r\n", .{});
            scroll(&app.find_cursor_pos, current.viewable_searchable.?.len - 1, .down);
            render_state.find = true;
        },
        'p' & '\x1F' => {
            log("input: Ctrl-p\r\n", .{});
            scroll(&app.find_cursor_pos, null, .up);
            render_state.find = true;
        },
        '\r', '\n' => {
            const addUri = current.viewable_searchable.?[current.find_cursor_pos].uri;
            try mpd.addFromUri(wrkallocator, addUri);
            log("added: {s}", .{addUri});
            onTypingExit();
            return;
        },
        else => {
            typeFind(char);
            log("typed: {s}\n", .{app.typing_display.typed});
            const slice = try algo.algorithm(&alloc.algoArena, alloc.typingAllocator, app.typing_display.typed);
            app.viewable_searchable = slice[0..];
            log("viewable string: {s}\n", .{slice[0].string.?});
            render_state.find = true;
            return;
        },
    }
}

fn normalQueue(char: u8) !void {
    switch (char) {
        'q' => app.quit = true,
        'j' => scrollQ(false),
        'k' => scrollQ(true),
        'p' => {
            if (debounce()) return;
            app.isPlaying = try mpd.togglePlaystate(current.isPlaying);
        },
        'l' => {
            if (debounce()) return;
            try mpd.nextSong();
        },
        'h' => {
            if (debounce()) return;
            try mpd.prevSong();
        },
        'f' => {
            app.input_state = .typing_find;
            render_state.find = true;
            render_state.queue = true;
        },
        'b' => {
            app.input_state = .normal_browse;
            render_state.find = true;
            render_state.browse_one = true;
            render_state.browse_cursor_one = true;
            render_state.browse_two = true;
            render_state.queue = true;
        },
        'x' => {
            if (debounce()) return;
            try mpd.rmFromPos(wrkallocator, current.cursorPosQ);
            if (current.cursorPosQ == 0) {
                if (current.queue.len > 1) return;
            }
            moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .down);
        },
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) return;

            if (mem.eql(u8, escBuffer[0..escRead], "[A")) {
                // log("input: arrow up\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[B")) {
                // log("input: arrow down\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[C")) {
                if (debounce()) return;
                try mpd.seekCur(true);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[D")) {
                if (debounce()) return;
                try mpd.seekCur(false);
            } else {
                log("unknown escape sequence", .{});
            }
        },
        '\n', '\r' => {
            if (debounce()) return;
            try mpd.playByPos(wrkallocator, current.cursorPosQ);
            if (!current.isPlaying) app.isPlaying = true;
        },
        else => log("input: {c}", .{char}),
    }
}

fn normalBrowse(char: u8) !void {
    switch (char) {
        'q' => app.quit = true,
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                onBrowseExit();
            }
        },
        'j' => verticalScroll(.down),
        'k' => verticalScroll(.up),
        'h' => {
            switch (current.selected_column) {
                .one => {},
                .two => {
                    app.selected_column = .one;
                    render_state.clear_browse_cursor_two = true;
                    render_state.browse_cursor_one = true;
                    render_state.clear_col_three = true;
                },
                .three => {
                    app.selected_column = .two;
                    app.column_3.pos = 0;

                    render_state.clear_browse_cursor_three = true;
                    render_state.browse_cursor_two = true;
                },
            }
        },
        'l' => selectNextColumn(),
        '\n', '\r' => {
            switch (current.selected_column) {
                .one => selectNextColumn(),
                .two => {
                    switch (current.column_2.type) {
                        .Tracks => {
                            const uri = data.songs.uris[current.column_2.absolutePos()];
                            try mpd.addFromUri(alloc.typingAllocator, uri);
                        },
                        else => selectNextColumn(),
                    }
                },
                .three => {
                    switch (current.column_3.type) {
                        .Tracks => {
                            const uri = tracks_from_album.uris[current.column_3.absolutePos()];
                            try mpd.addFromUri(alloc.typingAllocator, uri);
                        },
                        else => selectNextColumn(),
                    }
                },
            }
        },
        else => unreachable,
    }
}

fn verticalScroll(dir: cursorDirection) void {
    switch (current.selected_column) {
        .one => {
            const visible_area = window.panels.browse1.validArea();
            const max: ?u8 = if (dir == .up) null else @intCast(@min(visible_area.ylen, app.column_1.displaying.len));
            app.column_1.scroll(dir, max, visible_area.ylen);
            if (current.column_2.pos != 0) app.column_2.pos = 0;
            switch (app.column_1.pos) {
                0 => {
                    app.column_2.type = .Albums;
                    app.column_2.displaying = data.albums;
                },
                1 => {
                    app.column_2.type = .Artists;
                    app.column_2.displaying = data.artists;
                },
                2 => {
                    app.column_2.type = .Tracks;
                    app.column_2.displaying = data.songs.titles;
                },
                else => unreachable,
            }
            render_state.browse_one = true;
            render_state.browse_cursor_one = true;
            render_state.browse_two = true;
        },
        .two => {
            // Add safety check before scrolling
            if (app.column_2.displaying.len > 0) {
                const visible_area = window.panels.browse2.validArea();
                const max: ?u8 = if (dir == .up) null else @intCast(@min(visible_area.ylen, app.column_2.displaying.len));
                app.column_2.scroll(dir, max, visible_area.ylen);
                render_state.browse_two = true;
                render_state.browse_cursor_two = true;
            }
            // render_state.browse_three = true;
        },
        .three => {
            const visible_area = window.panels.browse3.validArea();
            const max: ?u8 = if (dir == .up) null else @intCast(@min(visible_area.ylen, app.column_3.displaying.len));
            app.column_3.scroll(dir, max, visible_area.ylen);
            render_state.browse_three = true;
            render_state.browse_cursor_three = true;
        },
    }
}

fn selectNextColumn() void {
    log("{}", .{current.column_2.type});
    switch (current.selected_column) {
        .one => {
            app.column_3.type = switch (current.column_2.type) {
                .Albums => .Tracks,
                .Artists => .Albums,
                .Tracks => .None,
                else => unreachable,
            };
            app.selected_column = .two;
            render_state.clear_browse_cursor_one = true;
            render_state.browse_cursor_two = true;
        },
        .two => {
            app.selected_column = .three;
            render_state.clear_browse_cursor_two = true;
            render_state.browse_cursor_three = true;
        },
        .three => {},
    }
}

fn normalBrowseRelease(char: u8) !void {
    switch (char) {
        'j', 'k' => {
            // Only update column 3 when column 2 is selected and has items
            if (current.selected_column != .two) return;
            if (current.column_2.displaying.len == 0) return;

            // if (current.column_2.absolutePos() >= current.column_2.displaying.len) return;

            try column2Release();
        },
        'l', '\n', '\r' => {
            if (current.selected_column != .two) return;
            if (current.column_2.displaying.len == 0) return;

            // Get actual position including slice_inc offset
            const actual_pos = current.column_2.pos + current.column_2.slice_inc;
            if (actual_pos >= current.column_2.displaying.len) return;

            try column2Release();
        },
        else => {
            log("unrecognized key", .{});
        },
    }
}

fn column2Release() !void {
    // Check if there's anything to display
    if (current.column_2.displaying.len == 0) return;

    // Get the actual index with slice_inc offset
    const actual_index = current.column_2.pos + current.column_2.slice_inc;

    // Make sure the index is valid
    if (actual_index >= current.column_2.displaying.len) return;

    var next_col_display: [][]const u8 = undefined;
    log("{}", .{current.column_2.type});
    switch (current.column_2.type) {
        .Albums => {
            app.find_filter.album = current.column_2.displaying[actual_index];
            log("album: {s}", .{app.find_filter.album});
            tracks_from_album = try mpd.findTracksFromAlbum(&app.find_filter, alloc.respAllocator, alloc.typingAllocator);
            next_col_display = tracks_from_album.titles;
        },
        .Artists => {
            next_col_display = try mpd.findAlbumsFromArtists(current.column_2.displaying[actual_index], alloc.respAllocator, alloc.typingAllocator);
        },
        .Tracks => return,
        else => unreachable,
    }
    _ = alloc.respArena.reset(.free_all);

    app.column_3.displaying = next_col_display;
    app.column_3.slice_inc = 0; // Reset slice increment for the third column
    render_state.browse_three = true;
}

fn debounce() bool {
    //input debounce
    const current_time = time.milliTimestamp();
    const diff = current_time - last_input;
    if (diff < 300) {
        return true;
    }
    last_input = current_time;
    return false;
}

fn typeFind(char: u8) void {
    app.typing_display.typeBuffer[current.typing_display.typed.len] = char;
    app.typing_display.typed = app.typing_display.typeBuffer[0 .. current.typing_display.typed.len + 1];
}

pub fn scrollQ(isUp: bool) void {
    if (isUp) {
        if (current.cursorPosQ == 0) return;
        moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .down);
        if (current.cursorPosQ < current.viewStartQ) {
            app.viewStartQ = current.cursorPosQ;
            app.viewEndQ = app.viewStartQ + window.panels.queue.validArea().ylen + 1;
        }
    } else {
        if (current.cursorPosQ >= current.queue.len - 1) return;
        moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .up);
        if (current.cursorPosQ >= current.viewEndQ) {
            app.viewEndQ = current.cursorPosQ + 1;
            app.viewStartQ = app.viewEndQ - window.panels.queue.validArea().ylen - 1;
        }
    }
    render_state.queueEffects = true;
}
fn moveCursorPos(current_dir: *u8, previous_dir: *u8, direction: cursorDirection) void {
    switch (direction) {
        .up => {
            previous_dir.* = current_dir.*;
            current_dir.* += 1;
        },
        .down => {
            previous_dir.* = current_dir.*;
            current_dir.* -= 1;
        },
    }
}

fn scroll(cursor_pos: *u8, max: ?usize, dir: cursorDirection) void {
    switch (dir) {
        .up => {
            if (cursor_pos.* > 0) {
                cursor_pos.* -= 1;
            }
        },
        .down => {
            if (cursor_pos.* < max.?) {
                cursor_pos.* += 1;
            }
        },
    }
}

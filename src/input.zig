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

pub var data: state.Data = undefined;

var last_input: i64 = 0;
const release_threshold: u8 = 15;
var nloops: u8 = 0;

pub var scroll_threshold: f16 = 0.2;
pub var min_scroll: u8 = 0;
pub var max_scroll: u8 = undefined;

var key_down: ?u8 = null;

// This contains shared data that will be refactored into the browser module
var tracks_from_album: mpd.SongTitleAndUri = undefined;
var albums_from_artist: []const []const u8 = undefined;

// to save before switching back
var temp_col2_inc: usize = 0;

pub const browse_types: [3][]const u8 = .{ "Albums", "Artists", "Songs" };

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

// ---- Core Input Handling ----

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

pub fn handleInput(char: u8, app_state: *state.State, render_state: *RenderState) void {
    const handler = switch (app_state.input_state) {
        .normal_queue => &normalQueue,
        .typing_find => &typingFind,
        .normal_browse => &handleNormalBrowse,
        .typing_browse => &typingBrowse,
    };
    handler(char, app_state, render_state) catch unreachable;
}

pub fn handleRelease(char: u8, app_state: *state.State, render_state: *RenderState) void {
    if (app_state.input_state == .normal_browse) handleBrowseKeyRelease(char, app_state, render_state) catch unreachable;
}

// ---- State Transitions ----

fn onTypingExit(app: *state.State, render_state: *RenderState) void {
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

fn onBrowseExit(app: *state.State, render_state: *RenderState) void {
    render_state.queueEffects = true;
    render_state.clear_browse_cursor_one = true;
    render_state.clear_browse_cursor_two = true;
    render_state.clear_browse_cursor_three = true;

    if (app.column_3.type == .Tracks and app.column_1.type == .Artists) revertSwitcheroo(app);
    app.input_state = .normal_queue;
    app.selected_column = .one;
    _ = alloc.typingArena.reset(.retain_capacity);
}

// ---- Input Mode Handlers ----

fn typingBrowse(char: u8, app: *state.State, render_state: *RenderState) !void {
    log("{}{}{}", .{ char, app, render_state });
    return;
}

fn typingFind(char: u8, app: *state.State, render_state: *RenderState) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                onTypingExit(app, render_state);
                return;
            }
        },
        'n' & '\x1F' => {
            log("input: Ctrl-n\r\n", .{});
            scroll(&app.find_cursor_pos, app.viewable_searchable.?.len - 1, .down);
            render_state.find = true;
        },
        'p' & '\x1F' => {
            log("input: Ctrl-p\r\n", .{});
            scroll(&app.find_cursor_pos, null, .up);
            render_state.find = true;
        },
        '\r', '\n' => {
            const addUri = app.viewable_searchable.?[app.find_cursor_pos].uri;
            try mpd.addFromUri(wrkallocator, addUri);
            log("added: {s}", .{addUri});
            onTypingExit(app, render_state);
            return;
        },
        else => {
            typeFind(char, app);
            log("typed: {s}\n", .{app.typing_display.typed});
            const slice = try algo.algorithm(&alloc.algoArena, alloc.typingAllocator, app.typing_display.typed);
            app.viewable_searchable = slice[0..];
            log("viewable string: {s}\n", .{slice[0].string.?});
            render_state.find = true;
            return;
        },
    }
}

fn normalQueue(char: u8, app: *state.State, render_state: *RenderState) !void {
    switch (char) {
        'q' => app.quit = true,
        'j' => scrollQ(false, app, render_state),
        'k' => scrollQ(true, app, render_state),
        'p' => {
            if (debounce()) return;
            app.isPlaying = try mpd.togglePlaystate(app.isPlaying);
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
            try mpd.rmFromPos(wrkallocator, app.cursorPosQ);
            if (app.cursorPosQ == 0) {
                if (app.queue.len > 1) return;
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
            try mpd.playByPos(wrkallocator, app.cursorPosQ);
            if (!app.isPlaying) app.isPlaying = true;
        },
        else => log("input: {c}", .{char}),
    }
}

// ---- Browser Module ----

fn handleNormalBrowse(char: u8, app: *state.State, render_state: *RenderState) !void {
    switch (char) {
        'q' => app.quit = true,
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                onBrowseExit(app, render_state);
            }
        },
        'j' => browserScrollVertical(.down, app, render_state),
        'k' => browserScrollVertical(.up, app, render_state),
        'h' => browserNavigateLeft(app, render_state),
        'l' => browserSelectNextColumn(app, render_state),
        '\n', '\r' => try browserHandleEnter(app, render_state),
        else => unreachable,
    }
}

// Browser vertical scrolling - handles all three columns in one place
fn browserScrollVertical(dir: cursorDirection, app: *state.State, render_state: *RenderState) void {
    switch (app.selected_column) {
        .one => browserScrollColumn1(dir, app, render_state),
        .two => browserScrollColumn2(dir, app, render_state),
        .three => browserScrollColumn3(dir, app, render_state),
    }
}

fn browserScrollColumn1(dir: cursorDirection, app: *state.State, render_state: *RenderState) void {
    const visible_area = window.panels.browse1.validArea();
    const max: ?u8 = if (dir == .up) null else @intCast(@min(visible_area.ylen, app.column_1.displaying.len));
    app.column_1.scroll(dir, max, visible_area.ylen);
    if (app.column_2.pos != 0) app.column_2.pos = 0;

    // Update column 2 content based on column 1 selection
    switch (app.column_1.pos) {
        0 => browserSetColumn2ToAlbums(app),
        1 => browserSetColumn2ToArtists(app),
        2 => browserSetColumn2ToTracks(app),
        else => unreachable,
    }

    render_state.browse_one = true;
    render_state.browse_cursor_one = true;
    render_state.browse_two = true;
}

fn browserSetColumn2ToAlbums(app: *state.State) void {
    app.column_2.type = .Albums;
    app.column_3.type = .Artists;
    app.column_2.displaying = data.albums;
}

fn browserSetColumn2ToArtists(app: *state.State) void {
    app.column_2.type = .Artists;
    app.column_3.type = .Albums;
    app.column_2.displaying = data.artists;
}

fn browserSetColumn2ToTracks(app: *state.State) void {
    app.column_2.type = .Tracks;
    app.column_3.type = .None;
    app.column_2.displaying = data.songs.titles;
}

fn browserScrollColumn2(dir: cursorDirection, app: *state.State, render_state: *RenderState) void {
    // Add safety check before scrolling
    if (app.column_2.displaying.len > 0) {
        const visible_area = window.panels.browse2.validArea();
        const max: ?u8 = if (dir == .up) null else @intCast(@min(visible_area.ylen, app.column_2.displaying.len));
        app.column_2.scroll(dir, max, visible_area.ylen);
        render_state.browse_two = true;
        render_state.browse_cursor_two = true;
    }
}

fn browserScrollColumn3(dir: cursorDirection, app: *state.State, render_state: *RenderState) void {
    const visible_area = window.panels.browse3.validArea();
    const max: ?u8 = if (dir == .up) null else @intCast(@min(visible_area.ylen, app.column_3.displaying.len));
    app.column_3.scroll(dir, max, visible_area.ylen);
    render_state.browse_three = true;
    render_state.browse_cursor_three = true;
}

// Browser left navigation - handles column dependency
fn browserNavigateLeft(app: *state.State, render_state: *RenderState) void {
    switch (app.selected_column) {
        .one => {}, // Nothing to do when already in column 1
        .two => browserNavigateFromColumn2ToColumn1(app, render_state),
        .three => browserNavigateFromColumn3(app, render_state),
    }
}

fn browserNavigateFromColumn2ToColumn1(app: *state.State, render_state: *RenderState) void {
    app.selected_column = .one;
    app.find_filter = mpd.Filter_Songs{
        .album = undefined,
        .artist = null,
    };
    render_state.clear_browse_cursor_two = true;
    render_state.browse_cursor_one = true;
    render_state.clear_col_three = true;
}

fn browserNavigateFromColumn3(app: *state.State, render_state: *RenderState) void {
    if (app.column_3.type == .Tracks and app.column_1.type == .Artists) {
        revertSwitcheroo(app);
        render_state.browse_one = true;
        render_state.browse_two = true;
        render_state.browse_three = true;
        render_state.browse_cursor_three = true;
        return;
    }

    app.selected_column = .two;
    app.column_3.pos = 0;
    render_state.clear_browse_cursor_three = true;
    render_state.browse_cursor_two = true;
}

fn revertSwitcheroo(app: *state.State) void {
    const artists = app.column_1.displaying;
    const albums = app.column_2.displaying;
    const select = browse_types[0..];

    app.column_3.pos = 0;
    app.column_1.displaying = select;
    app.column_2.displaying = artists;
    app.column_3.displaying = albums;
    app.column_3.type = .Albums;
    app.column_2.type = .Artists;
    app.column_1.type = .Select;
}

// Browser column navigation - handles moving to next column
fn browserSelectNextColumn(app: *state.State, render_state: *RenderState) void {
    switch (app.selected_column) {
        .one => browserMoveFromColumn1ToColumn2(app, render_state),
        .two => browserMoveFromColumn2ToColumn3(app, render_state),
        .three => browserHandleColumn3Selection(app, render_state),
    }
}

fn browserMoveFromColumn1ToColumn2(app: *state.State, render_state: *RenderState) void {
    app.column_3.type = switch (app.column_2.type) {
        .Albums => .Tracks,
        .Artists => .Albums,
        .Tracks => .None,
        else => unreachable,
    };
    app.selected_column = .two;
    render_state.clear_browse_cursor_one = true;
    render_state.browse_cursor_two = true;
}

fn browserMoveFromColumn2ToColumn3(app: *state.State, render_state: *RenderState) void {
    app.selected_column = .three;
    render_state.clear_browse_cursor_two = true;
    render_state.browse_cursor_three = true;
}

fn browserHandleColumn3Selection(app: *state.State, render_state: *RenderState) void {
    switch (app.column_3.type) {
        .Albums => {
            switcheroo(app) catch |err|
                log("column switch error: {}", .{err});
            render_state.browse_one = true;
            render_state.browse_two = true;
            render_state.browse_three = true;
            render_state.browse_cursor_three = true;
        },
        .Tracks => {}, // Nothing to do for tracks in column 3
        else => unreachable,
    }
}

fn switcheroo(app: *state.State) !void {
    app.find_filter.album = app.column_3.displaying[app.column_3.absolutePos()];
    const artists = app.column_2.displaying;
    const albums = app.column_3.displaying;

    // Save column 2 increment for potential later use
    temp_col2_inc = app.column_2.slice_inc;
    app.column_2.slice_inc = 0;
    app.column_3.pos = 0;

    // Rearrange columns
    app.column_1.displaying = artists;
    app.column_2.displaying = albums;
    app.column_3.type = .Tracks;
    app.column_1.type = .Artists;
    app.column_2.type = .Albums;

    // Fetch tracks from selected album
    tracks_from_album = try mpd.findTracksFromAlbum(&app.find_filter, alloc.respAllocator, alloc.persistentAllocator);
    app.column_3.displaying = tracks_from_album.titles;
}

// Handle Enter key press in browser mode
fn browserHandleEnter(app: *state.State, render_state: *RenderState) !void {
    switch (app.selected_column) {
        .one => browserSelectNextColumn(app, render_state),
        .two => {
            if (app.column_2.type == .Tracks) {
                const uri = data.songs.uris[app.column_2.absolutePos()];
                try mpd.addFromUri(alloc.typingAllocator, uri);
            } else {
                browserSelectNextColumn(app, render_state);
            }
        },
        .three => {
            if (app.column_3.type == .Tracks) {
                const uri = tracks_from_album.uris[app.column_3.absolutePos()];
                try mpd.addFromUri(alloc.typingAllocator, uri);
            } else {
                browserSelectNextColumn(app, render_state);
            }
        },
    }
}

// Handle key release events specifically for the browser
fn handleBrowseKeyRelease(char: u8, app: *state.State, render_state: *RenderState) !void {
    switch (char) {
        'j', 'k', 'l', '\n', '\r' => {
            // Only update column 3 when column 2 is selected and has items
            if (app.selected_column != .two) return;
            if (app.column_2.displaying.len == 0) return;
            if (app.column_2.type == .Tracks) return;

            try browserUpdateColumn3FromColumn2(app);
            render_state.browse_three = true;
        },
        else => {
            log("unrecognized key", .{});
        },
    }
}

// Update column 3 content based on column 2 selection
fn browserUpdateColumn3FromColumn2(app: *state.State) !void {
    // Check if there's anything to display
    if (app.column_2.displaying.len == 0) return;

    // Get the actual index with slice_inc offset
    const actual_index = app.column_2.absolutePos();

    // Make sure the index is valid
    if (actual_index >= app.column_2.displaying.len) return;

    var next_col_display: [][]const u8 = undefined;

    switch (app.column_2.type) {
        .Albums => {
            app.find_filter.album = app.column_2.displaying[actual_index];
            log("album: {s}", .{app.find_filter.album});
            tracks_from_album = try mpd.findTracksFromAlbum(&app.find_filter, alloc.respAllocator, alloc.typingAllocator);
            next_col_display = tracks_from_album.titles;
        },
        .Artists => {
            app.find_filter.artist = app.column_2.displaying[actual_index];
            next_col_display = try mpd.findAlbumsFromArtists(app.column_2.displaying[actual_index], alloc.respAllocator, alloc.typingAllocator);
        },
        .Tracks => return,
        else => unreachable,
    }

    _ = alloc.respArena.reset(.free_all);
    app.column_3.displaying = next_col_display;
    app.column_3.slice_inc = 0; // Reset slice increment for the third column
}

// ---- Utility Functions ----

fn debounce() bool {
    //input debounce
    const app_time = time.milliTimestamp();
    const diff = app_time - last_input;
    if (diff < 300) {
        return true;
    }
    last_input = app_time;
    return false;
}

fn typeFind(char: u8, app: *state.State) void {
    app.typing_display.typeBuffer[app.typing_display.typed.len] = char;
    app.typing_display.typed = app.typing_display.typeBuffer[0 .. app.typing_display.typed.len + 1];
}

pub fn scrollQ(isUp: bool, app: *state.State, render_state: *RenderState) void {
    if (isUp) {
        if (app.cursorPosQ == 0) return;
        moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .down);
        if (app.cursorPosQ < app.viewStartQ) {
            app.viewStartQ = app.cursorPosQ;
            app.viewEndQ = app.viewStartQ + window.panels.queue.validArea().ylen + 1;
        }
    } else {
        if (app.cursorPosQ >= app.queue.len - 1) return;
        moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .up);
        if (app.cursorPosQ >= app.viewEndQ) {
            app.viewEndQ = app.cursorPosQ + 1;
            app.viewStartQ = app.viewEndQ - window.panels.queue.validArea().ylen - 1;
        }
    }
    render_state.queueEffects = true;
}

fn moveCursorPos(app_dir: *u8, previous_dir: *u8, direction: cursorDirection) void {
    switch (direction) {
        .up => {
            previous_dir.* = app_dir.*;
            app_dir.* += 1;
        },
        .down => {
            previous_dir.* = app_dir.*;
            app_dir.* -= 1;
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

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

const util = @import("util.zig");
const log = util.log;
const findStringIndex = util.findStringIndex;
const wrkallocator = alloc.wrkallocator;

pub var data: state.Data = undefined;

var last_input: i64 = 0;
const release_threshold: u8 = 15;
var nloops: u8 = 0;

pub var y_len: usize = undefined;

var key_down: ?u8 = null;

// This contains shared data that will be refactored into the browser module
var tracks_from_album: []mpd.SongStringAndUri = undefined;
var albums_from_artist: []const []const u8 = undefined;

var all_albums_pos: u8 = undefined;
var all_artists_pos: u8 = undefined;
var all_songs_pos: u8 = undefined;
var all_albums_inc: usize = undefined;
var all_artists_inc: usize = undefined;
var all_songs_inc: usize = undefined;

var searchable_items: []mpd.SongStringAndUri = undefined;
var search_strings: [][]const u8 = undefined;

var modeSwitch: bool = false;

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
    const initial_state = app_state.input_state;
    switch (initial_state) {
        .normal_queue => normalQueue(char, app_state, render_state) catch unreachable,
        .typing_find => typingFind(char, app_state, render_state) catch unreachable,
        .normal_browse => handleNormalBrowse(char, app_state, render_state) catch unreachable,
        .typing_browse => typingBrowse(char, app_state, render_state) catch unreachable,
    }
    if (app_state.input_state != initial_state) {
        modeSwitch = true;
        return;
    }
    if (modeSwitch)
        modeSwitch = false;
}

pub fn handleRelease(char: u8, app_state: *state.State, render_state: *RenderState) void {
    if (app_state.input_state == .normal_browse) handleBrowseKeyRelease(char, app_state, render_state) catch unreachable;
}

// ---- State Transitions ----

fn onTypingExit(app: *state.State, render_state: *RenderState) void {
    // Reset application state
    app.typing_buffer.reset();
    app.viewable_searchable = null;
    app.input_state = .normal_queue;
    app.find_cursor_pos = 0;

    // Update rendering state
    render_state.borders = true;
    render_state.find = true;
    render_state.queueEffects = true;

    // Reset memory arenas
    _ = alloc.typingArena.reset(.retain_capacity);
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseTypingExit(app: *state.State, current: ColumnWithRender) !void {
    app.typing_buffer.reset();
    app.input_state = .normal_browse;

    current.render_col.* = true;
    current.render_cursor.* = true;

    // Reset memory arenas
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseExit(app: *state.State, render_state: *RenderState) void {
    // Update rendering state
    render_state.queueEffects = true;
    render_state.clear_browse_cursor_one = true;
    render_state.clear_browse_cursor_two = true;
    render_state.clear_browse_cursor_three = true;

    // Make sure we safely restore the column state
    if (app.column_3.type == .Tracks and app.column_1.type == .Artists) {
        revertSwitcheroo(app);
    } else {
        // Ensure safe default display state anyway
        app.column_1.type = .Select;
        app.column_1.displaying = browse_types[0..];
        app.column_1.pos = 0;
        app.column_1.slice_inc = 0;
    }

    // Reset application state
    app.input_state = .normal_queue;
    app.selected_column = .one;

    // Reset memory arenas - keep these together
    _ = alloc.typingArena.reset(.retain_capacity);
    _ = alloc.respArena.reset(.free_all);
}

// ---- Input Mode Handlers ----

fn typingFind(char: u8, app: *state.State, render_state: *RenderState) !void {
    if (modeSwitch) searchable_items = data.searchable;
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
            app.typing_buffer.append(char);
            log("typed: {s}\n", .{app.typing_buffer.typed});
            const slice = try algo.suTopNranked(
                &alloc.algoArena,
                alloc.typingAllocator,
                app.typing_buffer.typed,
                &searchable_items,
            );
            app.viewable_searchable = slice[0..];
            log("viewable string: {s}\n", .{slice[0].string});
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

const ColumnWithRender = struct {
    col: *state.BrowseColumn,
    render_col: *bool,
    render_cursor: *bool,
    clear_cursor: *bool,
};

fn handleNormalBrowse(char: u8, app: *state.State, render_state: *RenderState) !void {
    switch (char) {
        'q' => app.quit = true,
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                //this is wrong
                const current: ColumnWithRender = getCurrent(app, render_state);
                current.col.displaying = switch (current.col.type) {
                    .Albums => data.albums,
                    .Artists => data.artists,
                    else => return error.BadSearch,
                };
                onBrowseExit(app, render_state);
            }
        },
        'j' => {
            const current: ColumnWithRender = getCurrent(app, render_state);
            const next: ?ColumnWithRender = getNext(app, render_state);
            const prev: ?ColumnWithRender = getPrev(app, render_state);
            try browserScrollVertical(.down, current, next, prev, app);
        },
        'k' => {
            const current: ColumnWithRender = getCurrent(app, render_state);
            const next: ?ColumnWithRender = getNext(app, render_state);
            const prev: ?ColumnWithRender = getPrev(app, render_state);
            try browserScrollVertical(.up, current, next, prev, app);
        },
        'h' => browserNavigateLeft(app, render_state),
        'l' => browserSelectNextColumn(app, render_state),
        '/' => {
            app.input_state = .typing_browse;
            const current: ColumnWithRender = getCurrent(app, render_state);
            current.clear_cursor.* = true;
            current.render_col.* = true;
        },
        '\n', '\r' => try browserHandleEnter(app, render_state),
        else => unreachable,
    }
}

fn typingBrowse(char: u8, app: *state.State, render_state: *RenderState) !void {
    const current: ColumnWithRender = getCurrent(app, render_state);
    if (modeSwitch) {
        current.col.pos = 0;
        current.col.prev_pos = 0;
        current.col.slice_inc = 0;

        search_strings = switch (current.col.type) {
            .Albums => data.albums,
            .Artists => data.artists,
            else => return error.BadSearch,
        };
    }
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                current.col.displaying = switch (current.col.type) {
                    .Albums => data.albums,
                    .Artists => data.artists,
                    else => return error.BadSearch,
                };
                try onBrowseTypingExit(app, current);
            }
        },
        '\r', '\n' => try onBrowseTypingExit(app, current),
        else => {
            app.typing_buffer.append(char);
            log("typed: {s}\n", .{app.typing_buffer.typed});
            const best_match: []const u8 = try algo.stringBestMatch(
                &alloc.algoArena,
                alloc.typingAllocator,
                app.typing_buffer.typed,
                &search_strings,
            );

            log("best match: {s}", .{best_match});
            const index = findStringIndex(best_match, current.col.displaying);
            if (index) |unwrap| log("index: {}\n", .{unwrap});

            current.render_col.* = true;
        },
    }
}

fn getCurrent(app: *state.State, render_state: *RenderState) ColumnWithRender {
    return switch (app.selected_column) {
        .one => .{
            .col = &app.column_1,
            .render_col = &render_state.browse_one,
            .render_cursor = &render_state.browse_cursor_one,
            .clear_cursor = &render_state.clear_browse_cursor_one,
        },
        .two => .{
            .col = &app.column_2,
            .render_col = &render_state.browse_two,
            .render_cursor = &render_state.browse_cursor_two,
            .clear_cursor = &render_state.clear_browse_cursor_two,
        },
        .three => .{
            .col = &app.column_3,
            .render_col = &render_state.browse_three,
            .render_cursor = &render_state.browse_cursor_three,
            .clear_cursor = &render_state.clear_browse_cursor_three,
        },
    };
}

fn getPrev(app: *state.State, render_state: *RenderState) ?ColumnWithRender {
    return switch (app.selected_column) {
        .one => null,
        .two => .{
            .col = &app.column_1,
            .render_col = &render_state.browse_one,
            .render_cursor = &render_state.browse_cursor_one,
            .clear_cursor = &render_state.clear_browse_cursor_one,
        },
        .three => .{
            .col = &app.column_2,
            .render_col = &render_state.browse_two,
            .render_cursor = &render_state.browse_cursor_two,
            .clear_cursor = &render_state.clear_browse_cursor_two,
        },
    };
}

fn getNext(app: *state.State, render_state: *RenderState) ?ColumnWithRender {
    return switch (app.selected_column) {
        .one => .{
            .col = &app.column_2,
            .render_col = &render_state.browse_two,
            .render_cursor = &render_state.browse_cursor_two,
            .clear_cursor = &render_state.clear_browse_cursor_two,
        },
        .two => .{
            .col = &app.column_3,
            .render_col = &render_state.browse_three,
            .render_cursor = &render_state.browse_cursor_three,
            .clear_cursor = &render_state.clear_browse_cursor_three,
        },
        .three => null,
    };
}
// Browser vertical scrolling - handles all three columns in one place
fn browserScrollVertical(
    dir: cursorDirection,
    current: ColumnWithRender,
    next: ?ColumnWithRender,
    prev: ?ColumnWithRender,
    app: *state.State,
) !void {
    const max: ?u8 = if (dir == .up) null else @intCast(@min(y_len, current.col.displaying.len));
    current.col.scroll(dir, max, y_len);

    if (current.col.type == .Select) {
        // Update column 2 content based on column 1 selection
        switch (current.col.pos) {
            0 => browserSetColumn2ToAlbums(app),
            1 => browserSetColumn2ToArtists(app),
            2 => browserSetColumn2ToTracks(app),
            else => unreachable,
        }
        const next_col = next orelse return error.NextError;
        next_col.render_col.* = true;
    } else {
        //if not select, if not final, then reset the position of the next one
        if (next) |next_col| {
            if (next_col.col.pos != 0) next_col.col.pos = 0;
        }
    }

    if (prev) |prev_col| {
        if (prev_col.col.type == .Select) {
            switch (current.col.type) {
                .Albums => {
                    all_albums_pos = current.col.pos;
                    all_albums_inc = current.col.slice_inc;
                },
                .Artists => {
                    all_artists_pos = current.col.pos;
                    all_artists_inc = current.col.slice_inc;
                },
                .Tracks => {
                    all_songs_pos = current.col.pos;
                    all_songs_inc = current.col.slice_inc;
                },
                else => {},
            }
        }
    }
    current.render_col.* = true;
    current.render_cursor.* = true;
}

fn browserSetColumn2ToAlbums(app: *state.State) void {
    app.column_2.type = .Albums;
    app.column_3.type = .Artists;
    app.column_2.slice_inc = all_albums_inc;
    app.column_2.pos = all_albums_pos;
    app.column_2.displaying = data.albums;
}

fn browserSetColumn2ToArtists(app: *state.State) void {
    app.column_2.type = .Artists;
    app.column_3.type = .Albums;
    app.column_2.slice_inc = all_artists_inc;
    app.column_2.pos = all_artists_pos;
    app.column_2.displaying = data.artists;
}

fn browserSetColumn2ToTracks(app: *state.State) void {
    app.column_2.type = .Tracks;
    app.column_3.type = .None;
    app.column_2.slice_inc = all_songs_inc;
    app.column_2.pos = all_songs_pos;

    // Use a safer, persistent allocator for this long-lived data
    var titles = alloc.persistentAllocator.alloc([]const u8, data.songs.len) catch {
        log("Failed to allocate memory for song titles", .{});
        // Fallback to safer empty slice if allocation fails
        app.column_2.displaying = &[_][]const u8{};
        return;
    };

    for (data.songs, 0..) |song, i| {
        titles[i] = song.string;
    }

    app.column_2.displaying = titles;
}

// Browser left navigation - handles column dependency
fn browserNavigateLeft(app: *state.State, render_state: *RenderState) void {
    switch (app.selected_column) {
        .one => {}, // Nothing to do when already in column 1
        .two => {
            app.selected_column = .one;
            app.find_filter = mpd.Filter_Songs{
                .album = undefined,
                .artist = null,
            };
            render_state.clear_browse_cursor_two = true;
            render_state.browse_cursor_one = true;
            render_state.clear_col_three = true;
        },
        .three => {
            if (app.column_3.type == .Tracks and app.column_1.type == .Artists) {
                revertSwitcheroo(app);
                app.column_2.slice_inc = all_artists_inc;
                app.column_2.pos = all_artists_pos;
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
        },
    }
}

fn revertSwitcheroo(app: *state.State) void {
    // First ensure we have valid data in the columns
    const col1Empty = app.column_1.displaying.len == 0;
    const col2Empty = app.column_2.displaying.len == 0;

    if (col1Empty or col2Empty) {
        // Just reset to safe defaults if data is missing
        app.column_1.type = .Select;
        app.column_1.displaying = browse_types[0..];
        app.column_2.type = .Artists;
        app.column_2.displaying = data.artists;
        app.column_3.type = .None;
        app.column_3.displaying = &[_][]const u8{};
        app.column_3.pos = 0;
        return;
    }

    // Store references to current column data
    const artists = app.column_1.displaying;
    const albums = app.column_2.displaying;
    const select = browse_types[0..];

    // Reset positions
    app.column_1.slice_inc = 0;
    app.column_2.slice_inc = 0;
    app.column_3.slice_inc = 0;
    app.column_3.pos = 0;
    app.column_2.pos = 0;
    app.column_1.pos = 0;

    // Rearrange columns safely
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
    // Check for valid indices before accessing
    if (app.column_3.displaying.len == 0) {
        log("Empty column 3", .{});
        return;
    }

    const absPos = app.column_3.absolutePos();
    if (absPos >= app.column_3.displaying.len) {
        log("Invalid column 3 index", .{});
        return;
    }

    // First, clear any temporary allocations
    _ = alloc.respArena.reset(.free_all);

    // Get the album for filtering
    app.find_filter.album = app.column_3.displaying[app.column_3.absolutePos()];
    const artists = app.column_2.displaying;
    const albums = app.column_3.displaying;

    // Reset positions to known good states
    app.column_1.slice_inc = 0;
    app.column_2.slice_inc = 0;
    app.column_3.slice_inc = 0;
    app.column_3.pos = 0;
    app.column_2.pos = 0;
    app.column_1.pos = 0;

    // Rearrange columns
    app.column_1.displaying = artists;
    app.column_2.displaying = albums;
    app.column_3.type = .Tracks;
    app.column_1.type = .Artists;
    app.column_2.type = .Albums;

    // Fetch tracks from selected album
    tracks_from_album = try mpd.findTracksFromAlbum(&app.find_filter, alloc.respAllocator, alloc.persistentAllocator);

    // Create a new slice of just the titles from SongStringAndUri objects
    var titles = try alloc.persistentAllocator.alloc([]const u8, tracks_from_album.len);

    for (tracks_from_album, 0..) |song, i| {
        titles[i] = song.string;
    }

    app.column_3.displaying = titles;

    // Clear any temporary allocations again
    _ = alloc.respArena.reset(.free_all);
}

// Handle Enter key press in browser mode
fn browserHandleEnter(app: *state.State, render_state: *RenderState) !void {
    switch (app.selected_column) {
        .one => browserSelectNextColumn(app, render_state),
        .two => {
            if (app.column_2.type == .Tracks) {
                const pos = app.column_2.absolutePos();
                if (pos < data.songs.len) {
                    const uri = data.songs[pos].uri;
                    try mpd.addFromUri(alloc.typingAllocator, uri);
                }
            } else {
                browserSelectNextColumn(app, render_state);
            }
        },
        .three => {
            if (app.column_3.type == .Tracks) {
                const pos = app.column_3.absolutePos();
                if (pos < tracks_from_album.len) {
                    const uri = tracks_from_album[pos].uri;
                    try mpd.addFromUri(alloc.typingAllocator, uri);
                }
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

    // First, reset any previous allocations to avoid memory leaks
    _ = alloc.respArena.reset(.free_all);

    var next_col_display: [][]const u8 = undefined;

    switch (app.column_2.type) {
        .Albums => {
            app.find_filter.album = app.column_2.displaying[actual_index];
            log("album: {s}", .{app.find_filter.album});

            // Use respAllocator for temporary allocations
            tracks_from_album = try mpd.findTracksFromAlbum(&app.find_filter, alloc.respAllocator, alloc.persistentAllocator);

            // Create a new slice of just the titles
            // Use persistentAllocator for longer-lived data
            var titles = try alloc.persistentAllocator.alloc([]const u8, tracks_from_album.len);
            for (tracks_from_album, 0..) |song, i| {
                titles[i] = song.string;
            }
            next_col_display = titles;
        },
        .Artists => {
            app.find_filter.artist = app.column_2.displaying[actual_index];
            // Use persistentAllocator for the results since they need to live longer
            next_col_display = try mpd.findAlbumsFromArtists(app.column_2.displaying[actual_index], alloc.respAllocator, alloc.persistentAllocator);
        },
        .Tracks => return,
        else => unreachable,
    }

    // Any intermediate temp data that was allocated in respAllocator can now be freed
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

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
// const handleNormalBrowse = @import("browser.zig").handleNormalBrowse;
pub const RenderState = @import("render.zig").RenderState;

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

var all_albums_pos: u8 = undefined;
var all_artists_pos: u8 = undefined;
var all_songs_pos: u8 = undefined;
var select_pos: u8 = 0;
var all_albums_inc: usize = undefined;
var all_artists_inc: usize = undefined;
var all_songs_inc: usize = undefined;

var searchable_items: []mpd.SongStringAndUri = undefined;
var search_strings: [][]const u8 = undefined;

var modeSwitch: bool = false;
var browse_typed: bool = false;
var next_col_ready: bool = false;

var node_buffer: state.Browser = state.Browser{
    .buf = .{
        .{ .pos = 0, .slice_inc = 0, .displaying = &state.browse_types, .callback_type = null, .type = .Select },
        null,
        null,
        null,
    },
    .apex = .UNSET,
    .tracks = null,
    .find_filter = .{
        .artist = null,
        .album = null,
    },
    .index = 0,
    .len = 1,
};
var selected_column: u8 = 0;

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
    next_col_ready = true;
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

fn onBrowseTypingExit(app: *state.State, current: ColumnWithRender, render_state: *RenderState) !void {
    app.typing_buffer.reset();
    app.input_state = .normal_browse;

    if (browse_typed) render_state.borders = true;
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
        app.column_1.displaying = state.browse_types[0..];
        app.column_1.pos = 0;
        app.column_1.slice_inc = 0;
    }

    // Reset application state
    app.input_state = .normal_queue;
    app.selected_column = .one;
    node_buffer.find_filter = mpd.Filter_Songs{
        .album = undefined,
        .artist = null,
    };
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
        'j' => {
            const inc_changed = app.scroll_q.scroll(.down, app.queue.items.len);
            if (inc_changed) render_state.queue = true;
            render_state.queueEffects = true;
        },
        'k' => {
            const inc_changed = app.scroll_q.scroll(.up, app.queue.items.len);
            if (inc_changed) render_state.queue = true;
            render_state.queueEffects = true;
        },
        'g' => {
            // Go to top of queue
            app.scroll_q.pos = 0;
            app.scroll_q.slice_inc = 0;
            render_state.queue = true;
            render_state.queueEffects = true;
        },
        'G' => {
            // Go to bottom of queue
            if (app.queue.items.len > 0) {
                if (app.queue.items.len > app.scroll_q.area_height) {
                    app.scroll_q.slice_inc = app.queue.items.len - app.scroll_q.area_height;
                    app.scroll_q.pos = @intCast(app.scroll_q.area_height - 1);
                } else {
                    app.scroll_q.slice_inc = 0;
                    app.scroll_q.pos = @intCast(app.queue.items.len - 1);
                }
                render_state.queue = true;
                render_state.queueEffects = true;
            }
        },
        'd' & '\x1F' => {
            // Ctrl-d: Move down half a page (like vim)
            const half_height = app.scroll_q.area_height / 2;
            var move_down: usize = 0;

            // Determine how many positions we can move down
            if (app.scroll_q.absolutePos() + half_height < app.queue.items.len) {
                move_down = half_height;
            } else if (app.scroll_q.absolutePos() < app.queue.items.len) {
                move_down = app.queue.items.len - app.scroll_q.absolutePos() - 1;
            }

            if (move_down > 0) {
                // Try to keep cursor position in the middle of the screen when possible
                if (app.scroll_q.pos + move_down < app.scroll_q.area_height) {
                    // If we can move the cursor down without scrolling, do that
                    app.scroll_q.pos += @intCast(move_down);
                } else {
                    // Otherwise, move the slice increment (scroll the view)
                    const cursor_target: u8 = @intCast(app.scroll_q.area_height / 2);
                    if (app.scroll_q.pos > cursor_target) {
                        // Move cursor to middle position and adjust slice_inc
                        const pos_diff = app.scroll_q.pos - cursor_target;
                        app.scroll_q.slice_inc += @as(usize, pos_diff) + move_down;
                        app.scroll_q.pos = cursor_target;
                    } else {
                        // Just increase slice_inc
                        app.scroll_q.slice_inc += move_down;
                    }
                }
                render_state.queue = true;
                render_state.queueEffects = true;
            }
        },
        'u' & '\x1F' => {
            // Ctrl-u: Move up half a page (like vim)
            const half_height = app.scroll_q.area_height / 2;
            var move_up: usize = 0;

            // Determine how many positions we can move up
            if (app.scroll_q.absolutePos() >= half_height) {
                move_up = half_height;
            } else {
                move_up = app.scroll_q.absolutePos();
            }

            if (move_up > 0) {
                // First use slice_inc if available
                if (app.scroll_q.slice_inc >= move_up) {
                    app.scroll_q.slice_inc -= move_up;
                } else {
                    // Move cursor position by any remaining amount
                    const remaining = move_up - app.scroll_q.slice_inc;
                    app.scroll_q.slice_inc = 0;
                    app.scroll_q.pos -= @intCast(remaining);
                }
                render_state.queue = true;
                render_state.queueEffects = true;
            }
        },
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
            try mpd.rmFromPos(wrkallocator, app.scroll_q.absolutePos());
            // If we're deleting the last item in the queue, move cursor up
            if (app.scroll_q.absolutePos() >= app.queue.items.len - 1 and app.scroll_q.pos > 0) {
                if (app.scroll_q.slice_inc > 0)
                    app.scroll_q.slice_inc -= 1
                else
                    app.scroll_q.pos -= 1;
            }
            render_state.queueEffects = true;
        },
        'D' => {
            if (debounce()) return;
            const position: usize = app.scroll_q.absolutePos();
            try mpd.rmRangeFromPos(wrkallocator, position);

            // Always move cursor up after deleting to the end
            if (app.scroll_q.pos > 0) {
                app.scroll_q.pos -= 1;
            } else if (app.scroll_q.slice_inc > 0) {
                app.scroll_q.slice_inc -= 1;
            }

            render_state.queueEffects = true;
        },
        'X' => try mpd.clearQueue(),
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
            try mpd.playByPos(wrkallocator, app.scroll_q.absolutePos());
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

            if (escRead == 0) onBrowseExit(app, render_state);
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
        'd' & '\x1F' => try halfDown(app, render_state),
        'u' & '\x1F' => try halfUp(app, render_state),
        'g' => goTop(app, render_state),
        'G' => goBottom(app, render_state),
        'h' => browserNavigateLeft(app, render_state),
        'l' => {
            log("--L PRESS--", .{});
            log("node index {}", .{node_buffer.index});
            const node = try node_buffer.getCurrentNode();
            log("node: {}", .{node.type});
            log("selected col: {}", .{app.selected_column});
            defer {
                log("node index {}", .{node_buffer.index});
                log("selected col: {}", .{app.selected_column});
                log("length: {}", .{node_buffer.len});
            }
            const current = getCurrent(app, render_state);

            if (current.col.type == .Select) {
                const selected: state.Column_Type = switch (current.col.pos) {
                    0 => .Albums,
                    1 => .Artists,
                    2 => .Tracks,
                    else => unreachable,
                };
                node_buffer = state.Browser.init(selected, data);
            }
            if (node_buffer.index == node_buffer.len - 1) return;
            const next_ren = getNext(app, render_state);
            const next_col = if (next_ren) |next| next.col else null;
            const column_switched: bool = try node_buffer.incrementNode(current.col, next_col, &app.selected_column, 3);
            if (column_switched) {
                const prev = getPrev(app, render_state);
                const current_final = getCurrent(app, render_state);
                prev.?.clear_cursor.* = true;
                current_final.render_cursor.* = true;
            } else {
                next_ren.?.render_col.* = true;
                current.render_col.* = true;
                current.render_cursor.* = true;
            }
        },
        '/' => {
            app.input_state = .typing_browse;
            const current: ColumnWithRender = getCurrent(app, render_state);
            current.clear_cursor.* = true;
            current.render_col.* = true;
        },
        '\n', '\r' => try browserHandleEnter(app),
        else => return,
    }
}

fn halfUp(app: *state.State, render_state: *RenderState) !void {
    // Ctrl-u: Move up half the screen height (like vim)
    const current: ColumnWithRender = getCurrent(app, render_state);
    const next: ?ColumnWithRender = getNext(app, render_state);
    const prev: ?ColumnWithRender = getPrev(app, render_state);

    const half_height = y_len / 2;
    var move_up: usize = 0;

    // Determine how many positions we can move up
    if (current.col.absolutePos() >= half_height) {
        move_up = half_height;
    } else {
        move_up = current.col.absolutePos();
    }

    if (move_up > 0) {
        // First use slice_inc if available
        if (current.col.slice_inc >= move_up) {
            current.col.slice_inc -= move_up;
        } else {
            // Move cursor position by any remaining amount
            const remaining = move_up - current.col.slice_inc;
            current.col.slice_inc = 0;
            current.col.pos -= @intCast(remaining);
        }

        current.render_col.* = true;
        current.render_cursor.* = true;

        // Handle column dependencies
        try handleColumnDependencies(current, next, prev, app);
    }
}

fn halfDown(app: *state.State, render_state: *RenderState) !void {
    // Ctrl-d: Move down half the screen height (like vim)
    const current: ColumnWithRender = getCurrent(app, render_state);
    const next: ?ColumnWithRender = getNext(app, render_state);
    const prev: ?ColumnWithRender = getPrev(app, render_state);

    const half_height = y_len / 2;
    var move_down: usize = 0;

    // Determine how many positions we can move down
    if (current.col.absolutePos() + half_height < current.col.displaying.len) {
        move_down = half_height;
    } else if (current.col.absolutePos() < current.col.displaying.len) {
        move_down = current.col.displaying.len - current.col.absolutePos() - 1;
    }

    if (move_down > 0) {
        // Try to keep cursor position in the middle of the screen when possible
        if (current.col.pos + move_down < y_len) {
            // If we can move the cursor down without scrolling, do that
            current.col.pos += @intCast(move_down);
        } else {
            // Otherwise, move the slice increment (scroll the view)
            const cursor_target: u8 = @intCast(y_len / 2);
            if (current.col.pos > cursor_target) {
                // Move cursor to middle position and adjust slice_inc
                const pos_diff = current.col.pos - cursor_target;
                current.col.slice_inc += @as(usize, pos_diff) + move_down;
                current.col.pos = cursor_target;
            } else {
                // Just increase slice_inc
                current.col.slice_inc += move_down;
            }
        }

        current.render_col.* = true;
        current.render_cursor.* = true;

        // Handle column dependencies
        try handleColumnDependencies(current, next, prev, app);
    }
}

fn goTop(app: *state.State, render_state: *RenderState) void {
    // Go to top of current column
    const current: ColumnWithRender = getCurrent(app, render_state);
    current.col.pos = 0;
    current.col.slice_inc = 0;
    current.render_col.* = true;
    current.render_cursor.* = true;

    // Handle potential column dependencies
    const next: ?ColumnWithRender = getNext(app, render_state);
    if (current.col.type == .Select) {
        select_pos = current.col.pos;
        // Update column 2 based on select position
        switch (current.col.pos) {
            0 => browserSetColumn2ToAlbums(app),
            1 => browserSetColumn2ToArtists(app),
            2 => browserSetColumn2ToTracks(app),
            else => {},
        }
        if (next) |next_col| {
            next_col.render_col.* = true;
        }
    }
}

fn goBottom(app: *state.State, render_state: *RenderState) void {
    // Go to bottom of current column
    const current: ColumnWithRender = getCurrent(app, render_state);
    if (current.col.displaying.len > 0) {
        if (current.col.displaying.len > y_len) {
            current.col.slice_inc = current.col.displaying.len - y_len;
            current.col.pos = @intCast(@min(y_len - 1, current.col.displaying.len - 1));
        } else {
            current.col.slice_inc = 0;
            current.col.pos = @intCast(current.col.displaying.len - 1);
        }
        current.render_col.* = true;
        current.render_cursor.* = true;

        // Handle potential column dependencies
        const next: ?ColumnWithRender = getNext(app, render_state);
        if (current.col.type == .Select) {
            select_pos = current.col.pos;
            // Update column 2 based on select position
            switch (current.col.pos) {
                0 => browserSetColumn2ToAlbums(app),
                1 => browserSetColumn2ToArtists(app),
                2 => browserSetColumn2ToTracks(app),
                else => {},
            }
            if (next) |next_col| {
                next_col.render_col.* = true;
            }
        }
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
            .Tracks => data.song_titles,
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
                try onBrowseTypingExit(app, current, render_state);
            }
        },
        '\r', '\n' => try onBrowseTypingExit(app, current, render_state),
        else => {
            browse_typed = true;
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
            if (index) |unwrap| {
                log("index: {}\n", .{unwrap});
                // move cursor to index
                current.col.slice_inc = unwrap;
            }

            current.render_cursor.* = true;
            current.render_col.* = true;

            render_state.find = true;
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
// Helper function to handle column dependencies (used by browserScrollVertical and Ctrl-u/d)
fn handleColumnDependencies(
    current: ColumnWithRender,
    next: ?ColumnWithRender,
    prev: ?ColumnWithRender,
    app: *state.State,
) !void {
    if (current.col.type == .Select) {
        // Update column 2 content based on column 1 selection
        select_pos = current.col.pos;
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
}

// Browser vertical scrolling - handles all three columns in one place
fn browserScrollVertical(
    dir: cursorDirection,
    current: ColumnWithRender,
    next: ?ColumnWithRender,
    prev: ?ColumnWithRender,
    app: *state.State,
) !void {
    next_col_ready = false;
    const max: ?u8 = if (dir == .up) null else @intCast(@min(y_len, current.col.displaying.len));
    current.col.scroll(dir, max, y_len);

    try handleColumnDependencies(current, next, prev, app);

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
    app.column_2.displaying = data.song_titles;
}

// Browser left navigation - handles column dependency
fn browserNavigateLeft(app: *state.State, render_state: *RenderState) void {
    switch (app.selected_column) {
        .one => {}, // Nothing to do when already in column 1
        .two => {
            app.selected_column = .one;
            node_buffer.find_filter = mpd.Filter_Songs{
                .album = null,
                .artist = null,
            };
            app.column_1.pos = select_pos;
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
        app.column_1.displaying = state.browse_types[0..];
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
    const select = state.browse_types[0..];

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
fn browserNextColumn() void {}

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

// Handle Enter key press in browser mode
fn browserHandleEnter(app: *state.State) !void {
    switch (app.selected_column) {
        .one => return,
        .two => {
            switch (app.column_2.type) {
                .Tracks => {
                    const pos = app.column_2.absolutePos();
                    if (pos < data.songs.len) {
                        const uri = data.songs[pos].uri;
                        try mpd.addFromUri(alloc.typingAllocator, uri);
                    }
                },
                .Albums => {
                    const tracks = node_buffer.tracks orelse return error.NoTracks;
                    if (next_col_ready) mpd.addList(alloc.typingAllocator, tracks) catch return error.CommandFailed;
                },
                else => return,
            }
        },
        .three => {
            const tracks = node_buffer.tracks orelse return error.NoTracks;
            switch (app.column_3.type) {
                .Tracks => {
                    const pos = app.column_3.absolutePos();
                    if (pos < tracks.len) {
                        const uri = tracks[pos].uri;
                        try mpd.addFromUri(alloc.typingAllocator, uri);
                    }
                },
                .Albums => {
                    if (next_col_ready) mpd.addList(alloc.typingAllocator, tracks) catch return error.CommandFailed;
                },
                else => return,
            }
        },
    }
}

// Handle key release events specifically for the browser
fn handleBrowseKeyRelease(char: u8, app: *state.State, render_state: *RenderState) !void {
    if (node_buffer.index != 1) return;
    log("--RELEASE--", .{});
    switch (char) {
        'j', 'k', 'g', 'G', 'd' & '\x1F', 'u' & '\x1F' => {
            const current = getCurrent(app, render_state);
            switch (current.col.type) {
                .Albums => {
                    node_buffer.find_filter.album = current.col.displaying[current.col.absolutePos()];
                },
                .Artists => {
                    node_buffer.find_filter.artist = current.col.displaying[current.col.absolutePos()];
                },
                else => return,
            }
            const next_ren = getNext(app, render_state);
            const next_col = if (getNext(app, render_state)) |next| next.col else null;
            try node_buffer.setNodes(next_col, alloc.respAllocator, alloc.typingAllocator);
            if (next_ren) |next| next.render_col.* = true;
        },
        'l' => {
            const next_ren = getNext(app, render_state);
            const next_col = if (getNext(app, render_state)) |next| next.col else null;
            try node_buffer.setNodes(next_col, alloc.respAllocator, alloc.typingAllocator);
            if (next_ren) |next| next.render_col.* = true;
        },
        else => return,
    }
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

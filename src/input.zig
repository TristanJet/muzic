const std = @import("std");
const term = @import("terminal.zig");
const mpd = @import("mpdclient.zig");
const algo = @import("algo.zig");
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const window = @import("window.zig");
const mem = std.mem;
const time = std.time;
const debug = std.debug;
pub const RenderState = @import("render.zig").RenderState;

const util = @import("util.zig");
const CompareType = util.CompareType;
const findStringIndex = util.findStringIndex;
const wrkallocator = alloc.wrkallocator;
const n_browse_col = state.n_browse_columns;

var last_input: i64 = 0;
const release_threshold: u8 = 15;
var nloops: u8 = 0;

pub var y_len: usize = undefined;

var key_down: ?u8 = null;

var select_pos: u8 = 0;

var modeSwitch: bool = false;
var browse_typed: bool = false;
var next_col_ready: bool = false;
const initial_browser: state.Browser = state.Browser{
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

var node_buffer: state.Browser = initial_browser;
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

// Should this be the way it is??? WHy am I only reading one byte at a time??????
pub fn checkInputEvent() !?state.Event {
    var buffer: [1]u8 = undefined;
    const bytes_read: usize = try term.readBytes(&buffer);
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

pub fn handleInput(char: u8, app_state: *state.State, render_state: *RenderState(state.n_browse_columns), mpd_data: *state.Data) void {
    const initial_state = app_state.input_state;
    switch (initial_state) {
        .normal_queue => normalQueue(char, app_state, render_state, mpd_data) catch unreachable,
        .typing_find => typingFind(char, app_state, render_state) catch unreachable,
        .normal_browse => handleNormalBrowse(char, app_state, render_state, mpd_data) catch unreachable,
        .typing_browse => typingBrowse(char, app_state, render_state) catch unreachable,
    }
    if (app_state.input_state != initial_state) {
        modeSwitch = true;
        return;
    }
    if (modeSwitch)
        modeSwitch = false;
}

pub fn handleRelease(char: u8, app_state: *state.State, render_state: *RenderState(state.n_browse_columns)) void {
    if (app_state.input_state == .normal_browse) handleBrowseKeyRelease(char, app_state, render_state) catch unreachable;
    next_col_ready = true;
}

// ---- State Transitions ----

fn onTypingExit(app: *state.State, render_state: *RenderState(state.n_browse_columns)) void {
    // Reset application state
    app.typing_buffer.reset();
    app.viewable_searchable = null;
    app.input_state = .normal_queue;
    app.find_cursor_pos = 0;

    // Update rendering state
    render_state.borders = true;
    render_state.find_clear = true;
    render_state.queueEffects = true;

    // Reset memory arenas
    _ = alloc.typingArena.reset(.retain_capacity);
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseTypingExit(app: *state.State, current: *state.BrowseColumn, render_state: *RenderState(state.n_browse_columns)) !void {
    app.typing_buffer.reset();
    app.input_state = .normal_browse;

    if (browse_typed) render_state.borders = true;
    current.render(render_state);
    current.renderCursor(render_state);

    // Reset memory arenas
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseExit(app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    // Update rendering state
    render_state.queueEffects = true;
    render_state.browse_clear_cursor[app.col_arr.index] = true;

    // Reset application state
    app.input_state = .normal_queue;
    // Reset memory arenas - keep these together
    var resp: bool = undefined;
    resp = alloc.typingArena.reset(.retain_capacity);
    if (!resp) return error.AllocatorFail;
    resp = alloc.respArena.reset(.free_all);
    if (!resp) return error.AllocatorFail;
}

// ---- Input Mode Handlers ----

fn typingFind(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) onTypingExit(app, render_state);
        },
        'n' & '\x1F' => {
            scroll(&app.find_cursor_pos, &app.find_cursor_prev, app.viewable_searchable.?.len - 1, .down);
            render_state.find_cursor = true;
        },
        'p' & '\x1F' => {
            scroll(&app.find_cursor_pos, &app.find_cursor_prev, null, .up);
            render_state.find_cursor = true;
        },
        '\r', '\n' => {
            const addUri = app.viewable_searchable.?[app.find_cursor_pos].uri;
            try mpd.addFromUri(wrkallocator, addUri);
            onTypingExit(app, render_state);
        },
        '\x7F' => {
            app.typing_buffer.pop() catch return;
            // if (searchable_items) |_| {
            //     app.viewable_searchable = try algo.suTopNranked(
            //         alloc.typingAllocator,
            //         app.typing_buffer.typed,
            //         &searchable_items.?,
            //     );
            // } else return;
            render_state.find_cursor = true;
            render_state.find = true;
        },
        else => {
            app.typing_buffer.append(char) catch return;
            app.viewable_searchable = try algo.suTopNranked(app.typing_buffer.typed, &app.search_sample_su);
            render_state.find_cursor = true;
            render_state.find = true;
        },
    }
}

fn normalQueue(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns), mpd_data: *state.Data) !void {
    switch (char) {
        'q' => app.quit = true,
        'j' => {
            const inc_changed = app.scroll_q.scroll(.down);
            if (inc_changed) {
                try app.queue.scroll(alloc.respAllocator, .down, &app.scroll_q.inc, app.scroll_q.pos);
                render_state.queue = true;
            }
            render_state.queueEffects = true;
        },
        'k' => {
            const inc_changed = app.scroll_q.scroll(.up);
            if (inc_changed) {
                try app.queue.scroll(alloc.respAllocator, .up, &app.scroll_q.inc, app.scroll_q.pos);
                render_state.queue = true;
            }
            render_state.queueEffects = true;
        },
        'g' => {
            const inc_changed = app.scroll_q.jumpTop();
            if (inc_changed) render_state.queue = true;
            render_state.queueEffects = true;
        },
        'G' => {
            const inc_changed = app.scroll_q.jumpBottom(app.queue.pl_len);
            if (inc_changed) render_state.queue = true;
            render_state.queueEffects = true;
        },
        'd' & '\x1F' => {
            // Ctrl-d: Move down half a page (like vim)
            const half_height = app.scroll_q.area_height / 2;
            var move_down: usize = 0;

            // Determine how many positions we can move down
            if (app.scroll_q.absolutePos() + half_height < app.queue.pl_len) {
                move_down = half_height;
            } else if (app.scroll_q.absolutePos() < app.queue.pl_len) {
                move_down = app.queue.pl_len - app.scroll_q.absolutePos() - 1;
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
                        app.scroll_q.inc += @as(usize, pos_diff) + move_down;
                        app.scroll_q.pos = cursor_target;
                    } else {
                        // Just increase slice_inc
                        app.scroll_q.inc += move_down;
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
                if (app.scroll_q.inc >= move_up) {
                    app.scroll_q.inc -= move_up;
                } else {
                    // Move cursor position by any remaining amount
                    const remaining = move_up - app.scroll_q.inc;
                    app.scroll_q.inc = 0;
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
            mpd.nextSong() catch |e| {
                switch (e) {
                    error.MpdError => return,
                    else => return e,
                }
            };
        },
        'h' => {
            if (debounce()) return;
            if (app.song.time.elapsed < 5) {
                mpd.prevSong() catch |e| {
                    switch (e) {
                        error.MpdError => return,
                        else => return e,
                    }
                };
            } else {
                try mpd.playById(wrkallocator, app.song.id);
            }
        },
        'f' => {
            _ = try mpd_data.init(.searchable);
            const searchable = mpd_data.searchable orelse return;
            const uppers = mpd_data.searchable_lower orelse return;
            if (!app.algo_init) try algo.init(window.panels.find.validArea().ylen, searchable.len);
            try app.search_sample_su.update(searchable, uppers);
            app.input_state = .typing_find;
            render_state.find = true;
            render_state.queue = true;
        },
        'b' => {
            const data_init = try mpd_data.init(.albums);
            if (data_init) {
                if (app.col_arr.getNext()) |next| next.displaying = mpd_data.albums;
            }
            app.input_state = .normal_browse;
            app.node_switched = true;
            render_state.browse_cursor[app.col_arr.index] = true;
            render_state.browse_col[0] = true;
            render_state.browse_col[1] = true;
            render_state.browse_col[2] = true;
            render_state.find = true;
            render_state.queue = true;
        },
        'x' => {
            if (debounce()) return;
            mpd.rmFromPos(wrkallocator, app.scroll_q.absolutePos()) catch |e| switch (e) {
                error.MpdNotPlaying => return,
                error.MpdBadIndex => {
                    if (app.queue.pl_len == 0) return;
                    return error.MpdError;
                },
                else => return e,
            };
            // If we're deleting the last item in the queue, move cursor up
            if (app.queue.pl_len == 0) return;
            if (app.scroll_q.absolutePos() >= app.queue.pl_len - 1 and app.scroll_q.pos > 0) {
                if (app.scroll_q.inc > 0)
                    app.scroll_q.inc -= 1
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
            } else if (app.scroll_q.inc > 0) {
                app.scroll_q.inc -= 1;
            }

            render_state.queueEffects = true;
        },
        'X' => {
            try mpd.clearQueue();
            app.scroll_q.inc = 0;
            app.scroll_q.pos = 0;
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
                //right
                if (debounce()) return;
                try mpd.seek(.forward, 5);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[D")) {
                //left
                if (debounce()) return;
                try mpd.seek(.backward, 5);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[1;2C")) {
                //Shift right
                try mpd.seek(.forward, 15);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[1;2D")) {
                //Shift left
                try mpd.seek(.backward, 15);
            }
        },
        '\n', '\r' => {
            if (debounce()) return;
            mpd.playByPos(wrkallocator, app.scroll_q.absolutePos()) catch |e| switch (e) {
                error.MpdBadIndex => {
                    if (app.queue.pl_len == 0) return;
                    return error.MpdError;
                },
                else => return e,
            };
            if (!app.isPlaying) app.isPlaying = true;
        },
        else => {},
    }
}

// ---- Browser Module ----
fn handleNormalBrowse(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns), mpd_data: *state.Data) !void {
    switch (char) {
        'q' => app.quit = true,
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) try onBrowseExit(app, render_state);
        },
        'j' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            const next: ?*state.BrowseColumn = app.col_arr.getNext();
            const scrolled = &app.current_scrolled;
            const reset = try browserScrollVertical(.down, current, next, scrolled, mpd_data);
            if (reset) {
                try resetBrowser(next);
                app.col_arr.clear(render_state);
                for (1..app.col_arr.len) |i| {
                    app.col_arr.buf[i].render(render_state);
                }
                app.col_arr.buf[0].renderCursor(render_state);
            } else {
                if (scrolled.*) current.render(render_state);
                current.renderCursor(render_state);
                if (next) |col| col.render(render_state);
            }
        },
        'k' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            const next: ?*state.BrowseColumn = app.col_arr.getNext();
            const scrolled = &app.current_scrolled;
            const reset = try browserScrollVertical(.up, current, next, scrolled, mpd_data);
            if (reset) {
                try resetBrowser(next);
                app.col_arr.clear(render_state);
                for (1..app.col_arr.len) |i| {
                    app.col_arr.buf[i].render(render_state);
                }
                app.col_arr.buf[0].renderCursor(render_state);
            } else {
                if (scrolled.*) current.render(render_state);
                current.renderCursor(render_state);
                if (next) |col| col.render(render_state);
            }
        },
        'd' & '\x1F' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            try halfDown(current);
            current.render(render_state);
            current.renderCursor(render_state);
        },
        'u' & '\x1F' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            try halfUp(current);
            current.render(render_state);
            current.renderCursor(render_state);
        },
        'g' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            current.setPos(0, 0);
            current.render(render_state);
            current.renderCursor(render_state);
        },
        'G' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            try goBottom(current);
            current.render(render_state);
            current.renderCursor(render_state);
        },
        'h' => {
            const initial = app.col_arr.getCurrent();
            const current_node = try node_buffer.getCurrentNode();
            if (current_node.type == .Select) return;

            const prev_col = app.col_arr.getPrev();
            const next_col = app.col_arr.getNext();
            const col_switched: bool = try node_buffer.decrementNode(&app.col_arr);
            app.node_switched = true;
            const prev = prev_col orelse return error.NoPrev;
            if (col_switched) {
                initial.clearCursor(render_state);
                prev.renderCursor(render_state);
            } else {
                initial.clear(render_state);
                initial.render(render_state);
                initial.renderCursor(render_state);
                const next = next_col orelse return error.NoNext;
                next.clear(render_state);
                next.render(render_state);
                prev.clear(render_state);
                prev.render(render_state);
            }
        },
        'l' => {
            if (!next_col_ready) return;
            const node = try node_buffer.getCurrentNode();
            const initial: *state.BrowseColumn = app.col_arr.getCurrent();

            if (node.type == .Select and node_buffer.apex == .UNSET) {
                switch (initial.pos) {
                    0 => {
                        const albums = mpd_data.albums orelse return;
                        node_buffer = state.Browser.apexAlbums(albums);
                    },
                    1 => {
                        const artists = mpd_data.artists orelse return;
                        node_buffer = state.Browser.apexArtists(artists);
                    },
                    2 => {
                        const titles = mpd_data.song_titles orelse return;
                        const songs = mpd_data.songs orelse return;
                        node_buffer = state.Browser.apexTracks(songs, titles);
                    },
                    else => unreachable,
                }
            }
            if (node_buffer.index == node_buffer.len - 1) return;
            const next_col = app.col_arr.getNext();
            const prev_col = app.col_arr.getPrev();
            const column_switched: bool = try node_buffer.incrementNode(&app.col_arr);
            app.node_switched = true;
            const next = next_col orelse return error.NoNext;
            if (column_switched) {
                initial.clearCursor(render_state);
                next.renderCursor(render_state);
            } else {
                const prev = prev_col orelse return error.NoPrev;
                prev.clear(render_state);
                prev.render(render_state);
                initial.clear(render_state);
                initial.render(render_state);
                next.clear(render_state);
                next.render(render_state);
                initial.renderCursor(render_state);
            }
            if (node_buffer.index == 1) next_col_ready = false;
        },
        '/' => {
            const node = try node_buffer.getCurrentNode();
            if (node.type == .Select) return;
            app.input_state = .typing_browse;
            const curr_col = app.col_arr.getCurrent();
            try switchToTyping(node.type, node_buffer.apex, curr_col, mpd_data, &app.search_sample_str);
            curr_col.render(render_state);
            curr_col.clearCursor(render_state);
        },
        '\n', '\r' => {
            const curr_col = app.col_arr.getCurrent();
            try browserHandleEnter(alloc.typingAllocator, curr_col.absolutePos(), mpd_data);
        },
        ' ' => {
            util.log("SPACE PRESSED !!", .{});
            const curr_col = app.col_arr.getCurrent();
            try browserHandleSpace(alloc.typingAllocator, curr_col.absolutePos(), mpd_data);
        },
        else => return,
    }
}

fn switchToTyping(
    node_type: state.Column_Type,
    apex: state.NodeApex,
    col: *const state.BrowseColumn,
    data: *const state.Data,
    search_sample: *algo.SearchSample([]const u8),
) !void {
    // This is a very fragile solution
    if (@intFromEnum(apex) == @intFromEnum(node_type)) {
        var set: []const []const u8 = undefined;
        var uppers: []const []const u16 = undefined;
        switch (apex) {
            .Albums => {
                set = data.albums orelse return;
                uppers = data.albums_lower orelse return;
            },
            .Artists => {
                set = data.artists orelse return;
                uppers = data.artists_lower orelse return;
            },
            .Tracks => {
                set = data.song_titles orelse return;
                uppers = data.songs_lower orelse return;
            },
            else => unreachable,
        }
        try search_sample.update(set, uppers);
    } else {
        const disp = col.displaying orelse return error.NoDisplaying;
        try search_sample.update(disp, null);
    }
}

fn resetBrowser(next: ?*state.BrowseColumn) !void {
    if (next) |col| col.setPos(0, 0);
    node_buffer = initial_browser;
    var resp: bool = undefined;
    resp = alloc.browserArena.reset(.retain_capacity);
    if (!resp) return error.AllocatorError;
}

fn halfUp(current: *state.BrowseColumn) !void {
    if (current.displaying == null) return;
    // Ctrl-u: Move up half the screen height (like vim)
    const half_height = y_len / 2;
    var move_up: usize = 0;

    // Determine how many positions we can move up
    if (current.absolutePos() >= half_height) {
        move_up = half_height;
    } else {
        move_up = current.absolutePos();
    }

    if (move_up > 0) {
        // First use slice_inc if available
        if (current.slice_inc >= move_up) {
            current.slice_inc -= move_up;
        } else {
            // Move cursor position by any remaining amount
            const remaining = move_up - current.slice_inc;
            current.slice_inc = 0;
            current.pos -= @intCast(remaining);
        }
    }
}

fn halfDown(current: *state.BrowseColumn) !void {
    const displaying = current.displaying orelse return;
    // Ctrl-d: Move down half the screen height (like vim)
    const half_height = y_len / 2;
    var move_down: usize = 0;

    // Determine how many positions we can move down
    if (current.absolutePos() + half_height < displaying.len) {
        move_down = half_height;
    } else if (current.absolutePos() < displaying.len) {
        move_down = displaying.len - current.absolutePos() - 1;
    }

    if (move_down > 0) {
        // Try to keep cursor position in the middle of the screen when possible
        if (current.pos + move_down < y_len) {
            // If we can move the cursor down without scrolling, do that
            current.pos += @intCast(move_down);
        } else {
            // Otherwise, move the slice increment (scroll the view)
            const cursor_target: u8 = @intCast(y_len / 2);
            if (current.pos > cursor_target) {
                // Move cursor to middle position and adjust slice_inc
                const pos_diff = current.pos - cursor_target;
                current.slice_inc += @as(usize, pos_diff) + move_down;
                current.pos = cursor_target;
            } else {
                // Just increase slice_inc
                current.slice_inc += move_down;
            }
        }
    }
}

fn goBottom(current: *state.BrowseColumn) !void {
    const displaying = current.displaying orelse return;
    // Go to bottom of current column
    if (displaying.len > 0) {
        if (displaying.len > y_len) {
            current.slice_inc = displaying.len - y_len;
            current.pos = @intCast(@min(y_len - 1, displaying.len - 1));
        } else {
            current.slice_inc = 0;
            current.pos = @intCast(displaying.len - 1);
        }
    }
}

// fn switchToTyping(curr_col: *state.BrowseColumn) !void {
//     const displaying = curr_col.displaying orelse return error.NoDisplaying;
//     search_strings = try getSearchStrings(displaying, alloc.browserAllocator);
// }

fn typingBrowse(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                const current = app.col_arr.getCurrent();
                try onBrowseTypingExit(app, current, render_state);
            }
        },
        '\r', '\n' => {
            const current = app.col_arr.getCurrent();
            try onBrowseTypingExit(app, current, render_state);
        },
        '\x7F' => {
            util.log("Backspace!!", .{});
            app.typing_buffer.pop() catch return;
            browse_typed = true;
            const current = app.col_arr.getCurrent();
            // const displaying = current.displaying orelse return;
            // const best_match: ?[]const u8 = try algo.stringBestMatch(
            //     alloc.typingAllocator,
            //     app.typing_buffer.typed,
            //     &search_strings,
            // );
            // if (best_match) |best| {
            //     const compare_type: CompareType = if (node_buffer.index == 1) .binary else .linear; // doesn't need to be computed on input
            //     const index = findStringIndex(best, displaying, compare_type);
            //     if (index) |unwrap| moveToIndex(unwrap, current, displaying, window.panels.find.validArea().ylen);
            // }
            current.renderCursor(render_state);
            current.render(render_state);
            render_state.find = true;
        },
        else => {
            app.typing_buffer.append(char) catch return;
            const current = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;
            browse_typed = true;
            const best_match: ?[]const u8 = try algo.stringBestMatch(app.typing_buffer.typed, &app.search_sample_str);
            if (best_match) |best| {
                util.log("best match: {s}", .{best});
                const compare_type: CompareType = if (node_buffer.index == 1) .binary else .linear; // doesn't need to be computed on input
                const index = findStringIndex(best, app.search_sample_str.set, app.search_sample_str.uppers, compare_type) orelse return error.NotFound;
                moveToIndex(index, current, displaying, window.panels.find.validArea().ylen);
            }
            current.renderCursor(render_state);
            current.render(render_state);
            render_state.find = true;
        },
    }
}

fn moveToIndex(index: usize, col: *state.BrowseColumn, displaying: []const []const u8, ylen: usize) void {
    if (ylen >= displaying.len) {
        col.pos = @intCast(index);
        return;
    }
    col.setPos(0, index);
}

// Browser vertical scrolling - handles all three columns in one place
fn browserScrollVertical(dir: cursorDirection, current: *state.BrowseColumn, next: ?*state.BrowseColumn, scrolled: *bool, mpd_data: *state.Data) !bool {
    const displaying = current.displaying orelse return false;
    next_col_ready = false;
    const max: ?u8 = if (dir == .up) null else @intCast(@min(y_len, displaying.len));
    scrolled.* = try current.scroll(dir, max, y_len);

    const curr_node = try node_buffer.getCurrentNode();
    if (curr_node.type == .Select) {
        if (next) |col| {
            switch (current.pos) {
                0 => {
                    col.displaying = mpd_data.albums;
                },
                1 => {
                    _ = try mpd_data.init(.artists);
                    col.displaying = mpd_data.artists;
                },
                2 => {
                    _ = try mpd_data.init(.songs);
                    col.displaying = mpd_data.song_titles;
                },
                else => unreachable,
            }
        }
        if (node_buffer.apex != .UNSET) return true;
    }
    try node_buffer.zeroForward();
    return false;
}

// Handle Enter key press in browser mode
// dependency only needed in one branch
fn browserHandleEnter(allocator: mem.Allocator, abs_pos: usize, mpd_data: *const state.Data) !void {
    const curr_node = try node_buffer.getCurrentNode();
    switch (curr_node.type) {
        .Tracks => {
            if (node_buffer.apex == .Tracks) {
                const songs = mpd_data.songs orelse return error.NoSongs;
                if (abs_pos < songs.len) {
                    const uri = songs[abs_pos].uri;
                    mpd.addFromUri(allocator, uri) catch return error.CommandFailed;
                    return;
                } else return error.OutOfBounds;
            }
            const tracks = node_buffer.tracks orelse return error.NoTracks;
            if (abs_pos < tracks.len) {
                const uri = tracks[abs_pos].uri;
                mpd.addFromUri(allocator, uri) catch return error.CommandFailed;
            } else return error.OutOfBounds;
        },
        .Albums => {
            const tracks = node_buffer.tracks orelse return error.NoTracks;
            if (next_col_ready) mpd.addList(allocator, tracks) catch return error.CommandFailed;
        },
        .Artists => {
            const artist = mpd_data.artists.?[abs_pos];
            try mpd.addAllFromArtist(allocator, artist);
        },
        else => return,
    }
}

fn browserHandleSpace(allocator: mem.Allocator, abs_pos: usize, mpd_data: *const state.Data) !void {
    const curr_node = try node_buffer.getCurrentNode();
    switch (curr_node.type) {
        .Tracks => {
            if (node_buffer.apex == .Tracks) {
                const songs = mpd_data.songs orelse return error.NoSongs;
                if (abs_pos < songs.len) {
                    const uri = songs[abs_pos].uri;
                    mpd.clearQueue() catch return error.CommandFailed;
                    mpd.addFromUri(allocator, uri) catch return error.CommandFailed;
                    try mpd.playByPos(allocator, 0);
                    return;
                } else return error.OutOfBounds;
            }
            const tracks = node_buffer.tracks orelse return error.NoTracks;
            if (abs_pos < tracks.len) {
                const uri = tracks[abs_pos].uri;
                mpd.clearQueue() catch return error.CommandFailed;
                mpd.addFromUri(allocator, uri) catch return error.CommandFailed;
                try mpd.playByPos(allocator, 0);
            } else return error.OutOfBounds;
        },
        .Albums => {
            const tracks = node_buffer.tracks orelse return error.NoTracks;
            if (next_col_ready) {
                mpd.clearQueue() catch return error.CommandFailed;
                mpd.addList(allocator, tracks) catch return error.CommandFailed;
                try mpd.playByPos(allocator, 0);
            }
        },
        .Artists => {
            mpd.clearQueue() catch return error.CommandFailed;
            const artist = mpd_data.artists.?[abs_pos];
            mpd.addAllFromArtist(allocator, artist) catch return error.CommandFailed;
            try mpd.playByPos(allocator, 0);
        },
        else => return,
    }
}

// Handle key release events specifically for the browser
fn handleBrowseKeyRelease(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    switch (char) {
        'j', 'k', 'g', 'G', 'd' & '\x1F', 'u' & '\x1F', '\n', '\r' => {
            if (node_buffer.index == 0) return;
            const curr_node = try node_buffer.getCurrentNode();
            const curr_col = app.col_arr.getCurrent();
            const displaying = curr_col.displaying orelse return;
            switch (curr_node.type) {
                .Albums => {
                    node_buffer.find_filter.album = displaying[curr_col.absolutePos()];
                },
                .Artists => {
                    node_buffer.find_filter.artist = displaying[curr_col.absolutePos()];
                },
                else => return,
            }
            const resp = try node_buffer.setNodes(&app.col_arr, alloc.respAllocator, alloc.browserAllocator);
            if (!resp) return;
            const next_col = app.col_arr.getNext();
            if (next_col) |next| {
                util.log("next display: {s}", .{next.displaying.?});
                next.clear(render_state);
                next.render(render_state);
            }
        },
        'l' => {
            const resp = node_buffer.setNodes(&app.col_arr, alloc.respAllocator, alloc.browserAllocator) catch |e| {
                switch (e) {
                    // error.UnsetApex => {
                    //     util.log("uset apex!!!", .{});
                    //     return;
                    // },
                    error.UnsetApex => return,
                    else => return error.NodeError,
                }
            };
            if (!resp) return;
            const next_col = app.col_arr.getNext();
            if (next_col) |next| {
                next.clear(render_state);
                next.render(render_state);
            }
        },
        else => return,
    }
}

// ---- Utility Functions ----

fn getSearchStrings(strings: []const []const u8, allocator: mem.Allocator) ![][]const u8 {
    var return_strings: [][]const u8 = try allocator.alloc([]const u8, strings.len);
    for (strings, 0..) |string, i| {
        return_strings[i] = string;
    }
    return return_strings;
}
fn debounce() bool {
    //input debounce
    const app_time = time.milliTimestamp();
    const diff = app_time - last_input;
    if (diff < 150) {
        return true;
    }
    last_input = app_time;
    return false;
}

fn scroll(cursor_pos: *u8, cursor_prev: *u8, max: ?usize, dir: cursorDirection) void {
    cursor_prev.* = cursor_pos.*;
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

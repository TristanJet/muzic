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
const release_threshold: u8 = 5;
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
    visual_queue,
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
        .visual_queue => visualQueue(char, app_state, render_state) catch unreachable,
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
    app.search_state.reset();

    // Update rendering state
    render_state.borders = true;
    render_state.find_clear = true;
    render_state.browse_col[0] = true;
    render_state.browse_col[1] = true;
    render_state.browse_col[2] = true;
    render_state.queueEffects = true;

    // Reset memory arenas
    _ = alloc.typingArena.reset(.retain_capacity);
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseTypingExit(app: *state.State, current: *state.BrowseColumn, render_state: *RenderState(state.n_browse_columns)) !void {
    app.typing_buffer.reset();
    app.input_state = .normal_browse;
    app.search_state.reset();

    if (browse_typed) render_state.borders = true;
    current.render(render_state);
    current.renderCursor(render_state);

    // Reset memory arenas
    _ = alloc.algoArena.reset(.free_all);
}

fn onBrowseExit(app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    render_state.queueEffects = true;
    render_state.browse_clear_cursor[app.col_arr.index] = true;
    app.n_str_matches = 0;

    app.input_state = .normal_queue;

    var resp: bool = undefined;
    resp = alloc.typingArena.reset(.retain_capacity);
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
            const previ = app.search_state.isearch.pop() orelse return;
            app.search_sample_su.indices = std.ArrayList(usize).fromOwnedSlice(alloc.persistentAllocator, @constCast(previ));
            const imatches = app.search_state.imatch.pop() orelse return;
            util.log("imatch 0: {}", .{imatches[0]});
            const n = app.search_sample_su.itemsFromIndices(imatches, app.find_matches);
            util.log("best match: {s}", .{app.find_matches[0].string});

            app.viewable_searchable = app.find_matches[0..n];
            render_state.find_cursor = true;
            render_state.find = true;
        },
        else => {
            if (app.search_sample_su.indices.items.len == 0) return;
            app.typing_buffer.append(char) catch return;

            try app.search_state.isearch.append(try app.search_state.dupe(app.search_sample_su.indices.items));
            const imatches = try algo.stringUriBest(app.typing_buffer.typed, &app.search_sample_su, window.panels.find.validArea().ylen);
            util.log("imatch 0: {}", .{imatches[0]});
            try app.search_state.imatch.append(try app.search_state.dupe(imatches));
            const n = app.search_sample_su.itemsFromIndices(imatches, app.find_matches);
            util.log("best match: {s}", .{app.find_matches[0].string});

            app.viewable_searchable = app.find_matches[0..n];
            render_state.find_cursor = true;
            render_state.find = true;
        },
    }
}

fn normalQueue(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns), mpd_data: *state.Data) !void {
    switch (char) {
        'q' => app.quit = true,
        'b' => {
            const data_init = try mpd_data.init(.albums);
            if (data_init) {
                if (app.col_arr.getNext()) |next| next.displaying = mpd_data.albums;
                render_state.browse_col[1] = true;
            }
            app.input_state = .normal_browse;
            app.node_switched = true;
            render_state.browse_cursor[app.col_arr.index] = true;
        },
        'f' => {
            try onFind(render_state, mpd_data, &app.algo_init, &app.search_sample_su, &app.input_state);
        },
        else => if (app.queue.pl_len == 0) return,
    }
    switch (char) {
        'j' => try queueScrollDown(app, render_state),
        'k' => try queueScrollUp(app, render_state),
        'd' & '\x1F' => try queueHalfDown(app, render_state),
        'u' & '\x1F' => try queueHalfUp(app, render_state),
        'g' => goTop(app, render_state),
        'G' => goBottom(app, render_state),
        ' ' => {
            if (debounce()) return;
            app.isPlaying = try mpd.togglePlaystate(app.isPlaying);
        },
        'p' => {
            if (debounce()) return;
            const pos = app.queue.itopviewport + app.scroll_q.pos;
            try mpd.batchInsertUri(app.yanked.refs.items, pos, alloc.respAllocator);
            app.jumppos = app.queue.itopviewport + app.scroll_q.pos + app.yanked.refs.items.len;
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
        'x' => {
            if (debounce()) return;
            const position: usize = app.scroll_q.pos + app.queue.itopviewport;
            try mpd.getYanked(position, position + 1, &app.yanked, alloc.respAllocator);
            mpd.rmFromPos(wrkallocator, position) catch |e| switch (e) {
                error.MpdNotPlaying => return,
                error.MpdBadIndex => {
                    if (app.queue.pl_len == 0) return;
                    return error.MpdError;
                },
                else => return e,
            };
            // If we're deleting the last item in the queue, move cursor up
            if (app.queue.pl_len == 0) return;
            if (app.scroll_q.pos + app.queue.itopviewport >= app.queue.pl_len - 1 and app.scroll_q.pos > 0) {
                if (app.scroll_q.inc > 0)
                    app.scroll_q.inc -= 1
                else
                    app.scroll_q.pos -= 1;
            }
            render_state.queueEffects = true;
        },
        'D' => {
            if (debounce()) return;
            const position: usize = app.scroll_q.pos + app.queue.itopviewport;
            try mpd.getYanked(position, app.queue.pl_len, &app.yanked, alloc.respAllocator);
            try mpd.rmRange(position, app.queue.pl_len, alloc.respAllocator);

            render_state.queueEffects = true;
        },
        'y' => {
            if (debounce()) return;
            const position: usize = app.scroll_q.pos + app.queue.itopviewport;
            try mpd.getYanked(position, position + 1, &app.yanked, alloc.respAllocator);

            render_state.queueEffects = true;
        },
        'Y' => {
            if (debounce()) return;
            const position: usize = app.scroll_q.pos + app.queue.itopviewport;
            try mpd.getYanked(position, app.queue.pl_len, &app.yanked, alloc.respAllocator);

            render_state.queueEffects = true;
        },
        'X' => {
            try mpd.getYanked(0, app.queue.pl_len, &app.yanked, alloc.respAllocator);
            try mpd.clearQueue();
            app.scroll_q.inc = 0;
            app.scroll_q.pos = 0;
        },
        'v' => {
            app.input_state = .visual_queue;
            app.visual_anchor_pos = app.queue.itopviewport + app.scroll_q.pos;
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
            mpd.playByPos(wrkallocator, app.scroll_q.pos + app.queue.itopviewport) catch |e| switch (e) {
                error.MpdBadIndex => {
                    if (app.queue.pl_len == 0) return;
                    return error.MpdError;
                },
                else => return e,
            };
            if (!app.isPlaying) app.isPlaying = true;
        },
        else => return,
    }
}

fn scrollHalfDown(
    screen_pos: u8,
    wheight: u8,
    len: usize,
    itop: usize,
) struct { u8, usize } {
    if (screen_pos + itop == len - 1) return .{ screen_pos, itop };
    const half_height: u8 = wheight / 2;

    if (len < wheight) {
        const lencast: u8 = @intCast(len);
        return .{ @min(screen_pos + half_height, lencast - 1), itop };
    }

    if (screen_pos == 0) return .{ half_height, itop };

    const newitop = @min(itop + screen_pos, len - wheight);
    const leftover: u8 = @intCast((itop + screen_pos) - newitop);

    return .{ @min(half_height + leftover, wheight - 1), newitop };
}

fn scrollHalfUp(
    screen_pos: u8,
    wheight: u8,
    len: usize,
    itop: usize,
) struct { u8, usize } {
    if (screen_pos + itop == 0) return .{ screen_pos, itop };
    const half_height: u8 = wheight / 2;

    if (len < wheight) {
        return .{ screen_pos -| half_height, itop };
    }

    const delta = @abs(@as(i16, screen_pos) - wheight);
    const newitop = itop -| delta;
    const leftover: u8 = @intCast(delta - (itop - newitop));

    return .{ half_height -| leftover, newitop };
}

fn visualQueue(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                exitVisual(&app.visual_anchor_pos, &app.input_state, render_state);
            }
        },
        'v' => exitVisual(&app.visual_anchor_pos, &app.input_state, render_state),
        'j' => try queueScrollDown(app, render_state),
        'k' => try queueScrollUp(app, render_state),
        'd' & '\x1F' => try queueHalfDown(app, render_state),
        'u' & '\x1F' => try queueHalfUp(app, render_state),
        'g' => goTop(app, render_state),
        'G' => goBottom(app, render_state),
        'd' => {
            if (app.visual_anchor_pos) |anchor| {
                app.jumppos = try deleteVisual(app.queue.itopviewport + app.scroll_q.pos, anchor, &app.yanked, alloc.respAllocator);
            }

            app.visual_anchor_pos = null;
            app.input_state = .normal_queue;
        },
        'x' => {
            if (app.visual_anchor_pos) |anchor| {
                app.jumppos = try deleteVisual(app.queue.itopviewport + app.scroll_q.pos, anchor, &app.yanked, alloc.respAllocator);
            }

            app.visual_anchor_pos = null;
            app.input_state = .normal_queue;
        },
        'y' => {
            if (app.visual_anchor_pos) |anchor| {
                app.jumppos = try yankVisual(app.queue.itopviewport + app.scroll_q.pos, anchor, &app.yanked, alloc.respAllocator);
            }

            render_state.queue = true;
            app.visual_anchor_pos = null;
            app.input_state = .normal_queue;
        },
        else => return,
    }
}

fn exitVisual(anchor: *?usize, input: *Input_State, render_state: *RenderState(n_browse_col)) void {
    anchor.* = null;
    input.* = .normal_queue;
    render_state.queue = true;
}

fn deleteVisual(abspos: usize, anchor: usize, yanked: *mpd.Yanked, ra: mem.Allocator) !usize {
    const start = @min(abspos, anchor);
    const end = @max(abspos, anchor);
    try mpd.getYanked(start, end + 1, yanked, ra);
    try mpd.rmRange(start, end + 1, ra);
    return start -| 1;
}

fn yankVisual(abspos: usize, anchor: usize, yanked: *mpd.Yanked, ra: mem.Allocator) !usize {
    const start = @min(abspos, anchor);
    const end = @max(abspos, anchor);
    try mpd.getYanked(start, end + 1, yanked, ra);
    return start -| 1;
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
            node_buffer.zeroForward(&app.col_arr);
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
            node_buffer.zeroForward(&app.col_arr);
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
            const displaying = current.displaying orelse return;
            const wheight: u8 = @intCast(window.panels.find.validArea().ylen);
            current.pos, current.slice_inc = scrollHalfDown(current.pos, wheight, displaying.len, current.slice_inc);
            node_buffer.zeroForward(&app.col_arr);
            current.render(render_state);
            current.renderCursor(render_state);
        },
        'u' & '\x1F' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;
            const wheight: u8 = @intCast(window.panels.find.validArea().ylen);
            current.pos, current.slice_inc = scrollHalfUp(current.pos, wheight, displaying.len, current.slice_inc);
            node_buffer.zeroForward(&app.col_arr);
            current.render(render_state);
            current.renderCursor(render_state);
        },
        'g' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;
            current.prev_pos = current.pos;
            current.pos, current.slice_inc = goToIndex(0, displaying.len, window.panels.find.validArea().ylen);
            node_buffer.zeroForward(&app.col_arr);

            current.render(render_state);
            current.renderCursor(render_state);
        },
        'G' => {
            const current: *state.BrowseColumn = app.col_arr.getCurrent();
            if (current.displaying == null) return;
            const slicelen = current.displaying.?.len;
            const windowlen = window.panels.find.validArea().ylen;
            current.prev_pos = current.pos;
            current.pos, current.slice_inc = goToIndex(slicelen - 1, slicelen, windowlen);
            util.log("pos: {}, slice-inc: {}", .{ current.pos, current.slice_inc });
            node_buffer.zeroForward(&app.col_arr);
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
        'n' => {
            if (app.n_str_matches == 0) return;
            const current = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;

            app.istr_match = (app.istr_match + 1) % app.n_str_matches;
            const compare_type: CompareType = if (node_buffer.index == 1) .binary else .linear; // doesn't need to be computed on input
            const index = findStringIndex(app.str_matches[app.istr_match], app.search_sample_str.set, app.search_sample_str.uppers, compare_type) orelse return error.NotFound;
            current.prev_pos = current.pos;
            current.pos, current.slice_inc = goToIndex(index, displaying.len, window.panels.find.validArea().ylen);

            current.renderCursor(render_state);
            current.render(render_state);
        },
        'N' => {
            if (app.n_str_matches == 0) return;
            const current = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;

            var istr: isize = @intCast(app.istr_match);
            istr -= 1;
            const n: isize = @intCast(app.n_str_matches);
            app.istr_match = @intCast(@mod(istr, n));
            const compare_type: CompareType = if (node_buffer.index == 1) .binary else .linear; // doesn't need to be computed on input
            const index = findStringIndex(app.str_matches[app.istr_match], app.search_sample_str.set, app.search_sample_str.uppers, compare_type) orelse return error.NotFound;
            current.prev_pos = current.pos;
            current.pos, current.slice_inc = goToIndex(index, displaying.len, window.panels.find.validArea().ylen);

            current.renderCursor(render_state);
            current.render(render_state);
        },
        '/' => {
            const node = try node_buffer.getCurrentNode();
            if (node.type == .Select) return;
            app.input_state = .typing_browse;
            const curr_col = app.col_arr.getCurrent();
            try switchToTyping(node.type, node_buffer.apex, curr_col, mpd_data, &app.algo_init, &app.search_sample_str);
            curr_col.render(render_state);
            curr_col.clearCursor(render_state);
        },
        '\n', '\r' => {
            const curr_col = app.col_arr.getCurrent();
            try browserHandleEnter(alloc.typingAllocator, curr_col.absolutePos(), mpd_data);
        },
        ' ' => {
            const curr_col = app.col_arr.getCurrent();
            try browserHandleSpace(alloc.typingAllocator, curr_col.absolutePos(), mpd_data);
        },
        else => return,
    }
}

fn onFind(
    rs: *RenderState(state.n_browse_columns),
    mpd_data: *state.Data,
    algo_init: *bool,
    search_sample: *algo.SearchSample(mpd.SongStringAndUri),
    input_state: *Input_State,
) !void {
    _ = try mpd_data.init(.searchable);
    const searchable = mpd_data.searchable orelse return;
    const uppers = mpd_data.searchable_lower orelse return;
    if (!algo_init.*) {
        try algo.init(@max(window.panels.find.validArea().ylen, state.n_browse_matches));
        algo_init.* = true;
    }
    try search_sample.update(searchable, uppers);
    input_state.* = .typing_find;
    rs.find_clear = true;
    rs.queue = true;
}

fn switchToTyping(
    node_type: state.Column_Type,
    apex: state.NodeApex,
    col: *const state.BrowseColumn,
    data: *const state.Data,
    algo_init: *bool,
    search_sample: *algo.SearchSample([]const u8),
) !void {
    if (!algo_init.*) {
        try algo.init(@max(window.panels.find.validArea().ylen, state.n_browse_matches));
        algo_init.* = true;
    }
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

fn typingBrowse(char: u8, app: *state.State, render_state: *RenderState(state.n_browse_columns)) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                try onBrowseTypingExit(app, app.col_arr.getCurrent(), render_state);
            }
        },
        '\r', '\n' => {
            node_buffer.zeroForward(&app.col_arr);
            try onBrowseTypingExit(app, app.col_arr.getCurrent(), render_state);
        },
        '\x7F' => {
            app.typing_buffer.pop() catch return;
            browse_typed = true;
            const current = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;

            const previ = app.search_state.isearch.pop() orelse return;
            app.search_sample_str.indices = std.ArrayList(usize).fromOwnedSlice(alloc.persistentAllocator, @constCast(previ));
            const imatches = app.search_state.imatch.pop() orelse return;
            util.log("imatch 0: {}", .{imatches[0]});
            app.n_str_matches = app.search_sample_str.itemsFromIndices(imatches, app.str_matches);
            util.log("best match: {s}", .{app.str_matches[0]});
            app.istr_match = 0;

            const compare_type: CompareType = if (node_buffer.index == 1) .binary else .linear; // doesn't need to be computed on input
            const index = findStringIndex(app.str_matches[0], app.search_sample_str.set, app.search_sample_str.uppers, compare_type) orelse return error.NotFound;
            current.prev_pos = current.pos;
            current.pos, current.slice_inc = goToIndex(index, displaying.len, window.panels.find.validArea().ylen);

            current.renderCursor(render_state);
            current.render(render_state);
            render_state.type = true;
        },
        else => {
            if (app.search_sample_str.indices.items.len == 0) return;
            app.typing_buffer.append(char) catch return;
            const current = app.col_arr.getCurrent();
            const displaying = current.displaying orelse return;
            browse_typed = true;

            try app.search_state.isearch.append(try app.search_state.dupe(app.search_sample_str.indices.items));
            const imatches = try algo.stringBest(app.typing_buffer.typed, &app.search_sample_str, state.n_browse_matches);
            try app.search_state.imatch.append(try app.search_state.dupe(imatches));
            app.n_str_matches = app.search_sample_str.itemsFromIndices(imatches, app.str_matches);
            app.istr_match = 0;

            const compare_type: CompareType = if (node_buffer.index == 1) .binary else .linear; // doesn't need to be computed on input
            const index = findStringIndex(app.str_matches[0], app.search_sample_str.set, app.search_sample_str.uppers, compare_type) orelse return error.NotFound;
            current.prev_pos = current.pos;
            current.pos, current.slice_inc = goToIndex(index, displaying.len, window.panels.find.validArea().ylen);

            current.renderCursor(render_state);
            current.render(render_state);
            render_state.type = true;
        },
    }
}

fn goToIndex(index: usize, len: usize, height: usize) struct { u8, usize } {
    const inc = @min(index, len -| height);
    debug.assert(index - inc <= 255 and index - inc >= 0);
    return .{
        @intCast(index - inc),
        inc,
    };
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
        'j', 'k', 'g', 'G', 'd' & '\x1F', 'u' & '\x1F', '\n', '\r', 'n', 'N' => {
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
                next.clear(render_state);
                next.render(render_state);
            }
        },
        'l' => {
            if (node_buffer.buf[node_buffer.len - 1].?.displaying == null) {
                const resp = node_buffer.setNodes(&app.col_arr, alloc.respAllocator, alloc.browserAllocator) catch |e| {
                    switch (e) {
                        error.UnsetApex => return,
                        else => return error.NodeError,
                    }
                };
                if (!resp) return;
            }
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

fn goTop(app: *state.State, render_state: *RenderState(n_browse_col)) void {
    if (app.scroll_q.inc > 0) render_state.queue = true else render_state.queueEffects = true;
    app.scroll_q.inc = 0;
    app.scroll_q.prev_pos = app.scroll_q.pos;
    app.scroll_q.pos = 0;
    app.queue.itopviewport = 0;
}

fn goBottom(app: *state.State, render_state: *RenderState(n_browse_col)) void {
    const previnc = app.scroll_q.inc;
    app.scroll_q.inc = if (app.queue.edgebuf[0]) |edge|
        edge.len + @min((mpd.Queue.NSONGS), (app.queue.pl_len - edge.len - app.queue.nviewable))
    else
        app.queue.pl_len -| app.queue.nviewable;
    app.scroll_q.prev_pos = app.scroll_q.pos;
    app.scroll_q.pos = @intCast(@min(app.queue.nviewable - 1, app.queue.pl_len - 1));
    app.queue.itopviewport = app.queue.pl_len -| app.queue.nviewable;
    if (app.scroll_q.inc != previnc) render_state.queue = true else render_state.queueEffects = true;
}

fn queueHalfDown(app: *state.State, render_state: *RenderState(n_browse_col)) !void {
    const prev_itop = app.queue.itopviewport;
    app.scroll_q.prev_pos = app.scroll_q.pos;

    app.scroll_q.pos, app.queue.itopviewport = scrollHalfDown(app.scroll_q.pos, @intCast(app.queue.nviewable), app.queue.pl_len, app.queue.itopviewport);
    app.scroll_q.inc += app.queue.itopviewport - prev_itop;

    if (app.queue.itopviewport == prev_itop) {
        render_state.queueEffects = true;
        return;
    }

    if (app.queue.itopviewport + app.queue.nviewable - 1 > app.queue.ibufferstart + mpd.Queue.NSONGS - 1) {
        app.scroll_q.inc -= try app.queue.getForward(alloc.respAllocator);
    } else if (app.queue.downBufferWrong()) {
        app.queue.fill += try mpd.getQueue(app.queue, .forward, alloc.respAllocator, mpd.Queue.NSONGS);
    }
    render_state.queue = true;
}

fn queueHalfUp(app: *state.State, render_state: *RenderState(n_browse_col)) !void {
    const prev_itop = app.queue.itopviewport;
    app.scroll_q.prev_pos = app.scroll_q.pos;

    app.scroll_q.pos, app.queue.itopviewport = scrollHalfUp(app.scroll_q.pos, @intCast(app.queue.nviewable), app.queue.pl_len, app.queue.itopviewport);
    app.scroll_q.inc -= prev_itop - app.queue.itopviewport;

    if (app.queue.itopviewport == prev_itop) {
        render_state.queueEffects = true;
        return;
    }

    if (app.queue.itopviewport < app.queue.ibufferstart) {
        app.scroll_q.inc += try app.queue.getBackward(alloc.respAllocator);
    } else if (app.queue.upBufferWrong()) {
        app.scroll_q.inc = mpd.Queue.NSONGS - 1 + app.queue.nviewable;
        app.queue.fill += try mpd.getQueue(app.queue, .backward, alloc.respAllocator, mpd.Queue.NSONGS);
        app.queue.ibufferstart -= mpd.Queue.NSONGS;
    }
    render_state.queue = true;
}

fn queueScrollDown(app: *state.State, render_state: *RenderState(n_browse_col)) !void {
    const inc_changed = app.scroll_q.scrollDown(app.queue.nviewable, app.queue.pl_len, app.queue.itopviewport);
    if (inc_changed) {
        app.queue.itopviewport += 1;
        if (app.queue.itopviewport + app.queue.nviewable > app.queue.ibufferstart + mpd.Queue.NSONGS) {
            app.scroll_q.inc -= try app.queue.getForward(alloc.respAllocator);
        } else if (app.queue.downBufferWrong()) {
            util.log("buffer wrong - resetting", .{});
            app.queue.fill += try mpd.getQueue(app.queue, .forward, alloc.respAllocator, mpd.Queue.NSONGS);
        }

        render_state.queue = true;
    }
    render_state.queueEffects = true;
}

fn queueScrollUp(app: *state.State, render_state: *RenderState(n_browse_col)) !void {
    const inc_changed = app.scroll_q.scrollUp();
    if (inc_changed) {
        app.queue.itopviewport -= 1;
        if (app.queue.itopviewport < app.queue.ibufferstart) {
            app.scroll_q.inc += try app.queue.getBackward(alloc.respAllocator);
        } else if (app.queue.upBufferWrong()) {
            util.log("buffer wrong - resetting", .{});
            app.scroll_q.inc = mpd.Queue.NSONGS - 1 + app.queue.nviewable;
            app.queue.fill += try mpd.getQueue(app.queue, .backward, alloc.respAllocator, mpd.Queue.NSONGS);
            app.queue.ibufferstart -= mpd.Queue.NSONGS;
        }

        render_state.queue = true;
    }
    render_state.queueEffects = true;
}

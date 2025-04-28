const std = @import("std");
const mpd = @import("mpdclient.zig");
const input = @import("input.zig");
const algo = @import("algo.zig");
const log = @import("util.zig").log;
const RenderState = @import("render.zig").RenderState;
const expect = std.testing.expect;
const time = std.time;
const mem = std.mem;

const alloc = @import("allocators.zig");
const wrkallocator = alloc.wrkallocator;
const ArrayList = std.ArrayList;

pub const n_browse_columns: u4 = 3;

pub const State = struct {
    quit: bool,
    typing_free: bool,
    first_render: bool,

    song: mpd.CurrentSong,
    isPlaying: bool,
    last_second: i64,
    last_elapsed: u16,
    bar_init: bool,
    currently_filled: usize,

    last_ping: i64,

    queue: mpd.Queue,
    scroll_q: QueueScroll,

    typing_buffer: TypingBuffer,
    find_cursor_pos: u8,
    viewable_searchable: ?[]mpd.SongStringAndUri,

    col_arr: ColumnArray(n_browse_columns),
    node_switched: bool,

    input_state: input.Input_State,
};

pub const Data = struct {
    searchable: []mpd.SongStringAndUri,
    albums: [][]const u8,
    artists: [][]const u8,
    song_titles: [][]const u8,
    songs: []mpd.SongStringAndUri,

    pub fn init() !Data {
        const data = try mpd.listAllData(alloc.respAllocator);
        const searchable = try mpd.getSongStringAndUri(alloc.persistentAllocator, data);
        const songs_unsorted = try mpd.getAllSongs(alloc.persistentAllocator, data);
        _ = alloc.respArena.reset(.retain_capacity);

        // Sort songs alphabetically
        const songs = try sortSongStringsAndUris(songs_unsorted);

        var titles = try alloc.persistentAllocator.alloc([]const u8, songs.len);
        for (songs, 0..) |song, i| {
            titles[i] = song.string;
        }

        const albums = try mpd.getAllAlbums(alloc.persistentAllocator, alloc.respAllocator);
        _ = alloc.respArena.reset(.retain_capacity);
        const artists = try mpd.getAllArtists(alloc.persistentAllocator, alloc.respAllocator);
        _ = alloc.respArena.reset(.retain_capacity);
        return .{
            .searchable = searchable,
            .albums = albums,
            .artists = artists,
            .song_titles = titles,
            .songs = songs,
        };
    }

    // Helper function to sort songs alphabetically
    fn sortSongStringsAndUris(songs_param: []mpd.SongStringAndUri) ![]mpd.SongStringAndUri {
        // Create a sorted copy
        var sorted = try alloc.persistentAllocator.alloc(mpd.SongStringAndUri, songs_param.len);

        // Copy the songs
        for (songs_param, 0..) |song, i| {
            sorted[i] = song;
        }

        // Define a custom context for sorting based on song titles
        const SortContext = struct {
            pub fn lessThan(_: @This(), a: mpd.SongStringAndUri, b: mpd.SongStringAndUri) bool {
                return std.mem.lessThan(u8, a.string, b.string);
            }
        };

        // Sort songs using block sort
        std.sort.block(mpd.SongStringAndUri, sorted, SortContext{}, SortContext.lessThan);

        return sorted;
    }
};

pub const Column_Type = enum {
    Select,
    Artists,
    Albums,
    Tracks,
    None,
};

const CallbackType = enum {
    AlbumsFromArtist,
    TitlesFromTracks,
};
const DisplayCallback = union(CallbackType) {
    AlbumsFromArtist: struct {
        func: *const fn ([]const u8, mem.Allocator, mem.Allocator) anyerror![][]const u8,
        artist: []const u8,
    },
    TitlesFromTracks: struct {
        func: *const fn ([]mpd.SongStringAndUri, mem.Allocator) anyerror![][]const u8,
        tracks: []mpd.SongStringAndUri,
    },
};
//A node is a virtual column.
pub const BrowseNode = struct {
    pos: u8,
    slice_inc: usize,
    displaying: ?[]const []const u8,
    callback_type: ?CallbackType,
    type: Column_Type,

    fn resetPos(self: *BrowseNode) void {
        self.pos = 0;
        self.slice_inc = 0;
    }

    fn posFromColumn(self: *BrowseNode, column: *const BrowseColumn) void {
        self.pos = column.pos;
        self.slice_inc = column.slice_inc;
    }

    fn setCallback(self: *const BrowseNode, selected_artist: ?[]const u8, tracks: ?[]mpd.SongStringAndUri) !DisplayCallback {
        if (self.callback_type) |type_| {
            return switch (type_) {
                .AlbumsFromArtist => DisplayCallback{ .AlbumsFromArtist = .{
                    .func = &mpd.findAlbumsFromArtists,
                    .artist = selected_artist orelse return error.CallbackMishandled,
                } },
                .TitlesFromTracks => DisplayCallback{ .TitlesFromTracks = .{
                    .func = &mpd.titlesFromTracks,
                    .tracks = tracks orelse return error.CallbackMishandled,
                } },
            };
        } else return error.NodeError;
    }

    fn displayingCallback(self: *BrowseNode, cb: DisplayCallback, temp_alloc: mem.Allocator, pers_alloc: mem.Allocator) !void {
        self.displaying = switch (cb) {
            .AlbumsFromArtist => |data| try data.func(data.artist, temp_alloc, pers_alloc),
            .TitlesFromTracks => |data| try data.func(data.tracks, pers_alloc),
        };
    }
};

const NodeApex = enum {
    Albums,
    Artists,
    Tracks,
    UNSET,
};

pub const browse_types: [3][]const u8 = .{ "Albums", "Artists", "Songs" };

//Virtual representation of the browser independent of columns
//Allows to save state of the browser regardless of column layout
pub const Browser = struct {
    const Direction = enum {
        forward,
        backward,
    };
    buf: [4]?BrowseNode,
    index: u8,
    len: u8,
    apex: NodeApex,
    tracks: ?[]mpd.SongStringAndUri,
    find_filter: mpd.Filter_Songs,

    pub fn init(selected: Column_Type, data: Data) Browser {
        return switch (selected) {
            .Albums => Browser{
                .buf = .{
                    .{ .pos = 1, .slice_inc = 0, .displaying = &browse_types, .callback_type = null, .type = .Select },
                    .{ .pos = 0, .slice_inc = 0, .displaying = data.albums, .callback_type = null, .type = .Albums },
                    .{ .pos = 0, .slice_inc = 0, .displaying = null, .callback_type = .TitlesFromTracks, .type = .Tracks },
                    null,
                },
                .apex = .Albums,
                .index = 0,
                .len = 3,
                .tracks = null,
                .find_filter = .{
                    .artist = null,
                    .album = data.albums[0],
                },
            },
            .Artists => Browser{
                .buf = .{
                    .{ .pos = 2, .slice_inc = 0, .displaying = &browse_types, .callback_type = null, .type = .Select },
                    .{ .pos = 0, .slice_inc = 0, .displaying = data.artists, .callback_type = null, .type = .Artists },
                    .{ .pos = 0, .slice_inc = 0, .displaying = null, .callback_type = .AlbumsFromArtist, .type = .Albums },
                    .{ .pos = 0, .slice_inc = 0, .displaying = null, .callback_type = .TitlesFromTracks, .type = .Tracks },
                },
                .apex = .Artists,
                .index = 0,
                .len = 4,
                .tracks = null,
                .find_filter = .{
                    .artist = data.artists[0],
                    .album = null,
                },
            },
            .Tracks => Browser{
                .buf = .{
                    .{ .pos = 3, .slice_inc = 0, .displaying = &browse_types, .callback_type = null, .type = .Select },
                    .{ .pos = 0, .slice_inc = 0, .displaying = data.song_titles, .callback_type = null, .type = .Tracks },
                    null,
                    null,
                },
                .apex = .Tracks,
                .index = 0,
                .len = 2,
                .tracks = data.songs,
                .find_filter = .{
                    .artist = null,
                    .album = null,
                },
            },
            else => unreachable,
        };
    }

    pub fn setNodes(
        self: *Browser,
        columns: *ColumnArray(n_browse_columns),
        temp_alloc: mem.Allocator,
        pers_alloc: mem.Allocator,
    ) !bool {
        switch (self.apex) {
            .Albums => {
                if (self.index != 1) return false;
                const next_node: *BrowseNode = try self.getNextNode();
                self.tracks = try mpd.findTracksFromAlbum(self.find_filter, alloc.respAllocator, alloc.typingAllocator);
                const cb = try next_node.setCallback(null, self.tracks);
                try next_node.displayingCallback(cb, temp_alloc, pers_alloc);
                try columns.setAllDisplaying(self);
                return true;
            },
            .Artists => {
                if (self.index == 1) {
                    const next_node: *BrowseNode = try self.getNextNode();
                    const final: *BrowseNode = if (self.buf[self.index + 2]) |*node| node else return error.NoNode;
                    var cb = try next_node.setCallback(self.find_filter.artist, null);
                    try next_node.displayingCallback(cb, temp_alloc, pers_alloc);
                    try columns.setAllDisplaying(self);
                    self.find_filter.album = next_node.displaying.?[0];
                    self.tracks = try mpd.findTracksFromAlbum(self.find_filter, temp_alloc, pers_alloc);
                    cb = try final.setCallback(null, self.tracks);
                    try final.displayingCallback(cb, temp_alloc, pers_alloc);
                    return true;
                } else if (self.index == 2) {
                    const next_node: *BrowseNode = try self.getNextNode();
                    self.tracks = try mpd.findTracksFromAlbum(self.find_filter, temp_alloc, pers_alloc);
                    const cb = try next_node.setCallback(null, self.tracks);
                    try next_node.displayingCallback(cb, temp_alloc, pers_alloc);
                    try columns.setAllDisplaying(self);
                    return true;
                } else return false;
            },
            .Tracks => return false,
            .UNSET => return error.UnsetApex,
        }
    }
    //Next node has to be synchronised during scroll
    pub fn incrementNode(self: *Browser, columns: *ColumnArray(n_browse_columns)) !bool {
        const init_col: *BrowseColumn = &columns.buf[columns.index];
        const init_node = try self.getCurrentNode();
        init_node.posFromColumn(init_col);
        const next_node = try self.getNextNode();
        log("cond 1: {}", .{(self.len > columns.len)});
        log("cond 2: {}", .{(columns.index == (columns.len / 2))});
        log("cond 3: {}", .{((self.len - self.index) != columns.len)});
        if (self.len > columns.len and columns.index == (columns.len / 2) and (self.len - self.index) == columns.len) {
            init_col.setPos(next_node.pos, next_node.slice_inc);
            columns.inc += 1;
            self.index += 1;
            try columns.setAllDisplaying(self);
            return false;
        } else {
            const next_col: *BrowseColumn = &columns.buf[columns.index + 1];
            next_col.setPos(next_node.pos, next_node.slice_inc);
            columns.index += 1;
            self.index += 1;
            return true;
        }
    }

    pub fn decrementNode(self: *Browser, columns: *ColumnArray(n_browse_columns)) !bool {
        const init_col: *BrowseColumn = &columns.buf[columns.index];
        const init_node = try self.getCurrentNode();
        init_node.posFromColumn(init_col);
        const prev_node = self.buf[self.index - 1].?;
        if (self.len > columns.len and columns.index == (columns.len / 2) and (self.len - self.index) != columns.len) {
            init_col.setPos(prev_node.pos, prev_node.slice_inc);
            columns.inc -= 1;
            self.index -= 1;
            try columns.setAllDisplaying(self);
            return false;
        } else {
            const prev_col: *BrowseColumn = &columns.buf[columns.index - 1];
            prev_col.setPos(prev_node.pos, prev_node.slice_inc);
            columns.index -= 1;
            self.index -= 1;
            return true;
        }
    }

    pub fn zeroForward(self: *Browser) !void {
        for (self.index + 1..self.len) |i| {
            self.buf[i].?.resetPos();
        }
    }

    pub fn getCurrentNode(self: *Browser) !*BrowseNode {
        if (self.index >= self.len) return error.indexError;
        if (self.buf[self.index]) |*node| {
            return node;
        } else {
            return error.NoNode;
        }
    }

    pub fn getNextNode(self: *Browser) !*BrowseNode {
        if (self.index >= self.len) return error.indexError;
        if (self.buf[self.index + 1]) |*node| {
            return node;
        } else {
            return error.NoNode;
        }
    }
};

pub fn ColumnArray(n_col: u8) type {
    return struct {
        const Self = @This();
        buf: [n_col]BrowseColumn,
        index: u8,
        inc: u8,
        len: u8,

        pub fn init() Self {
            var i: u8 = 0;
            var buf: [n_col]BrowseColumn = undefined;
            while (i < n_col) : (i += 1) {
                buf[i] = BrowseColumn{
                    .pos = 0,
                    .prev_pos = 0,
                    .slice_inc = 0,
                    .displaying = null,
                    .index = i,
                };
                if (i == 0) buf[i].displaying = &browse_types;
            }
            return .{
                .buf = buf,
                .index = 0,
                .inc = 0,
                .len = n_col,
            };
        }

        fn setAllDisplaying(self: *Self, browser: *const Browser) !void {
            var i: u8 = 0;
            while (i < self.len) : (i += 1) {
                const browse_node = if (browser.buf[self.inc + i]) |node| node else return error.NoNode;
                const displaying: []const []const u8 = browse_node.displaying orelse return error.NoDisplaying;
                self.buf[i].displaying = displaying;
            }
        }

        pub fn getCurrent(self: *Self) *BrowseColumn {
            return &self.buf[self.index];
        }

        pub fn getPrev(self: *Self) ?*BrowseColumn {
            if (self.index == 0) return null;
            return &self.buf[self.index - 1];
        }

        pub fn getNext(self: *Self) ?*BrowseColumn {
            if (self.index + 1 >= self.len) return null;
            return &self.buf[self.index + 1];
        }
    };
}

pub const BrowseColumn = struct {
    pos: u8,
    prev_pos: u8,
    slice_inc: usize,
    displaying: ?[]const []const u8,
    index: u8,

    pub fn setPos(self: *BrowseColumn, pos: u8, slice_inc: usize) void {
        self.pos = pos;
        self.slice_inc = slice_inc;
    }

    pub fn absolutePos(self: *const BrowseColumn) usize {
        return self.pos + self.slice_inc;
    }

    pub fn scroll(self: *BrowseColumn, direction: input.cursorDirection, max: ?u8, area_height: usize) void {
        self.prev_pos = self.pos;
        //do this earlier and once
        const scroll_threshold: f32 = 0.8;
        const threshold_pos = @as(u8, @intFromFloat(@as(f32, @floatFromInt(area_height)) * scroll_threshold));

        switch (direction) {
            .up => {
                if (self.pos > 0) {
                    self.pos -= 1;
                } else if (self.slice_inc > 0) {
                    self.slice_inc -= 1;
                }
            },
            .down => {
                const displaying = self.displaying orelse return;
                if (self.pos < max.? - 1 and max.? > 0) {
                    self.pos += 1;
                    // If cursor position exceeds threshold (80% of visible area)
                    if (self.pos >= threshold_pos and self.slice_inc + area_height < displaying.len) {
                        self.slice_inc += 1;
                        self.pos -= 1;
                    }
                } else if (self.slice_inc + area_height < displaying.len) {
                    self.slice_inc += 1;
                }
            },
        }
    }

    pub fn render(self: *BrowseColumn, render_state: *RenderState(n_browse_columns)) void {
        render_state.browse_col[self.index] = true;
    }

    pub fn renderCursor(self: *BrowseColumn, render_state: *RenderState(n_browse_columns)) void {
        render_state.browse_cursor[self.index] = true;
    }

    pub fn clearCursor(self: *BrowseColumn, render_state: *RenderState(n_browse_columns)) void {
        render_state.browse_clear_cursor[self.index] = true;
    }

    pub fn clear(self: *BrowseColumn, render_state: *RenderState(n_browse_columns)) !void {
        if (self.index == 0) return error.NoClear;
        render_state.browse_clear[self.index - 1] = true;
    }
};

pub const QueueScroll = struct {
    pos: u8,
    prev_pos: u8,
    slice_inc: usize,

    threshold_pos: u8,
    area_height: usize,

    pub fn absolutePos(self: *const QueueScroll) usize {
        return self.pos + self.slice_inc;
    }

    pub fn absolutePrevPos(self: *const QueueScroll) usize {
        return self.prev_pos + self.slice_inc;
    }

    pub fn scroll(self: *QueueScroll, direction: input.cursorDirection, queue_len: usize) bool {
        const max = self.getMax(queue_len);
        var inc_changed: bool = false;
        self.prev_pos = self.pos;

        switch (direction) {
            .up => {
                if (self.pos > 0) {
                    self.pos -= 1;
                } else if (self.slice_inc > 0) {
                    self.slice_inc -= 1;
                    inc_changed = true;
                }
            },
            .down => {
                if (self.pos < max - 1 and max > 0) {
                    self.pos += 1;
                    // If cursor position exceeds threshold (80% of visible area)
                    if (self.pos >= self.threshold_pos and self.slice_inc + self.area_height < queue_len) {
                        self.slice_inc += 1;
                        self.pos -= 1;
                        inc_changed = true;
                    }
                } else if (self.slice_inc + self.area_height < queue_len) {
                    self.slice_inc += 1;
                    inc_changed = true;
                }
            },
        }
        return inc_changed;
    }

    fn getMax(self: *const QueueScroll, queue_len: usize) usize {
        return @min(queue_len, self.area_height);
    }
};

pub fn getThresholdPos(area_height: usize, threshold_frac: f16) u8 {
    return @as(u8, @intFromFloat(@as(f16, @floatFromInt(area_height)) * threshold_frac));
}

// Core application state
pub const App = struct {
    event_buffer: EventBuffer,
    state: State,
    data: *Data,

    // Constructor
    pub fn init(initial_state: State, data: *Data) App {
        return App{
            .event_buffer = EventBuffer{},
            .state = initial_state,
            .data = data,
        };
    }

    pub fn appendEvent(self: *App, event: Event) void {
        self.event_buffer.buffer[self.event_buffer.len] = event;
        self.event_buffer.len += 1;
    }
    // Update function that processes events
    pub fn updateState(self: *App, render_state: *RenderState(n_browse_columns)) void {
        // Process all events in the buffer
        var i: u8 = 0;
        while (i < self.event_buffer.len) : (i += 1) {
            self.handleEvent(self.event_buffer.buffer[i], render_state);
        }
        // Clear the buffer after processing
        self.event_buffer.len = 0;
    }

    // Handle individual events
    fn handleEvent(self: *App, event: Event, render_state: *RenderState(n_browse_columns)) void {
        switch (event) {
            .input => |char| input.handleInput(char, &self.state, render_state),
            .release => |char| input.handleRelease(char, &self.state, render_state),
            .idle => |idle_type| handleIdle(idle_type, &self.state, render_state) catch |err| {
                log("IDLE EVENT ERROR: {}", .{err});
                unreachable;
            },
            .time => |start_time| handleTime(start_time, &self.state, render_state) catch |err| {
                log("TIME EVENT ERROR: {}", .{err});
                unreachable;
            },
        }
    }
};

pub const Event = union(EventType) {
    input: u8,
    release: u8,
    idle: Idle,
    time: i64,
};

const BufferError = error{
    BufferFull,
};

const BrowseDisplayType = enum {
    types,
    albums,
    artists,
    tracks,
};

const EventBuffer = struct {
    buffer: [5]Event = undefined,
    len: u8 = 0,
};

const EventType = enum {
    input,
    release,
    idle,
    time,
};

pub const Idle = enum {
    player,
    queue,
};

pub const TypingBuffer = struct {
    buf: [256]u8,
    typed: []const u8,

    pub fn init(self: *TypingBuffer) void {
        self.buf = undefined;
        self.typed = self.buf[0..0];
    }

    pub fn reset(self: *TypingBuffer) void {
        self.typed = self.buf[0..0];
    }

    pub fn append(self: *TypingBuffer, char: u8) void {
        self.buf[self.typed.len] = char;
        self.typed = self.buf[0 .. self.typed.len + 1];
    }
};

pub const BrowseCursorPos = struct {
    pos: u8,
    prev_pos: u8,
};

fn handleTime(time_: i64, app: *State, _render_state: *RenderState(n_browse_columns)) !void {
    updateElapsed(time_, app, app, _render_state);
    try ping(time_, app);
}

fn handleIdle(idle_event: Idle, app: *State, render_state: *RenderState(n_browse_columns)) !void {
    switch (idle_event) {
        .player => {
            _ = app.song.init();
            try mpd.getCurrentSong(wrkallocator, &alloc.wrkfba.end_index, &app.song);
            try mpd.getCurrentTrackTime(wrkallocator, &alloc.wrkfba.end_index, &app.song);
            app.last_elapsed = app.song.time.elapsed;
            //lazy
            app.last_second = @divTrunc(time.milliTimestamp(), 1000);
            app.bar_init = true;
            render_state.bar = true;
            render_state.queue = true;
            render_state.queueEffects = true;
            render_state.currentTrack = true;
        },
        .queue => {
            // Clear and rebuild the queue
            app.queue.array.clearRetainingCapacity();
            try mpd.getQueue(alloc.respAllocator, &app.queue);
            app.queue.items = app.queue.getItems();
            _ = alloc.respArena.reset(.free_all);
            render_state.queue = true;
            render_state.queueEffects = true;
        },
    }
}

fn updateElapsed(start: i64, crnt: *const State, app: *State, render_state: *RenderState(n_browse_columns)) void {
    if (crnt.isPlaying) {
        const current_second = @divTrunc(start, 1000);
        if (current_second > crnt.last_second) {
            app.song.time.elapsed += 1;
            app.last_second = current_second;
            render_state.bar = true;
        }
    }
}

fn ping(start: i64, app: *State) !void {
    if ((start - app.last_ping) >= 25 * 1000) {
        try mpd.checkConnection();
        app.last_ping = start;
    }
}

// test "event buffer" {
//     var buf: [256]u8 = undefined;
//     event_buffer = EventBuffer{};
//     const event = Event{ .input_char = 'H' };
//     try event_buffer.append(event);
//     const event2 = Event{ .idle = Idle.player };
//     try event_buffer.append(event2);
//     for (0..event_buffer.len) |i| {
//         const event_type: []const u8 = switch (event_buffer.buffer[i]) {
//             EventType.input_char => |value| try std.fmt.bufPrint(&buf, "char: {c}", .{value}),
//             EventType.idle => |value| try std.fmt.bufPrint(&buf, "mpd: {}", .{value}),
//             EventType.time => |value| try std.fmt.bufPrint(&buf, "time: {}", .{value}),
//         };
//         std.debug.print("event type: {s}\n", .{event_type});
//     }
// }

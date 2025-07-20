const std = @import("std");
const mpd = @import("mpdclient.zig");
const input = @import("input.zig");
const algo = @import("algo.zig");
const RenderState = @import("render.zig").RenderState;
const expect = std.testing.expect;
const time = std.time;
const mem = std.mem;
const debug = std.debug;
const log = @import("util.zig").log;

const alloc = @import("allocators.zig");
const wrkallocator = alloc.wrkallocator;
const ArrayList = std.ArrayList;

pub const n_browse_columns: u4 = 3;

pub const State = struct {
    quit: bool,
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
    prev_id: usize,

    typing_buffer: TypingBuffer,
    find_cursor_pos: u8,
    find_cursor_prev: u8,
    viewable_searchable: ?[]mpd.SongStringAndUri,

    col_arr: ColumnArray(n_browse_columns),
    node_switched: bool,
    current_scrolled: bool,

    input_state: input.Input_State,
};

pub const Data = struct {
    var song_data: ?[]u8 = null;

    searchable: ?[]mpd.SongStringAndUri,
    searchable_init: bool,
    albums: ?[][]const u8,
    albums_init: bool,
    artists: ?[][]const u8,
    artists_init: bool,
    song_titles: ?[][]const u8,
    songs: ?[]mpd.SongStringAndUri,
    songs_init: bool,

    pub fn init(self: *Data, D: enum { searchable, songs, albums, artists }) !bool {
        switch (D) {
            .searchable => {
                if (self.searchable_init) return false;
                try self.initSearchable();
                self.searchable_init = true;
                log("init searchable", .{});
            },
            .songs => {
                if (self.songs_init) return false;
                try self.initSongs();
                self.songs_init = true;
                log("init songs", .{});
            },
            .albums => {
                if (self.albums_init) return false;
                try self.initAlbums();
                self.albums_init = true;
                log("init albums", .{});
            },
            .artists => {
                if (self.artists_init) return false;
                try self.initArtists();
                self.artists_init = true;
                log("init artists", .{});
            },
        }
        return true;
    }

    fn initSearchable(self: *Data) !void {
        if (song_data == null) song_data = try mpd.listAllData(alloc.songDataAllocator);
        self.searchable = try mpd.getSongStringAndUri(alloc.persistentAllocator, song_data.?);

        if (self.songs_init) {
            alloc.songData.deinit();
            song_data = null;
        }
    }

    fn initSongs(self: *Data) !void {
        if (song_data == null) song_data = try mpd.listAllData(alloc.songDataAllocator);
        const songs = try mpd.getAllSongs(alloc.persistentAllocator, song_data.?);

        // Sort songs alphabetically
        try sortSongsLex(songs);

        var titles = try alloc.persistentAllocator.alloc([]const u8, songs.len);
        for (songs, 0..) |song, i| {
            titles[i] = song.string;
        }

        self.songs = songs;
        self.song_titles = titles;

        if (self.searchable_init) {
            alloc.songData.deinit();
            song_data = null;
        }
    }

    fn initAlbums(self: *Data) !void {
        self.albums = try mpd.getAllAlbums(alloc.persistentAllocator, alloc.respAllocator);
        if (self.artists_init) {
            _ = alloc.respArena.reset(.free_all);
        } else {
            _ = alloc.respArena.reset(.retain_capacity);
        }
    }

    fn initArtists(self: *Data) !void {
        self.artists = try mpd.getAllArtists(alloc.persistentAllocator, alloc.respAllocator);
        if (self.albums_init) {
            _ = alloc.respArena.reset(.free_all);
        } else {
            _ = alloc.respArena.reset(.retain_capacity);
        }
    }
};

// Helper function to sort songs alphabetically
fn sortSongsLex(songs: []mpd.SongStringAndUri) !void {
    // Define a custom context for sorting based on song titles
    const SortContext = struct {
        pub fn lessThan(_: @This(), a: mpd.SongStringAndUri, b: mpd.SongStringAndUri) bool {
            return std.mem.lessThan(u8, a.string, b.string);
        }
    };

    // Sort songs using block sort
    std.sort.block(mpd.SongStringAndUri, songs, SortContext{}, SortContext.lessThan);
}

test "codepointcount" {
    var wrkbuf: [64]u8 = undefined;
    mpd.connect(wrkbuf[0..64], .command, false) catch return error.MpdConnectionFailed;
    defer mpd.disconnect(.command);

    mpd.connect(wrkbuf[0..64], .idle, true) catch return error.MpdConnectionFailed;
    defer mpd.disconnect(.idle);
    try mpd.initIdle();
    const data = try Data.init();
    const start = std.time.milliTimestamp();
    for (data.artists) |artist| {
        const count: usize = try std.unicode.utf8CountCodepoints(artist);
        // std.debug.print("{s}", .{artist});
        // std.debug.print(": {}\n", .{count});
        _ = count;
    }
    for (data.song_titles) |song| {
        const count: usize = try std.unicode.utf8CountCodepoints(song);
        // std.debug.print("{s}", .{artist});
        // std.debug.print(": {}\n", .{count});
        _ = count;
    }
    for (data.albums) |albums| {
        const count: usize = try std.unicode.utf8CountCodepoints(albums);
        // std.debug.print("{s}", .{artist});
        // std.debug.print(": {}\n", .{count});
        _ = count;
    }
    const timespent = std.time.milliTimestamp() - start;
    std.debug.print("{}\n", .{timespent});
}

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

    pub fn apexAlbums(data_str: [][]const u8) Browser {
        return Browser{
            .buf = .{
                .{ .pos = 1, .slice_inc = 0, .displaying = &browse_types, .callback_type = null, .type = .Select },
                .{ .pos = 0, .slice_inc = 0, .displaying = data_str, .callback_type = null, .type = .Albums },
                .{ .pos = 0, .slice_inc = 0, .displaying = null, .callback_type = .TitlesFromTracks, .type = .Tracks },
                null,
            },
            .apex = .Albums,
            .index = 0,
            .len = 3,
            .tracks = null,
            .find_filter = .{
                .artist = null,
                .album = data_str[0],
            },
        };
    }

    pub fn apexArtists(data_str: [][]const u8) Browser {
        return Browser{
            .buf = .{
                .{ .pos = 2, .slice_inc = 0, .displaying = &browse_types, .callback_type = null, .type = .Select },
                .{ .pos = 0, .slice_inc = 0, .displaying = data_str, .callback_type = null, .type = .Artists },
                .{ .pos = 0, .slice_inc = 0, .displaying = null, .callback_type = .AlbumsFromArtist, .type = .Albums },
                .{ .pos = 0, .slice_inc = 0, .displaying = null, .callback_type = .TitlesFromTracks, .type = .Tracks },
            },
            .apex = .Artists,
            .index = 0,
            .len = 4,
            .tracks = null,
            .find_filter = .{
                .artist = data_str[0],
                .album = null,
            },
        };
    }

    pub fn apexTracks(songs: []mpd.SongStringAndUri, song_titles: [][]const u8) Browser {
        return Browser{
            .buf = .{
                .{ .pos = 3, .slice_inc = 0, .displaying = &browse_types, .callback_type = null, .type = .Select },
                .{ .pos = 0, .slice_inc = 0, .displaying = song_titles, .callback_type = null, .type = .Tracks },
                null,
                null,
            },
            .apex = .Tracks,
            .index = 0,
            .len = 2,
            .tracks = songs,
            .find_filter = .{
                .artist = null,
                .album = null,
            },
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
                self.tracks = try mpd.findTracksFromAlbum(self.find_filter, temp_alloc, pers_alloc);
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

        pub fn init(first_strings: ?[]const []const u8) Self {
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
                if (i == 1) buf[i].displaying = first_strings;
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

        pub fn clear(self: *Self, render_state: *RenderState(n_browse_columns)) void {
            for (2..self.len) |i| {
                self.buf[i].displaying = null;
                self.buf[i].clear(render_state);
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

    pub fn scroll(self: *BrowseColumn, direction: input.cursorDirection, max: ?u8, area_height: usize) !bool {
        self.prev_pos = self.pos;
        //do this earlier and once
        const scroll_threshold: f32 = 0.8;
        const threshold_pos = @as(u8, @intFromFloat(@as(f32, @floatFromInt(area_height)) * scroll_threshold));

        switch (direction) {
            .up => {
                if (self.pos > 0) {
                    self.pos -= 1;
                    return false;
                } else if (self.slice_inc > 0) {
                    self.slice_inc -= 1;
                    return true;
                }
                return false;
            },
            .down => {
                const displaying = self.displaying orelse return error.NoDisplaying;
                if (self.pos < max.? - 1 and max.? > 0) {
                    self.pos += 1;
                    // If cursor position exceeds threshold (80% of visible area)
                    if (self.pos >= threshold_pos and self.slice_inc + area_height < displaying.len) {
                        self.slice_inc += 1;
                        self.pos -= 1;
                        return true;
                    }
                    return false;
                } else if (self.slice_inc + area_height < displaying.len) {
                    self.slice_inc += 1;
                    return true;
                }
                return false;
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

    pub fn clear(self: *BrowseColumn, render_state: *RenderState(n_browse_columns)) void {
        render_state.browse_clear[self.index] = true;
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

    pub fn jumpTop(self: *QueueScroll) bool {
        var inc_changed = false;
        if (self.slice_inc > 0) {
            self.slice_inc = 0;
            inc_changed = true;
        }
        self.prev_pos = self.pos;
        self.pos = 0;
        return inc_changed;
    }

    pub fn jumpBottom(self: *QueueScroll, qlen: usize) bool {
        var inc_changed = false;
        self.prev_pos = self.pos;
        if (qlen > 0) {
            if (qlen > self.area_height) {
                const prev_inc = self.slice_inc;
                self.slice_inc = qlen - self.area_height;
                if (self.slice_inc != prev_inc) inc_changed = true;
                self.pos = @intCast(self.area_height - 1);
            } else {
                self.pos = @intCast(qlen - 1);
            }
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
    pub fn updateState(self: *App, render_state: *RenderState(n_browse_columns), mpd_data: *Data) void {
        var i: u8 = 0;
        while (i < self.event_buffer.len) : (i += 1) {
            switch (self.event_buffer.buffer[i]) {
                .input => |char| input.handleInput(char, &self.state, render_state, mpd_data),
                .release => |char| input.handleRelease(char, &self.state, render_state),
                .idle => |idle_type| handleIdle(idle_type, &self.state, render_state) catch |err| {
                    log("err: {}", .{err});
                    unreachable;
                },
                .time => |start_time| handleTime(start_time, &self.state, render_state) catch |err| {
                    log("err: {}", .{err});
                    unreachable;
                },
            }
        }
        self.event_buffer.len = 0;
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
    buf: [32]u8,
    typed: []const u8,

    pub fn init(self: *TypingBuffer) void {
        self.buf = undefined;
        self.typed = self.buf[0..0];
    }

    pub fn reset(self: *TypingBuffer) void {
        self.typed = self.buf[0..0];
    }

    pub fn append(self: *TypingBuffer, char: u8) !void {
        if (self.typed.len == self.buf.len) return error.BufferFull;
        self.buf[self.typed.len] = char;
        self.typed = self.buf[0 .. self.typed.len + 1];
    }

    pub fn pop(self: *TypingBuffer) !void {
        if (self.typed.len == 0) return error.NoTyped;
        self.typed = self.buf[0 .. self.typed.len - 1];
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
            app.prev_id = app.song.id;
            _ = app.song.init();
            try mpd.getCurrentSong(wrkallocator, &alloc.wrkfba.end_index, &app.song);
            try mpd.getCurrentTrackTime(wrkallocator, &alloc.wrkfba.end_index, &app.song);
            app.last_elapsed = app.song.time.elapsed;
            //lazy
            app.last_second = @divTrunc(time.milliTimestamp(), 1000);
            app.bar_init = true;
            render_state.bar = true;
            render_state.queueEffects = true;
            render_state.currentTrack = true;
        },
        .queue => {
            // Clear and rebuild the queue
            app.queue.array.clearRetainingCapacity();
            try mpd.getQueue(alloc.respAllocator, &app.queue);
            app.queue.items = app.queue.getItems();
            _ = alloc.respArena.reset(.free_all);
            if (app.queue.items.len == 0) app.isPlaying = false;
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

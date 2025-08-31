const std = @import("std");
const mpd = @import("mpdclient.zig");
const input = @import("input.zig");
const algo = @import("algo.zig");
const RenderState = @import("render.zig").RenderState;
const CodePointIterator = @import("code_point").Iterator;
const isAsciiOnly = @import("ascii").isAsciiOnly;
const lowerString = std.ascii.lowerString;
const expect = std.testing.expect;
const ascii = std.ascii;
const time = std.time;
const mem = std.mem;
const math = std.math;
const debug = std.debug;
const unic = std.unicode;
const log = @import("util.zig").log;

const alloc = @import("allocators.zig");
const stringLowerBuf1 = alloc.ptrLower1;
const stringLowerBuf2 = alloc.ptrLower2;
const wrkallocator = alloc.wrkallocator;
const ArrayList = std.ArrayList;

pub const n_browse_columns: u4 = 3;
pub const RingBufSize = 128;

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
    // songbuf: RingBuffer(RingBufSize, mpd.QSong),
    // strbuf: RingBuffer(RingBufSize * mpd.QSong.STR_BUF_SIZE, u8),
    prev_id: usize,

    typing_buffer: TypingBuffer,
    find_cursor_pos: u8,
    find_cursor_prev: u8,
    viewable_searchable: ?[]const mpd.SongStringAndUri,

    algo_init: bool,
    search_sample_str: algo.SearchSample([]const u8),
    search_sample_su: algo.SearchSample(mpd.SongStringAndUri),

    col_arr: ColumnArray(n_browse_columns),
    node_switched: bool,
    current_scrolled: bool,

    input_state: input.Input_State,
};

pub const Data = struct {
    var song_data: ?[]u8 = null;

    searchable: ?[]const mpd.SongStringAndUri,
    searchable_lower: ?[]const []const u16,
    searchable_init: bool,
    albums: ?[]const []const u8,
    albums_lower: ?[]const []const u16,
    albums_init: bool,
    artists: ?[]const []const u8,
    artists_lower: ?[]const []const u16,
    artists_init: bool,
    song_titles: ?[]const []const u8,
    songs_lower: ?[]const []const u16,
    songs: ?[]const mpd.SongStringAndUri,
    songs_init: bool,

    pub fn init(self: *Data, D: enum { searchable, songs, albums, artists }) !bool {
        switch (D) {
            .searchable => {
                if (self.searchable_init) return false;
                try self.initSearchable(alloc.persistentAllocator, alloc.songDataAllocator);
                self.searchable_init = true;
                log("init searchable", .{});
            },
            .songs => {
                if (self.songs_init) return false;
                try self.initSongs(alloc.persistentAllocator, alloc.songDataAllocator);
                self.songs_init = true;
                log("init songs", .{});
            },
            .albums => {
                if (self.albums_init) return false;
                try self.initAlbums(alloc.persistentAllocator, alloc.respAllocator);
                self.albums_init = true;
                log("init albums", .{});
            },
            .artists => {
                if (self.artists_init) return false;
                try self.initArtists(alloc.persistentAllocator, alloc.respAllocator);
                self.artists_init = true;
                log("init artists", .{});
            },
        }
        return true;
    }

    fn initSearchable(self: *Data, heapAlloc: mem.Allocator, songDataAlloc: mem.Allocator) !void {
        if (song_data == null) song_data = try mpd.listAllData(songDataAlloc);
        self.searchable = try mpd.getSongStringAndUri(heapAlloc, song_data.?);
        if (self.searchable) |search| {
            var lower: [][]u16 = try heapAlloc.alloc([]u16, search.len);
            for (search, 0..) |su, i| {
                var array = ArrayList(u16).init(heapAlloc);
                if (isAsciiOnly(su.string)) {
                    for (su.string, 0..) |c, j| {
                        if (ascii.isUpper(c)) {
                            if (math.cast(u16, j)) |casted|
                                try array.append(casted)
                            else
                                return error.OutOfBoundsOffset;
                        }
                    }
                    lower[i] = try array.toOwnedSlice();
                    continue;
                }
                var cp_iter = CodePointIterator{ .bytes = su.string };
                while (cp_iter.next()) |cp| {
                    if (cp.len != 1) {
                        continue;
                    }
                    if (math.cast(u8, cp.code)) |c| {
                        if (ascii.isAscii(c) and ascii.isUpper(c)) {
                            if (math.cast(u16, cp.offset)) |casted|
                                try array.append(casted)
                            else
                                return error.OutOfBoundsOffset;
                        }
                    }
                }
                lower[i] = try array.toOwnedSlice();
            }
            self.searchable_lower = lower;
        }

        if (self.songs_init) {
            alloc.songData.deinit();
            song_data = null;
        }
    }

    fn initSongs(self: *Data, persistentAlloc: mem.Allocator, songDataAlloc: mem.Allocator) !void {
        if (song_data == null) song_data = try mpd.listAllData(songDataAlloc);
        const songs = try mpd.getAllSongs(persistentAlloc, song_data.?);

        // Sort songs alphabetically in lower-case
        sortSongsLex(songs);

        var titles = try persistentAlloc.alloc([]const u8, songs.len);
        for (songs, 0..) |song, i| {
            titles[i] = song.string;
        }

        const lower = try persistentAlloc.alloc([]u16, titles.len);
        try getUpperIndices(titles, lower, persistentAlloc);

        self.songs = songs;
        self.song_titles = titles;
        self.songs_lower = lower;

        if (self.searchable_init) {
            alloc.songData.deinit();
            song_data = null;
        }
        // var buf = try persistentAlloc.alloc(u8, 512);
        // for (self.song_titles.?, 0..) |a, i| {
        //     getLowerString(a, self.songs_lower.?[i], buf);
        //     log("{s} - {s}", .{
        //         a,
        //         buf[0..a.len],
        //     });
        // }
    }

    fn initAlbums(self: *Data, persistentAllocator: mem.Allocator, tempAllocator: mem.Allocator) !void {
        const albums = try mpd.getAllAlbums(persistentAllocator, tempAllocator);
        sortStringsLex(albums);
        self.albums = albums;
        const lower = try persistentAllocator.alloc([]u16, albums.len);
        try getUpperIndices(albums, lower, persistentAllocator);
        self.albums_lower = lower;
        if (self.artists_init) {
            _ = alloc.respArena.reset(.free_all);
        } else {
            _ = alloc.respArena.reset(.retain_capacity);
        }

        // var buf = try persistentAllocator.alloc(u8, 512);
        // for (self.albums.?, 0..) |a, i| {
        //     getLowerString(a, self.albums_lower.?[i], buf);
        //     log("{s} - {s}", .{
        //         a,
        //         buf[0..a.len],
        //     });
        // }
    }

    fn initArtists(self: *Data, persistentAllocator: mem.Allocator, tempAllocator: mem.Allocator) !void {
        const artists = try mpd.getAllArtists(persistentAllocator, tempAllocator);
        sortStringsLex(artists);
        self.artists = artists;
        const lower = try persistentAllocator.alloc([]u16, artists.len);
        try getUpperIndices(artists, lower, persistentAllocator);
        self.artists_lower = lower;
        if (self.albums_init) {
            _ = alloc.respArena.reset(.free_all);
        } else {
            _ = alloc.respArena.reset(.retain_capacity);
        }

        // var buf = try persistentAllocator.alloc(u8, 512);
        // for (self.artists.?, 0..) |a, i| {
        //     getLowerString(a, self.artists_lower.?[i], buf);
        //     log("{s} - {s}", .{
        //         a,
        //         buf[0..a.len],
        //     });
        // }
    }
};

fn getUpperIndices(strings: []const []const u8, dest: [][]u16, allocator: mem.Allocator) !void {
    for (strings, 0..) |str, i| {
        var array = ArrayList(u16).init(allocator);
        if (isAsciiOnly(str)) {
            for (str, 0..) |c, j| {
                if (ascii.isUpper(c)) {
                    if (math.cast(u16, j)) |casted|
                        try array.append(casted)
                    else
                        return error.OutOfBoundsOffset;
                }
            }
            dest[i] = try array.toOwnedSlice();
            continue;
        }
        var cp_iter = CodePointIterator{ .bytes = str };
        while (cp_iter.next()) |cp| {
            if (cp.len != 1) {
                continue;
            }
            if (math.cast(u8, cp.code)) |c| {
                if (ascii.isAscii(c) and ascii.isUpper(c)) {
                    if (math.cast(u16, cp.offset)) |casted|
                        try array.append(casted)
                    else
                        return error.OutOfBoundsOffset;
                }
            }
        }
        dest[i] = try array.toOwnedSlice();
    }
}

pub fn fastLowerString(str: []const u8, uppers: []const u16, buf: []u8) []const u8 {
    var index: usize = 0;
    var char: u8 = undefined;
    for (str, 0..) |c, i| {
        if (index == uppers.len) {
            mem.copyForwards(u8, buf[i..str.len], str[i..str.len]);
            break;
        }
        if (i == uppers[index]) {
            char = ascii.toLower(c);
            index += 1;
        } else {
            char = c;
        }
        buf[i] = char;
    }
    return buf[0..str.len];
}
// Helper function to sort songs alphabetically
fn sortSongsLex(songs: []mpd.SongStringAndUri) void {
    const SortContext = struct {
        pub fn lessThan(_: @This(), a: mpd.SongStringAndUri, b: mpd.SongStringAndUri) bool {
            const alower: []const u8 = ascii.lowerString(stringLowerBuf1, a.string);
            const blower: []const u8 = ascii.lowerString(stringLowerBuf2, b.string);
            return mem.lessThan(u8, alower, blower);
        }
    };

    // Sort songs using block sort
    std.sort.block(mpd.SongStringAndUri, songs, SortContext{}, SortContext.lessThan);
}

fn sortStringsLex(strings: [][]const u8) void {
    const SortContext = struct {
        pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
            const alower: []const u8 = ascii.lowerString(stringLowerBuf1, a);
            const blower: []const u8 = ascii.lowerString(stringLowerBuf2, b);
            return mem.lessThan(u8, alower, blower);
        }
    };

    // Sort songs using block sort
    std.sort.block([]const u8, strings, SortContext{}, SortContext.lessThan);
}

pub const Column_Type = enum {
    Albums,
    Artists,
    Tracks,
    Select,
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
        func: *const fn ([]const mpd.SongStringAndUri, mem.Allocator) anyerror![][]const u8,
        tracks: []const mpd.SongStringAndUri,
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

    fn setCallback(self: *const BrowseNode, selected_artist: ?[]const u8, tracks: ?[]const mpd.SongStringAndUri) !DisplayCallback {
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

pub const NodeApex = enum {
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
    tracks: ?[]const mpd.SongStringAndUri,
    find_filter: mpd.Filter_Songs,

    pub fn apexAlbums(data_str: []const []const u8) Browser {
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

    pub fn apexArtists(data_str: []const []const u8) Browser {
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

    pub fn apexTracks(songs: []const mpd.SongStringAndUri, song_titles: []const []const u8) Browser {
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

fn Ring(size: usize, T: type) type {
    return struct {
        const Self = @This();
        buf: []T,
        first: usize,
        stop: usize,
        fill: usize,
        items: Iterator(T),

        fn init(allocator: mem.Allocator) !Self {
            const buf = try allocator.alloc(T, size);
            return .{
                .buf = buf,
                .first = 0,
                .stop = 0,
                .fill = 0,
                .items = Iterator(T).init(buf.ptr, size),
            };
        }

        fn forwardWrite(self: *Self, src: []const T) void {
            debug.assert(src.len <= size);
            const rest = size - self.stop;
            if (src.len <= rest) {
                @memcpy(self.buf[self.stop .. self.stop + src.len], src);
            } else {
                @memcpy(self.buf[self.stop..size], src[0..rest]);
                @memcpy(self.buf[0 .. src.len - rest], src[rest..]);
            }
            self.stop = (self.stop + src.len) % size;

            self.fill += src.len;
            if (self.fill > size) {
                self.first = (self.first + (self.fill - size)) % size;
                self.fill = size;
            }

            self.items.index = self.first;
            self.items.remaining = self.fill;
        }

        fn backwardWrite(self: *Self, src: []const T) void {
            debug.assert(src.len <= size);
            const start: usize = (self.first + size - src.len) % size;
            if (src.len <= self.first) {
                @memcpy(self.buf[start..self.first], src);
            } else {
                const tail_len = size - start;
                @memcpy(self.buf[start..size], src[0..tail_len]);
                const head_len = src.len - tail_len;
                @memcpy(self.buf[0..head_len], src[tail_len..]);
            }
            self.first = start;

            self.fill += src.len;
            if (self.fill > size) {
                const overflow = self.fill - size;
                self.stop = (self.stop + size - overflow) % size;
                self.fill = size;
            }

            self.items.index = self.first;
            self.items.remaining = self.fill;
        }
    };
}

fn Iterator(T: type) type {
    return struct {
        const Self = @This();
        buf: [*]const T,
        index: usize,
        remaining: usize,
        size: usize,

        fn init(buf: [*]const T, size: usize) Self {
            return .{
                .buf = buf,
                .index = 0,
                .remaining = 0,
                .size = size,
            };
        }

        fn next(self: *Self) ?T {
            if (self.remaining == 0) return null;
            const value = self.buf[self.index];
            self.index = (self.index + 1) % self.size;
            self.remaining -= 1;
            return value;
        }
    };
}

test "ring" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var arr: [8]u8 = undefined;
    for (0..8) |i| {
        const cast: u8 = @intCast(i);
        arr[i] = cast;
    }
    var ring = try Ring(8, u8).init(allocator);

    ring.forwardWrite(arr[0..]);

    debug.print("---------------\n", .{});
    for (ring.buf) |x| {
        debug.print("Val: {}\n", .{x});
    }

    for (0..4) |i| {
        arr[i] = 69;
    }

    ring.forwardWrite(arr[0..4]);

    debug.print("---------------\n", .{});
    for (ring.buf) |x| {
        debug.print("Val: {}\n", .{x});
    }

    debug.print("---------------\n", .{});
    debug.print("Ordered\n", .{});
    while (ring.items.next()) |item| {
        debug.print("Val: {}\n", .{item});
    }
}

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

const std = @import("std");
const mpd = @import("mpdclient.zig");
const input = @import("input.zig");
const algo = @import("algo.zig");
const log = @import("util.zig").log;
const RenderState = @import("render.zig").RenderState;
const expect = std.testing.expect;
const time = std.time;

const alloc = @import("allocators.zig");
const wrkallocator = alloc.wrkallocator;

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
    viewStartQ: usize,
    viewEndQ: usize,
    cursorPosQ: u8,
    prevCursorPos: u8,

    typing_display: TypingDisplay,
    find_cursor_pos: u8,
    viewable_searchable: ?[]mpd.Searchable,

    selected_column: Columns,
    column_1: BrowseColumn,
    column_2: BrowseColumn,
    column_3: BrowseColumn,

    find_filter: mpd.Filter_Songs,

    input_state: input.Input_State,
};

pub const Data = struct {
    searchable: []mpd.Searchable,
    albums: []const []const u8,
    artists: []const []const u8,
    songs: mpd.SongTitleAndUri,

    pub fn init() !Data {
        const data = try mpd.listAllData(alloc.respAllocator);
        const searchable = try mpd.getSearchable(alloc.persistentAllocator, data);
        var songs = try mpd.getAllSongs(alloc.persistentAllocator, data);
        _ = alloc.respArena.reset(.retain_capacity);

        // Sort songs alphabetically while keeping uri and title indices synchronized
        try sortSongTitlesAndUris(&songs);

        const albums = try mpd.getAllAlbums(alloc.persistentAllocator, alloc.respAllocator);
        _ = alloc.respArena.reset(.retain_capacity);
        const artists = try mpd.getAllArtists(alloc.persistentAllocator, alloc.respAllocator);
        _ = alloc.respArena.reset(.retain_capacity);
        return .{
            .searchable = searchable,
            .albums = albums,
            .artists = artists,
            .songs = songs,
        };
    }

    // Helper function to sort songs alphabetically while keeping uri and title indices synchronized
    fn sortSongTitlesAndUris(songs: *mpd.SongTitleAndUri) !void {
        // Create an array of indices
        var indices = try alloc.persistentAllocator.alloc(usize, songs.titles.len);
        defer alloc.persistentAllocator.free(indices);

        for (0..songs.titles.len) |i| {
            indices[i] = i;
        }

        // Define a custom context for sorting indices based on song titles
        const SortContext = struct {
            titles: []const []const u8,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.titles[a], ctx.titles[b]);
            }
        };

        // Sort indices using block sort
        std.sort.block(usize, indices, SortContext{ .titles = songs.titles }, SortContext.lessThan);

        // Create new arrays with sorted data
        var new_titles = try alloc.persistentAllocator.alloc([]const u8, songs.titles.len);
        var new_uris = try alloc.persistentAllocator.alloc([]const u8, songs.uris.len);

        for (indices, 0..) |old_idx, new_idx| {
            new_titles[new_idx] = songs.titles[old_idx];
            new_uris[new_idx] = songs.uris[old_idx];
        }

        // Free old arrays and replace with sorted ones
        alloc.persistentAllocator.free(songs.titles);
        alloc.persistentAllocator.free(songs.uris);

        songs.titles = new_titles;
        songs.uris = new_uris;
    }
};

pub const Columns = enum {
    one,
    two,
    three,
};

pub const Column_Type = enum {
    Select,
    Artists,
    Albums,
    Tracks,
    None,
};

pub const BrowseColumn = struct {
    pos: u8,
    prev_pos: u8,
    slice_inc: usize,
    displaying: []const []const u8,
    type: Column_Type,

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
                if (self.pos < max.? - 1 and max.? > 0) {
                    self.pos += 1;
                    // If cursor position exceeds threshold (80% of visible area)
                    if (self.pos >= threshold_pos and self.slice_inc + area_height < self.displaying.len) {
                        self.slice_inc += 1;
                        self.pos -= 1;
                    }
                } else if (self.slice_inc + area_height < self.displaying.len) {
                    self.slice_inc += 1;
                }
            },
        }
    }
};
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
    pub fn updateState(self: *App, render_state: *RenderState) void {
        // Process all events in the buffer
        var i: u8 = 0;
        while (i < self.event_buffer.len) : (i += 1) {
            self.handleEvent(self.event_buffer.buffer[i], render_state);
        }
        // Clear the buffer after processing
        self.event_buffer.len = 0;
    }

    // Handle individual events
    fn handleEvent(self: *App, event: Event, render_state: *RenderState) void {
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
    buffer: [4]Event = undefined,
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

pub const TypingDisplay = struct {
    typeBuffer: [256]u8,
    typed: []const u8,

    pub fn init(self: *TypingDisplay) void {
        self.typeBuffer = undefined;
        self.typed = self.typeBuffer[0..0];
    }

    pub fn reset(self: *TypingDisplay) void {
        self.typed = self.typeBuffer[0..0];
    }
};

pub const BrowseCursorPos = struct {
    pos: u8,
    prev_pos: u8,
};

fn handleTime(time_: i64, app: *State, _render_state: *RenderState) !void {
    updateElapsed(time_, app, app, _render_state);
    try ping(time_, app);
}

fn handleIdle(idle_event: Idle, app: *State, render_state: *RenderState) !void {
    switch (idle_event) {
        .player => {
            _ = app.song.init();
            _ = try mpd.getCurrentSong(wrkallocator, &alloc.wrkfba.end_index, &app.song);
            _ = try mpd.getCurrentTrackTime(wrkallocator, &alloc.wrkfba.end_index, &app.song);
            _ = try mpd.initIdle();
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
            app.queue = mpd.Queue{};
            _ = try mpd.getQueue(wrkallocator, &alloc.wrkfba.end_index, &app.queue);
            _ = try mpd.initIdle();
            render_state.queue = true;
            render_state.queueEffects = true;
        },
    }
}

fn updateElapsed(start: i64, crnt: *const State, app: *State, render_state: *RenderState) void {
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

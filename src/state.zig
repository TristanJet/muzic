const std = @import("std");
const mpd = @import("mpdclient.zig");
const input = @import("input.zig");
const log = @import("util.zig").log;
const RenderState = @import("render.zig").RenderState;
const expect = std.testing.expect;
const time = std.time;

const alloc = @import("allocators.zig");
const wrkallocator = alloc.wrkallocator;

// Core application state
pub const App = struct {
    event_buffer: EventBuffer,
    state: State,

    // Constructor
    pub fn init(initial_state: State) App {
        return App{
            .event_buffer = EventBuffer{},
            .state = initial_state,
        };
    }

    pub fn appendEvent(self: *App, event: Event) BufferError!void {
        if (self.event_buffer.len >= self.event_buffer.buffer.len) {
            return BufferError.BufferFull;
        }
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
            .input_char => |char| input.handleInput(char, &self.state, render_state),
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
    input_char: u8,
    idle: Idle,
    time: i64,
};

const BufferError = error{
    BufferFull,
};

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

    browse_cursor: BrowseCursor,

    input_state: input.Input_State,
};

const EventBuffer = struct {
    buffer: [3]Event = undefined,
    len: u8 = 0,
};

const EventType = enum {
    input_char,
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

pub const BrowseCursor = struct {
    column: u8,
    position: u8,
    prev_position: u8,
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

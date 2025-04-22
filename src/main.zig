const std = @import("std");
const time = std.time;

const state = @import("state.zig");
const mpd = @import("mpdclient.zig");
const input = @import("input.zig");
const term = @import("terminal.zig");
const window = @import("window.zig");
const util = @import("util.zig");
const render = @import("render.zig");
const alloc = @import("allocators.zig");
const algo = @import("algo.zig");

const RenderState = render.RenderState;
const log = util.log;
const Event = state.Event;
const App = state.App;
const ArrayList = std.ArrayList;

const target_fps = 60;
const target_frame_time_ms = 1000 / target_fps;

var initial_song: mpd.CurrentSong = undefined;
var initial_typing: state.TypingBuffer = undefined;
var initial_queue: mpd.Queue = .{
    .allocator = alloc.persistentAllocator,
    .array = ArrayList(mpd.QSong).init(alloc.persistentAllocator),
    .items = undefined,
};

const wrkallocator = alloc.wrkallocator;
const wrkfba = &alloc.wrkfba;
const wrkbuf = &alloc.wrkbuf;

pub fn main() !void {
    defer alloc.deinit();

    try util.init();
    defer util.deinit() catch {};

    try mpd.connect(wrkbuf[0..64], .command, false);
    defer mpd.disconnect(.command);

    try mpd.connect(wrkbuf[0..64], .idle, true);
    defer mpd.disconnect(.idle);
    try mpd.initIdle();

    try term.init();
    defer term.deinit() catch {};

    try window.init();
    algo.nRanked = window.panels.find.validArea().ylen;

    initial_song.init();
    try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &initial_song);
    try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &initial_song);
    log("initial queue", .{});
    try mpd.getQueue(alloc.respAllocator, &initial_queue);
    initial_queue.items = initial_queue.getItems();
    _ = alloc.respArena.reset(.free_all);

    initial_typing.init();

    // change to const eventually ???
    var data = try state.Data.init();
    input.data = data;

    const initial_state = state.State{
        .quit = false,
        .first_render = true,

        .song = initial_song,
        .isPlaying = true,
        .last_second = 0,
        .last_elapsed = 0,
        .bar_init = true,
        .currently_filled = 0,

        .last_ping = time.milliTimestamp(),

        .queue = initial_queue,
        .scroll_q = state.QueueScroll{
            .pos = 0,
            .prev_pos = 0,
            .slice_inc = 0,

            .threshold_pos = state.getThresholdPos(window.panels.queue.validArea().ylen, 0.8),
            .area_height = window.panels.queue.validArea().ylen,
        },

        .typing_buffer = initial_typing,
        .find_cursor_pos = 0,
        .viewable_searchable = null,

        .selected_column = .one,
        .column_1 = state.BrowseColumn{
            .displaying = state.browse_types[0..],
            .pos = 0,
            .prev_pos = 0,
            .slice_inc = 0,
        },
        .column_2 = state.BrowseColumn{
            .displaying = data.albums,
            .pos = 0,
            .prev_pos = 0,
            .slice_inc = 0,
        },
        .column_3 = state.BrowseColumn{
            .displaying = undefined,
            .pos = 0,
            .prev_pos = 0,
            .slice_inc = 0,
        },
        .node_switched = false,

        .input_state = .normal_queue,
    };

    var app = App.init(initial_state, &data);

    var render_state = RenderState.init();

    while (!app.state.quit) {
        defer wrkfba.reset();
        const loop_start_time = time.milliTimestamp();

        const input_event: ?Event = try input.checkInputEvent(wrkbuf[wrkfba.end_index .. wrkfba.end_index + 1]);
        const released_event: ?Event = try input.checkReleaseEvent(input_event);
        const idle_event: [2]?Event = try mpd.checkIdle(wrkbuf[wrkfba.end_index .. wrkfba.end_index + 18]);
        const time_event: Event = Event{ .time = loop_start_time };

        if (input_event) |event| app.appendEvent(event);
        if (released_event) |event| app.appendEvent(event);
        if (idle_event[0]) |event| app.appendEvent(event);
        if (idle_event[1]) |event| app.appendEvent(event);
        app.appendEvent(time_event);

        app.updateState(&render_state);
        try render.render(&app.state, &render_state, window.panels, &wrkfba.end_index);
        render_state = RenderState{};

        // Calculate remaining time in frame and sleep if necessary
        const frame_time = time.milliTimestamp() - loop_start_time;
        if (frame_time < target_frame_time_ms) {
            const sleep_time: u64 = @intCast((target_frame_time_ms - frame_time) * time.ns_per_ms);
            time.sleep(sleep_time);
        }
    }
}

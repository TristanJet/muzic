const std = @import("std");
const builtin = @import("builtin");
const DisplayWidth = @import("DisplayWidth");
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
const proc = @import("proc.zig");
const dw = @import("display_width.zig");

const RenderState = render.RenderState;
const Event = state.Event;
const App = state.App;
const ArrayList = std.ArrayList;

const target_fps = 60;
const target_frame_time_ms = 1000 / target_fps;

var initial_song: mpd.CurrentSong = undefined;
var initial_typing: state.TypingBuffer = undefined;

const wrkallocator = alloc.wrkallocator;
const wrkfba = &alloc.wrkfba;
const wrkbuf = &alloc.wrkbuf;

pub fn main() !void {
    defer alloc.deinit();

    if (builtin.mode == .Debug) try util.loggerInit();
    defer if (builtin.mode == .Debug) util.deinit() catch {};

    const args = proc.handleArgs() catch |e| switch (e) {
        error.InvalidOption => {
            try proc.printInvArg();
            return;
        },
        proc.InvalidIPv4Error.InvalidHost, proc.InvalidIPv4Error.InvalidPort => |err| {
            try proc.printInvIp4(wrkallocator, err);
            return;
        },
        else => return,
    };

    if (args.help) return;
    if (args.version) return;

    mpd.handleArgs(args.host, args.port);
    mpd.connect(.command, false) catch |e| switch (e) {
        error.NoMpd => {
            try proc.printMpdFail(wrkallocator, args.host, args.port);
            return;
        },
        else => return error.MpdConnectionFailed,
    };
    defer mpd.disconnect(.command);
    mpd.connect(.idle, true) catch |e| switch (e) {
        error.NoMpd => {
            try proc.printMpdFail(wrkallocator, args.host, args.port);
            return;
        },
        else => {
            return error.MpdConnectionFailed;
        },
    };
    defer mpd.disconnect(.idle);
    try mpd.initIdle();

    try term.init();
    defer term.deinit() catch {};

    try window.init();

    try dw.init(alloc.persistentAllocator, window.panels);
    defer dw.deinit(alloc.persistentAllocator);

    initial_song.init();
    try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &initial_song);
    try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &initial_song);
    var queue: mpd.Queue = try mpd.Queue.init(alloc.respAllocator, alloc.persistentAllocator, window.panels.queue.validArea().ylen);
    try queue.fillForward(alloc.respAllocator, alloc.persistentAllocator);

    initial_typing.init();

    var mpd_data = state.Data{
        .artists = null,
        .artists_lower = null,
        .artists_init = false,
        .albums = null,
        .albums_lower = null,
        .albums_init = false,
        .searchable = null,
        .searchable_lower = null,
        .searchable_init = false,
        .songs = null,
        .songs_lower = null,
        .song_titles = null,
        .songs_init = false,
    };

    const initial_state = state.State{
        .quit = false,
        .first_render = true,

        .prev_id = 0,
        .song = &initial_song,
        .isPlaying = try mpd.getPlayState(alloc.respAllocator),
        .last_second = 0,
        .last_elapsed = 0,
        .bar_init = true,
        .currently_filled = 0,

        .last_ping = time.milliTimestamp(),

        .queue = &queue,
        .scroll_q = state.QueueScroll{
            .pos = 0,
            .prev_pos = 0,
            .inc = 0,
            .queue = &queue,

            .threshold_pos = state.getThresholdPos(window.panels.queue.validArea().ylen, 0.8),
            .area_height = window.panels.queue.validArea().ylen,
        },

        .typing_buffer = initial_typing,
        .find_cursor_pos = 0,
        .find_cursor_prev = 0,
        .viewable_searchable = null,

        .algo_init = false,
        .search_sample_str = algo.SearchSample([]const u8).init(alloc.persistentAllocator),
        .search_sample_su = algo.SearchSample(mpd.SongStringAndUri).init(alloc.persistentAllocator),

        .col_arr = state.ColumnArray(state.n_browse_columns).init(mpd_data.albums),
        .node_switched = false,
        .current_scrolled = false,

        .input_state = .normal_queue,
    };

    _ = alloc.respArena.reset(.free_all);
    var app = App.init(initial_state, &mpd_data);

    var render_state = RenderState(state.n_browse_columns).init();

    while (!app.state.quit) {
        const loop_start_time = time.milliTimestamp();

        defer {
            const frame_time = time.milliTimestamp() - loop_start_time;
            if (frame_time < target_frame_time_ms) {
                const sleep_time: u64 = @intCast((target_frame_time_ms - frame_time) * time.ns_per_ms);
                time.sleep(sleep_time);
            }
        }

        defer {
            _ = alloc.respArena.reset(.{ .retain_with_limit = 1024 });
            wrkfba.reset();
        }

        const input_event: ?Event = try input.checkInputEvent();
        const released_event: ?Event = try input.checkReleaseEvent(input_event);
        const idle_event: [2]?Event = try mpd.checkIdle();
        const time_event: Event = Event{ .time = loop_start_time };

        if (input_event) |event| app.appendEvent(event);
        if (released_event) |event| app.appendEvent(event);
        if (idle_event[0]) |event| app.appendEvent(event);
        if (idle_event[1]) |event| app.appendEvent(event);
        app.appendEvent(time_event);

        app.updateState(&render_state, &mpd_data);
        try render.render(&app.state, &render_state, window.panels, &wrkfba.end_index);
        render_state.reset();
    }
}

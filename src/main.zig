const std = @import("std");
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

var initial_song: mpd.CurrentSong = undefined;
var initial_queue: mpd.Queue = mpd.Queue{};
var initial_typing: state.TypingDisplay = undefined;

const wrkallocator = alloc.wrkallocator;
const wrkfba = &alloc.wrkfba;
const wrkbuf = &alloc.wrkbuf;

pub fn main() !void {
    defer alloc.deinit();

    try mpd.connect(wrkbuf[0..64], .command, false);
    defer mpd.disconnect(.command);

    try mpd.connect(wrkbuf[0..64], .idle, true);
    defer mpd.disconnect(.idle);

    try term.init();
    defer term.deinit() catch {};

    try window.init();

    try util.init();
    defer util.deinit() catch {};

    initial_song.init();
    _ = try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &initial_song);
    _ = try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &initial_song);
    _ = try mpd.getQueue(wrkallocator, &wrkfba.end_index, &initial_queue);

    initial_typing.init();

    const all_searchable = try mpd.getSearchable(alloc.persistentAllocator, alloc.respAllocator);
    alloc.respArena.deinit();

    algo.pointerToAll = &all_searchable;
    algo.resetItems();
    log("allsearchable len: {}", .{all_searchable.len});

    const initial_state = state.State{
        .quit = false,
        .first_render = true,

        .song = initial_song,
        .isPlaying = true,
        .last_second = 0,
        .last_elapsed = 0,
        .bar_init = true,
        .currently_filled = 0,

        .queue = initial_queue,
        .viewStartQ = 0,
        .viewEndQ = undefined,
        .cursorPosQ = 0,
        .prevCursorPos = 0,

        .typing_display = initial_typing,
        .find_cursor_pos = 0,
        .viewable_searchable = null,

        .input_state = .normal,
        .search_state = .find,
    };

    var app = App.init(initial_state);

    var render_state = RenderState.init();

    while (!app.state.quit) {
        defer wrkfba.reset();
        const loop_start_time = std.time.milliTimestamp();

        const input_event: ?Event = try input.checkInputEvent(wrkbuf[wrkfba.end_index .. wrkfba.end_index + 1]);
        // const idle_event: ?Event = mpd.checkIdle(wrkbuf[wrkfba.end_index .. wrkfba.end_index + 18]);
        const time_event: Event = Event{ .time = loop_start_time };

        if (input_event) |event| try app.appendEvent(event);
        // if (idle_event) |event| app.appendEvent(event);
        try app.appendEvent(time_event);

        app.updateState(&render_state);
        try render.render(&app.state, &render_state, window.panels, &wrkfba.end_index);
        render_state = RenderState{};
    }
}

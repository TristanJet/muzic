const std = @import("std");
const sym = @import("symbols.zig");
const util = @import("util.zig");
const mpd = @import("mpdclient.zig");
const algo = @import("algo.zig");
const window = @import("window.zig");
const terminal = @import("terminal.zig");
const state = @import("state.zig");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;
const time = std.time;

const moveCursor = util.moveCursor;
const log = util.log;
const clear = util.clear;

const target_fps: u64 = 60;
const target_frame_time: u64 = 1_000_000_000 / target_fps; // nanoseconds per frame

pub var quit: bool = false;

var wrkbuf: [4096]u8 = undefined;
var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
const wrkallocator = wrkfba.allocator();

var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const respAllocator = respArena.allocator();

var persistentArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const persistentAllocator = persistentArena.allocator();

var currSong = mpd.CurrentSong{};

var panelCurrSong: window.Panel = undefined;
var queue = mpd.Queue{};

var currently_filled: usize = 0;
var bar_init: bool = true;
var last_elapsed: u16 = 0;
var last_second: i64 = 0;

var panelQueue: window.Panel = undefined;
var viewStartQ: usize = 0;
var viewEndQ: usize = undefined;
var cursorPosQ: u8 = 0;
var prevCursorPos: u8 = 0;

var panelFind: window.Panel = undefined;

var panelBrowse1: window.Panel = undefined;

var isPlaying: bool = true;

var algoArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const algoArenaAllocator = algoArena.allocator();

var typingArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const typingAllocator = typingArena.allocator();

var all_searchable: []mpd.Searchable = undefined;
var viewable_searchable: ?[]mpd.Searchable = null;

var state_input = Input_State.normal;
var state_search = Search_State.find;


pub fn main() !void {
    defer typingArena.deinit();
    defer algoArena.deinit();

    util.init() catch {};
    defer util.deinit() catch {};

    mpd.connect(wrkbuf[0..64], &mpd.cmdStream, false) catch {
        log("Unable to connect to MPD", .{});
        return;
    };
    defer mpd.disconnect(&mpd.cmdStream);

    mpd.connect(wrkbuf[0..64], &mpd.idleStream, true) catch |err| {
        log("Unable to connect to MPD: {}\n", .{err});
        return;
    };
    defer mpd.disconnect(&mpd.idleStream);

    const tty = terminal.getTty();
    defer tty.close();

    terminal.setNonBlock(tty);

    try window.getWindow(&tty);

    terminal.uncook(tty) catch {
        log("failed to uncook", .{});
        return;
    };
    defer terminal.cook(tty) catch {};

    _ = currSong.init();
    _ = try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &currSong);
    _ = try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &currSong);
    log("elapsed: {}\nduration: {}\n", .{ currSong.time.elapsed, currSong.time.duration });

    _ = try mpd.getQueue(wrkallocator, &wrkfba.end_index, &queue);

    viewEndQ = viewStartQ + panelQueue.validArea().ylen + 1;

    panelCurrSong = window.Panel.init(
        true,
        .{
            .absolute = .{
                .min = window.window.xmin,
                .max = window.window.xmax,
            },
        },
        .{
            .absolute = .{ .min = 0, .max = 6 },
        },
        null,
    );

    panelQueue = window.Panel.init(
        true,
        .{
            .fractional = .{
                .totalfr = 7,
                .startline = 0,
                .endline = 4,
            },
        },
        .{
            .absolute = .{
                .min = 7,
                .max = window.window.ymax,
            },
        },
        null,
    );

    panelFind = window.Panel.init(
        true,
        .{
            .fractional = .{
                .totalfr = 7,
                .startline = 4,
                .endline = 7,
            },
        },
        .{
            .absolute = .{
                .min = 7,
                .max = window.window.ymax,
            },
        },
        null,
    );
    algo.nRanked = panelFind.validArea().ylen;

    panelBrowse1 = window.Panel.init(
        false,
        .{
            .fractional = .{
                .totalfr = 8,
                .startline = 0,
                .endline = 2,
            },
        },
        .{
            .absolute = .{
                .min = panelFind.validArea().ymin,
                .max = panelFind.validArea().ymax,
            },
        },
        panelFind.validArea(),
    );
    log("browse 1 area: {}\n", .{panelBrowse1});
    log("window area: {}\n", .{window.window});

    _ = try mpd.initIdle();

    all_searchable = try mpd.getSearchable(persistentAllocator, respAllocator);
    algo.pointerToAll = &all_searchable;
    algo.resetItems();
    log("allsearchable len: {}", .{all_searchable.len});
    respArena.deinit();

    renderState.currentTrack = true;
    renderState.borders = true;
    renderState.queue = true;
    renderState.find = true;
    renderState.queueEffects = true;
    var last_render_time = time.milliTimestamp();
    var last_ping_time = time.milliTimestamp();

    while (!quit) {
        defer {
            if (wrkfba.end_index > 0) wrkfba.reset();
        }
        const loop_start_time = time.milliTimestamp();
        var inputBuffer: [1]u8 = undefined;
        try checkInput(inputBuffer[0..]);

        // handle Idle update
        const idleRes = try mpd.checkIdle(wrkallocator, &wrkfba.end_index);
        if (idleRes == 1) {
            _ = currSong.init();
            _ = try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &currSong);
            _ = try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &currSong);
            _ = try mpd.initIdle();
            last_elapsed = currSong.time.elapsed;
            last_second = @divTrunc(loop_start_time, 1000);
            bar_init = true;
            renderState.bar = true;
            renderState.queue = true;
            renderState.queueEffects = true;
            renderState.currentTrack = true;
        } else if (idleRes == 2) {
            queue = mpd.Queue{};
            _ = try mpd.getQueue(wrkallocator, &wrkfba.end_index, &queue);
            _ = try mpd.initIdle();
            renderState.queue = true;
            renderState.queueEffects = true;
        }

        updateElapsed(loop_start_time);

        if (bar_init) try browseOneRender(tty.writer());

        render(renderState, &wrkfba.end_index) catch |err| {
            log("Couldn't render {}", .{err});
            return;
        };
        renderState = RenderState.init();
        last_render_time = time.milliTimestamp();

        if ((loop_start_time - last_ping_time) >= 25 * 1000) {
            try mpd.checkConnection();
            last_ping_time = loop_start_time;
        }

        const end_time = time.nanoTimestamp();
        const elapsed_ns = @as(u64, @intCast(end_time - loop_start_time * 1_000_000));
        if (elapsed_ns < target_frame_time) {
            const sleep_ns = target_frame_time - elapsed_ns;
            time.sleep(sleep_ns);
        }
    }
}

fn loop() !void {
    while (!quit) {
        // checkInput();
        // checkIdle();
        // updateElapsed(start: i64);
        // render();
        // ping();
    }
}

fn updateElapsed(start: i64) void {
    if (isPlaying) {
        const current_second = @divTrunc(start, 1000);
        if (current_second > last_second) {
            currSong.time.elapsed += 1;
            last_second = current_second;
            renderState.bar = true;
        }
    }
}

pub fn scrollQ(isUp: bool) void {
    if (isUp) {
        if (cursorPosQ == 0) return;
        moveCursorPos(&cursorPosQ, &prevCursorPos, .down);
        if (cursorPosQ < viewStartQ) {
            viewStartQ = cursorPosQ;
            viewEndQ = viewStartQ + panelQueue.validArea().ylen + 1;
        }
    } else {
        if (cursorPosQ >= queue.len - 1) return;
        moveCursorPos(&cursorPosQ, &prevCursorPos, .up);
        if (cursorPosQ >= viewEndQ) {
            viewEndQ = cursorPosQ + 1;
            viewStartQ = viewEndQ - panelQueue.validArea().ylen - 1;
        }
    }
    renderState.queueEffects = true;
}

fn moveCursorPos(current: *u8, previous: *u8, direction: cursorDirection) void {
    switch (direction) {
        .up => {
            previous.* = current.*;
            current.* += 1;
        },
        .down => {
            previous.* = current.*;
            current.* -= 1;
        },
    }
}

fn fetchTime() !mpd.Time {
    return try mpd.get_status();
}
